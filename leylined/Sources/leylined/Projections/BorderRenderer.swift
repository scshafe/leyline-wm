// The border projection rendered as nonactivating AppKit panels.
//
// It RENDERS a BorderPlan and computes nothing: the plan arrives from
// LeylineModel's pure `BorderProjection.plan(world:)`, and this file must
// never read the world (no CGWindowList, no AX, no file polls) — asserted
// structurally by `ley test leylined`. Everything here is main-thread AppKit.
//
// Three D10 properties, by mechanism rather than assertion:
//   * COMMIT BEFORE RENDER — `render` is only ever called with an
//     already-committed revision; nothing here can mutate core state (there
//     is no path back into the timeline from this file).
//   * DEGRADE, NEVER FAIL — a render fault disables THIS projection and is
//     reported; it cannot fail, block, or mutate a window-management
//     transaction.
//   * REMOUNT WITHOUT TOUCHING THE TIMELINE — `unmount()`/`mount()` rebuild
//     the panels only; the borders survival test's "renderer restarts"
//     becomes exactly this.
//
import AppKit
import Foundation
import QuartzCore
import LeylineModel

enum BorderRenderSurfaceResult: Equatable {
    case rendered
    case failed(reason: String)
}

/// @canonical border_render_surface -- the sole mutable AppKit output surface
/// behind BorderRenderer's revision/health gate. The protocol is also the
/// hermetic observation point for proving teardown/remount reconstruction.
@MainActor
protocol BorderRenderSurface: AnyObject {
    func replace(plan: BorderPlan, store: JSONValue?) -> BorderRenderSurfaceResult
    func clear()
}

@MainActor
private final class AppKitBorderRenderSurface: BorderRenderSurface {
    private var panels: [NSPanel] = []
    private let screenHeightProvider: () -> CGFloat?

    init(screenHeightProvider: @escaping () -> CGFloat?) {
        self.screenHeightProvider = screenHeightProvider
    }

    func replace(
        plan: BorderPlan,
        store: JSONValue?
    ) -> BorderRenderSurfaceResult {
        guard let screenHeight = screenHeightProvider() else {
            return .failed(reason: "no_screen_available")
        }
        let thickness = CGFloat(BorderPalette.thickness(store: store))
        if thickness == 0 { clear(); return .rendered }
        let radius = CGFloat(BorderPalette.radius(store: store))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let decorationCount = plan.rings.count + plan.selectionLines.count
        while panels.count < decorationCount { panels.append(Self.makePanel()) }

        for (index, ring) in plan.rings.enumerated() {
            let panel = panels[index]
            // The ring sits just OUTSIDE the window: outset by the stroke so
            // its INNER edge lands on the window's outer edge.
            let envelope = ring.envelope(thickness: Double(thickness))
            let outset = CGRect(x: envelope.x, y: envelope.y, width: envelope.w, height: envelope.h)
            // CG (top-left origin) → AppKit (bottom-left, primary screen).
            let appkit = NSRect(
                x: outset.origin.x,
                y: screenHeight - outset.origin.y - outset.height,
                width: outset.width,
                height: outset.height)
            if panel.frame != appkit { panel.setFrame(appkit, display: true) }
            if let layer = panel.contentView?.layer as? CAShapeLayer {
                let stroke = panel.contentView!.bounds.insetBy(dx: thickness / 2, dy: thickness / 2)
                layer.path = CGPath(roundedRect: stroke, cornerWidth: radius, cornerHeight: radius, transform: nil)
                layer.strokeColor = Self.nsColor(hex: BorderPalette.color(ring.role, store: store)).cgColor
                layer.fillColor = NSColor.clear.cgColor
                layer.lineWidth = thickness
                layer.lineDashPattern = ring.stroke == .dashed ? [6, 4] : nil
                layer.lineCap = .butt
            }
            if panel.alphaValue == 0 { panel.orderFrontRegardless() }
            panel.alphaValue = 1
        }
        for (index, line) in plan.selectionLines.enumerated() {
            let panel = panels[plan.rings.count + index]
            let horizontal = line.axis == "h"
            let cg = CGRect(x: (horizontal ? line.lower : line.coordinate) - Double(thickness),
                y: (horizontal ? line.coordinate : line.lower) - Double(thickness),
                width: horizontal ? line.upper - line.lower + Double(thickness) * 2 : Double(thickness) * 2,
                height: horizontal ? Double(thickness) * 2 : line.upper - line.lower + Double(thickness) * 2)
            let frame = NSRect(x: cg.minX, y: screenHeight - cg.minY - cg.height, width: cg.width, height: cg.height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if let layer = panel.contentView?.layer as? CAShapeLayer {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: thickness, y: thickness))
                path.addLine(to: horizontal
                    ? CGPoint(x: cg.width - thickness, y: thickness)
                    : CGPoint(x: thickness, y: cg.height - thickness))
                layer.path = path
                layer.strokeColor = Self.nsColor(hex: BorderPalette.color(.dropEdge, store: store)).cgColor
                layer.fillColor = NSColor.clear.cgColor
                layer.lineWidth = thickness
                layer.lineDashPattern = nil
                layer.lineCap = .round
            }
            if panel.alphaValue == 0 { panel.orderFrontRegardless() }
            panel.alphaValue = 1
        }
        for index in decorationCount..<panels.count
            where panels[index].alphaValue != 0 {
            panels[index].orderOut(nil)
            panels[index].alphaValue = 0
        }
        return .rendered
    }

    func clear() {
        for panel in panels {
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
    }

    // A click-through decoration panel; never grabbable, never key.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.alphaValue = 0
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.layer = CAShapeLayer()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.autoresizingMask = [.width, .height]
        content.setAccessibilityElement(false)
        panel.contentView = content
        return panel
    }

    private static func nsColor(hex: String) -> NSColor {
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard body.count == 8, let value = UInt32(body, radix: 16) else {
            return .systemRed
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: CGFloat((value >> 24) & 0xff) / 255)
    }
}

