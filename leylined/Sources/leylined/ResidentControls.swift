// In-process AppKit status items. This surface is a revision projection and a
// command source; no world reads, subprocesses, or recurring state poll exist.
import AppKit
import Foundation
import LeylineModel

/// @canonical resident_controls -- the two ordinary functions are focused-Space
/// management and the Leyline menu. Global recovery is in that mouse-reachable
/// menu, independent of whether input, observers, or projections are running.
@MainActor
final class ResidentControls: NSObject, NSMenuDelegate {
    private let onToggleSpace: @Sendable (ResidentSpaceTarget) -> Void
    private let onLifecycle: @Sendable (ResidentLifecycleAction) -> Void
    private let onAction: @Sendable (ResidentMenuAction) -> Void
    private let onGutter: @Sendable (Int?) -> Void
    private var state = ResidentControlsState()
    private var toggleItem: NSStatusItem?
    private var menuItem: NSStatusItem?
    private let menu = NSMenu(title: "Leyline")
    private let spaceMenuRow = NSMenuItem(title: "Space unavailable", action: nil, keyEquivalent: "")
    private let healthRow = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let windowsRow = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
    private let windowsMenu = NSMenu(title: "Windows")
    private let gutterRow = NSMenuItem(title: "Border width", action: nil, keyEquivalent: "")
    private let gutterMenu = NSMenu(title: "Border width")
    private let regutterRow = NSMenuItem(title: "Reapply border spacing on this Space", action: nil, keyEquivalent: "")
    private var displayedWindows: [ResidentWindowMenuEntry] = []
    private let faultNotice = ResidentInputFaultNoticePresenter(makeSurface: { ResidentInputFaultPanel() })

