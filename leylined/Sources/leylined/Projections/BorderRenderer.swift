// The border projection rendered as nonactivating AppKit panels.
//
// It RENDERS a BorderPlan and computes nothing: the plan arrives from
// LeylineModel's pure `BorderProjection.plan(world:)`, and this file must
// never read the world (no CGWindowList, no AX, no file polls).
// Everything here is main-thread AppKit.
//
// Three presentation properties, by mechanism rather than assertion:
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

private enum BorderInsertionPreviewStyle {
    static let tintAlpha: CGFloat = 0.16
    static let badgeAlpha: CGFloat = 0.88
    static let fontSize: CGFloat = 15
    static let paddingX: CGFloat = 12
    static let paddingY: CGFloat = 8
    static let margin: CGFloat = 8
    static let badgeRadius: CGFloat = 8
}

/// Click-through drawing within the exact source destination supplied by the
/// immutable plan. Label fitting affects typography only, never tile geometry.
@MainActor
private final class BorderInsertionPreviewView: NSView {
    var preview: BorderInsertionPreview?
    var color: NSColor = .systemBlue
    var cornerRadius: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        guard let preview else { return }
        if preview.isAvailable {
            color.withAlphaComponent(BorderInsertionPreviewStyle.tintAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        let available = bounds.insetBy(dx: BorderInsertionPreviewStyle.margin, dy: BorderInsertionPreviewStyle.margin)
        guard available.width > 0, available.height > 0 else { return }
        let fontSize = min(BorderInsertionPreviewStyle.fontSize, max(6, available.height - BorderInsertionPreviewStyle.paddingY * 2))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let choices = preview.isAvailable
            ? [preview.label, "\(preview.arrow) \(preview.sideLabel)", preview.arrow]
            : [preview.label, "\(preview.arrow) NO FIT", preview.arrow]
        let label = choices.first { ($0 as NSString).size(withAttributes: attributes).width
            + BorderInsertionPreviewStyle.paddingX * 2 <= available.width } ?? preview.arrow
        let size = (label as NSString).size(withAttributes: attributes)
        let badge = NSRect(x: bounds.midX - min(available.width, size.width + BorderInsertionPreviewStyle.paddingX * 2) / 2,
            y: bounds.midY - min(available.height, size.height + BorderInsertionPreviewStyle.paddingY * 2) / 2,
            width: min(available.width, size.width + BorderInsertionPreviewStyle.paddingX * 2),
            height: min(available.height, size.height + BorderInsertionPreviewStyle.paddingY * 2))
        let path = NSBezierPath(roundedRect: badge, xRadius: BorderInsertionPreviewStyle.badgeRadius,
            yRadius: BorderInsertionPreviewStyle.badgeRadius)
        NSColor.black.withAlphaComponent(BorderInsertionPreviewStyle.badgeAlpha).setFill(); path.fill()
        color.setStroke(); path.lineWidth = 1; path.stroke()
        (label as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
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
        let thickness = CGFloat(BorderPalette.thickness)
        let radius = CGFloat(BorderPalette.radius(store: store))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let decorationCount = plan.rings.count + plan.selectionLines.count + (plan.insertionPreview == nil ? 0 : 1)
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
            let layer = Self.shapeLayer(for: panel)
            let stroke = panel.contentView!.bounds.insetBy(dx: thickness / 2, dy: thickness / 2)
            layer.path = CGPath(roundedRect: stroke, cornerWidth: radius, cornerHeight: radius, transform: nil)
            layer.strokeColor = Self.nsColor(hex: BorderPalette.color(ring.role, store: store)).cgColor
            layer.fillColor = NSColor.clear.cgColor
            layer.lineWidth = thickness
            layer.lineDashPattern = ring.stroke == .dashed ? [6, 4] : nil
            layer.lineCap = .butt
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
            let layer = Self.shapeLayer(for: panel)
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
            if panel.alphaValue == 0 { panel.orderFrontRegardless() }
            panel.alphaValue = 1
        }
        if let preview = plan.insertionPreview {
            let panel = panels[plan.rings.count + plan.selectionLines.count]
            let frame = NSRect(x: preview.frame.x, y: screenHeight - preview.frame.y - preview.frame.h,
                width: preview.frame.w, height: preview.frame.h)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            let view: BorderInsertionPreviewView
            if let existing = panel.contentView as? BorderInsertionPreviewView { view = existing }
            else {
                view = BorderInsertionPreviewView(frame: NSRect(origin: .zero, size: frame.size))
                view.autoresizingMask = [.width, .height]
                view.setAccessibilityElement(false)
                panel.contentView = view
            }
            view.preview = preview
            view.color = preview.isAvailable ? Self.nsColor(hex: BorderPalette.color(.moved, store: store)) : .systemRed
            view.cornerRadius = radius
            view.needsDisplay = true
            panel.orderFrontRegardless()
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
        panel.contentView = makeShapeView(frame: panel.contentView?.bounds ?? .zero)
        return panel
    }

    /// Panel indices change as a scope adds/removes affected windows. Replacing
    /// the content kind prevents a previous badge surviving as a border panel.
    private static func shapeLayer(for panel: NSPanel) -> CAShapeLayer {
        if panel.contentView is BorderInsertionPreviewView || !(panel.contentView?.layer is CAShapeLayer) {
            panel.contentView = makeShapeView(frame: NSRect(origin: .zero, size: panel.frame.size))
        }
        return panel.contentView!.layer as! CAShapeLayer
    }

    private static func makeShapeView(frame: NSRect) -> NSView {
        let content = NSView(frame: frame)
        content.layer = CAShapeLayer()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.autoresizingMask = [.width, .height]
        content.setAccessibilityElement(false)
        return content
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

#if LEYLINE_BUILD_TESTS
/// Render the actual insertion view offscreen for visual QA, without opening
/// panels or reading the desktop. The caller supplies fixture-owned geometry.
@MainActor
func renderInsertionPreviewSample(_ preview: BorderInsertionPreview, output: URL) throws {
    guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(preview.frame.w.rounded(.up)), pixelsHigh: Int(preview.frame.h.rounded(.up)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let bounds = NSRect(x: 0, y: 0, width: preview.frame.w, height: preview.frame.h)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    bounds.fill()
    let view = BorderInsertionPreviewView(frame: bounds)
    view.preview = preview
    view.color = preview.isAvailable ? NSColor(srgbRed: 41 / 255, green: 98 / 255, blue: 1, alpha: 1) : .systemRed
    view.draw(view.bounds)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: output)
}
#endif

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
                "insertion_preview": plan.insertionPreview.map { .object(["window_id": .int($0.windowId),
                    "frame": $0.frame.json, "side": .string($0.side.rawValue), "label": .string($0.label),
                    "available": .bool($0.isAvailable)]) } ?? .null,
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