// @MainActor is load-bearing, not decoration: D10 says projections render on
// the main thread from published revisions, and the isolation makes that a
// compile-time property instead of a convention a later edit can break.
@MainActor
final class BorderRenderer {
    private var mounted = false
    private var degraded: String?
    private var lastPlan: BorderPlan = .empty
    private var lastRenderedRevision: UInt64?

    private var store: JSONValue?
    private let surface: any BorderRenderSurface

    init(
        store: JSONValue?,
        screenHeightProvider: @escaping () -> CGFloat? = {
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height
        },
        surface: (any BorderRenderSurface)? = nil
    ) {
        self.store = store
        self.surface = surface
            ?? AppKitBorderRenderSurface(
                screenHeightProvider: screenHeightProvider)
    }

    /// Event-delivered configuration replaces palette state and invalidates
    /// submission evidence so the current immutable plan can be resubmitted.
    func updateStore(_ replacement: JSONValue?) {
        store = replacement
        lastRenderedRevision = nil
        lastPlan = .empty
    }

    var isMounted: Bool { mounted }
    var degradedReason: String? { degraded }
    var health: CoreProjectionHealth {
        CoreProjectionHealth(
            required: true,
            mounted: mounted,
            degraded: degraded != nil,
            degradedReason: degraded,
            lastRenderedRevision: lastRenderedRevision)
    }

    /// Mount the resident border projection on the main actor.
    @discardableResult
    func mount() -> Bool {
        degraded = nil
        mounted = true
        return true
    }

    func unmount() {
        surface.clear()
        mounted = false
        lastPlan = .empty
        // Revision evidence describes current output, not historical success.
        // Teardown invalidates it so remount must render the current immutable
        // snapshot before the positive health oracle can pass again.
        lastRenderedRevision = nil
    }

    /// Render one revision atomically, or skip it. A revision older than the
    /// one already on screen is DROPPED rather than drawn — two revisions
    /// never blend in a frame (D2), and a late delivery never rolls the ring
    /// backwards.
    @discardableResult
    func render(plan: BorderPlan, revision: UInt64) -> Bool {
        guard mounted, degraded == nil else { return false }
        if let lastRenderedRevision, revision <= lastRenderedRevision {
            return false
        }
        if plan == lastPlan {
            lastRenderedRevision = revision
            return true
        }
        switch surface.replace(plan: plan, store: store) {
        case .rendered:
            ResidentPerformanceTrace.shared.record("render_submitted", fields: [
                "revision": .int(Int64(clamping: revision)),
                "candidate_id": plan.previewCandidateID.map(JSONValue.string) ?? .null,
                "window_ids": .array(Set(plan.rings.map(\.windowId)).sorted().map(JSONValue.int)),
                "decorations": .array(plan.rings.map { .object(["window_id": .int($0.windowId),
                    "frame": $0.frame.json, "role": .string($0.role.rawValue), "stroke": .string($0.stroke.rawValue)]) }),
                "visible_evidence": .bool(false)])
            lastPlan = plan
            lastRenderedRevision = revision
            return true
        case let .failed(reason):
            // Degrade-to-no-projection: any renderer fault takes the
            // projection down and leaves the core untouched.
            degrade(reason)
            return false
        }
    }

    private func degrade(_ reason: String) {
        degraded = reason
        FileHandle.standardError.write(Data(
            "leylined borders: DEGRADED (\(reason)) — projection disabled, core unaffected\n".utf8))
        unmount()
    }

}