    init(onToggleSpace: @escaping @Sendable (ResidentSpaceTarget) -> Void,
         onLifecycle: @escaping @Sendable (ResidentLifecycleAction) -> Void,
         onAction: @escaping @Sendable (ResidentMenuAction) -> Void = { _ in },
         onGutter: @escaping @Sendable (Int?) -> Void = { _ in }) {
        self.onToggleSpace = onToggleSpace
        self.onLifecycle = onLifecycle
        self.onAction = onAction
        self.onGutter = onGutter
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(healthRow)
        spaceMenuRow.target = self
        spaceMenuRow.action = #selector(toggleSpace)
        menu.addItem(spaceMenuRow)
        windowsMenu.autoenablesItems = false
        windowsRow.submenu = windowsMenu
        menu.addItem(windowsRow)
        gutterMenu.autoenablesItems = false
        for width in [0, 4, 8, 12, 16] {
            let row = NSMenuItem(title: "\(width) pt", action: #selector(setGlobalGutter(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = NSNumber(value: width)
            gutterMenu.addItem(row)
        }
        gutterMenu.addItem(.separator())
        let configured = NSMenuItem(title: "Use configured border width", action: #selector(resetGlobalGutter), keyEquivalent: "")
        configured.target = self
        gutterMenu.addItem(configured)
        gutterRow.submenu = gutterMenu
        menu.addItem(gutterRow)
        regutterRow.target = self
        regutterRow.action = #selector(regutter)
        menu.addItem(regutterRow)
        menu.addItem(.separator())
        for (title, selector) in [("Start Leyline", #selector(startLeyline)),
                                  ("Stop Leyline", #selector(stopLeyline)),
                                  ("Restart Leyline", #selector(restartLeyline)),
                                  ("Hard reset Leyline", #selector(hardResetLeyline))] {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            row.target = self
            menu.addItem(row)
        }
    }

    func start() {
        guard menuItem == nil else { return }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleSpace)
        toggleItem = toggle
        let entry = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        entry.button?.title = "Leyline"
        entry.button?.setAccessibilityLabel("Open Leyline menu")
        entry.menu = menu
        menuItem = entry
        render()
    }

    /// Only process shutdown unmounts this recovery surface. Global stop does
    /// not call this method; it changes the revision state while items survive.
    func stop() {
        faultNotice.stop()
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let menuItem { NSStatusBar.system.removeStatusItem(menuItem) }
        toggleItem = nil
        menuItem = nil
    }

    func receive(revision: UInt64, world: JSONValue) {
        state.receive(revision: revision, world: world)
        render()
    }

    func receiveFaultRelease(_ event: ResidentInputFaultRelease, currentInputEpoch: String,
                             currentInputGeneration: UInt64) {
        faultNotice.receive(event, currentInputEpoch: currentInputEpoch, currentInputGeneration: currentInputGeneration)
    }

    func health() -> JSONObject {
        ["mounted": .bool(menuItem != nil), "revision": .int(Int64(state.revision)),
         "menu_tracking": .bool(state.menuTracking), "recurring_poll_count": .int(0),
         "space_identity_available": .bool(state.currentTarget != nil),
         "window_entry_count": .int(Int64(state.windowEntries.count)),
         "menu_space_key": state.toggleTarget.map { .string($0.spaceKey) } ?? .null,
         "global_gutter_width": state.globalGutterWidth.map { .int(Int64($0)) } ?? .null,
         "unavailable_reason": state.unavailableReason.map(JSONValue.string) ?? .null,
         "global_recovery_reachable": .bool(menuItem != nil), "fault_notice": .object(faultNotice.health)]
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        state.menuWillOpen(); render()
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        state.menuDidClose(); render()
    }

    @objc private func toggleSpace() {
        guard let target = state.toggleTarget else { NSSound.beep(); return }
        onToggleSpace(target)
    }
    @objc private func startLeyline() { onLifecycle(.start) }
    @objc private func stopLeyline() { onLifecycle(.stop) }
    @objc private func restartLeyline() { onLifecycle(.restart) }
    @objc private func hardResetLeyline() { onLifecycle(.hardReset) }
    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value,
              let action = state.selectionAction(windowID: id) else { NSSound.beep(); return }
        onAction(action)
    }
    @objc private func regutter() {
        guard let action = state.regutterAction() else { NSSound.beep(); return }
        onAction(action)
    }
    @objc private func setGlobalGutter(_ sender: NSMenuItem) {
        guard let width = (sender.representedObject as? NSNumber)?.intValue else { NSSound.beep(); return }
        onGutter(width)
    }
    @objc private func resetGlobalGutter() { onGutter(nil) }

    private static func humanReason(_ code: String) -> String {
        let reason = code.lowercased()
        if reason.contains("session_locked") { return "Desktop locked" }
        if reason.contains("input_monitoring") { return "Input Monitoring permission needed" }
        if reason.contains("trust") || reason.contains("permission") { return "Accessibility permission needed" }
        if reason.contains("journal") || reason.contains("persistence") { return "Saved state needs recovery" }
        if reason.contains("geometry") || reason.contains("config") || reason.contains("settings") { return "Check Leyline settings" }
        if reason.contains("maintenance") { return "Recovery in progress" }
        if reason.contains("space") { return "Space unavailable" }
        if reason.contains("minimum") || reason.contains("constraint") { return "Windows cannot fit this layout" }
        if reason.contains("window") || reason.contains("observation") { return "Window information unavailable" }
        return "Action unavailable"
    }

    private func render() {
        let target = state.toggleTarget
        let enabled = state.toggleManagementEnabled
        toggleItem?.button?.title = target == nil ? "◌" : (enabled == true ? "●" : "○")
        toggleItem?.button?.isEnabled = target != nil
        toggleItem?.button?.toolTip = target.map { _ in "Management on this Space: \(enabled == true ? "ON" : "OFF")" }
            ?? "Focused Space identity unavailable"
        toggleItem?.button?.setAccessibilityLabel(target == nil ? "Space unavailable" : "Toggle focused Space management")
        healthRow.title = state.unavailableReason.map(Self.humanReason) ?? state.status
        healthRow.isEnabled = false
        spaceMenuRow.title = target.map { _ in "Turn management \(enabled == true ? "off" : "on") on this Space" } ?? "Space unavailable"
        spaceMenuRow.isEnabled = target != nil
        if displayedWindows != state.windowEntries {
            displayedWindows = state.windowEntries
            windowsMenu.removeAllItems()
            for entry in displayedWindows {
                let row = NSMenuItem(title: entry.title + (entry.obscured ? " (obscured)" : ""),
                    action: #selector(selectWindow(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = NSNumber(value: entry.windowID)
                row.toolTip = "Select window \(entry.windowID) on this Space"
                row.setAccessibilityLabel("Select " + entry.title + (entry.obscured ? ", obscured window" : ""))
                windowsMenu.addItem(row)
            }
            if displayedWindows.isEmpty {
                let row = NSMenuItem(title: "No managed windows on this Space", action: nil, keyEquivalent: "")
                row.isEnabled = false
                windowsMenu.addItem(row)
            }
        }
        for (index, entry) in displayedWindows.enumerated() {
            windowsMenu.item(at: index)?.isEnabled = state.selectionAction(windowID: entry.windowID) != nil
        }
        windowsRow.isEnabled = !displayedWindows.isEmpty
        gutterRow.title = "Border width (\(state.effectiveGutterWidth) pt)"
        for row in gutterMenu.items where !row.isSeparatorItem {
            if let width = (row.representedObject as? NSNumber)?.intValue {
                row.state = state.globalGutterWidth == width ? .on : .off
            } else { row.state = state.globalGutterWidth == nil ? .on : .off }
        }
        regutterRow.isEnabled = state.regutterAction() != nil
    }
}
