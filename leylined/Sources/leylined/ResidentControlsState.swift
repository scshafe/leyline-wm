import Foundation
import LeylineModel

struct ResidentSpaceTarget: Equatable, Sendable {
    let spaceKey: String
    let displayId: String

    static func focusedContext(in world: JSONValue) -> JSONValue? {
        ["focused_space", "active_context", "focus"].compactMap { world.at(path: $0) }.first { $0.objectValue != nil }
    }

    static func focused(in world: JSONValue) -> ResidentSpaceTarget? {
        guard let context = focusedContext(in: world),
              context.at(path: "space_identity_available")?.boolValue != false,
              world.at(path: "space_identity_available")?.boolValue != false,
              let space = context.at(path: "space_key")?.stringValue, !space.isEmpty, !space.contains("runtime:"),
              let display = context.at(path: "display_id")?.stringValue, !display.isEmpty else { return nil }
        return ResidentSpaceTarget(spaceKey: space, displayId: display)
    }

    func isVisible(in world: JSONValue) -> Bool {
        guard !spaceKey.isEmpty, !spaceKey.contains("runtime:"), !displayId.isEmpty,
              world.at(path: "space_identity_available")?.boolValue != false else { return false }
        let contexts = [Self.focusedContext(in: world)].compactMap { $0 }
            + (world.at(path: "space_contexts")?.arrayValue ?? []) + (world.at(path: "windows")?.arrayValue ?? [])
        return contexts.contains {
            $0.at(path: "space_key")?.stringValue == spaceKey && $0.at(path: "display_id")?.stringValue == displayId
                && $0.at(path: "space_visible")?.boolValue != false && $0.at(path: "space_identity_available")?.boolValue != false
        }
    }
}

enum ResidentLifecycleAction: String, Sendable { case start, stop, restart, hardReset = "hard_reset" }

/// Typed menu intents enter the same controller as keyboard and socket actions.
struct ResidentMenuAction: Sendable {
    let actionID: String
    let arguments: JSONValue
    let target: ResidentSpaceTarget
    let expectedRevision: UInt64
}

struct ResidentWindowMenuEntry: Equatable, Sendable {
    let windowID: Int64
    let title: String
    let target: ResidentSpaceTarget
    let pid: Int64?
    let windowGeneration: Int64?
    let observerEpoch: String?
    let obscured: Bool
    let selectable: Bool
}

/// @canonical resident_controls_projection -- pure revision projection. Opening
/// a menu freezes its target and entries; live authority still gates each action.
struct ResidentControlsState: Sendable {
    private(set) var revision: UInt64 = 0
    private(set) var currentTarget: ResidentSpaceTarget?
    private(set) var managementEnabled: Bool?
    private(set) var menuTracking = false
    private(set) var menuTarget: ResidentSpaceTarget?
    private(set) var menuManagementEnabled: Bool?
    private(set) var menuWindows: [ResidentWindowMenuEntry] = []
    private(set) var currentWindows: [ResidentWindowMenuEntry] = []
    private(set) var globallyRunning = true
    private(set) var globalGutterWidth: Int?
    private(set) var effectiveGutterWidth = BorderPalette.defaultThickness
    private(set) var status = "Starting"
    private(set) var unavailableReason: String?
    private var observedWindows: [ResidentWindowMenuEntry] = []
    private var menuRevision: UInt64 = 0
    private var liveWorld: JSONValue = .object([:])

    mutating func receive(revision: UInt64, world: JSONValue) {
        guard revision >= self.revision, let object = world.objectValue else { return }
        self.revision = revision
        liveWorld = world
        let context = ResidentSpaceTarget.focusedContext(in: world)?.objectValue
        currentTarget = ResidentSpaceTarget.focused(in: world)
        if let target = currentTarget {
            managementEnabled = object["space_activation"]?.objectValue?[target.spaceKey]?.boolValue
                ?? object["spaces_enabled"]?.objectValue?[target.spaceKey]?.boolValue
                ?? context?["space_enabled"]?.boolValue ?? true
        } else { managementEnabled = nil }
        globallyRunning = object["resident_running"]?.boolValue ?? globallyRunning
        globalGutterWidth = object["global_gutter_width"]?.intValue.map(Int.init)
        effectiveGutterWidth = object["effective_gutter_width"]?.intValue.map(Int.init)
            ?? globalGutterWidth ?? BorderPalette.defaultThickness
        observedWindows = Self.windowEntries(world: world)
        currentWindows = observedWindows.filter { $0.target == currentTarget }
        let result = object["last_result"]
        let fault = ["failed", "refused"].contains(result?.at(path: "status")?.stringValue ?? "")
            ? result?.at(path: "reason")?.stringValue : nil
        let residentReason: String? = object["resident_unavailable_reason"]?.stringValue ?? fault
        let observationReason: String? = object["observation"]?.at(path: "world_failure_code")?.stringValue
            ?? object["observation"]?.at(path: "failure_code")?.stringValue
        let spaceReason: String? = object["space_identity_reason"]?.stringValue
            ?? context?["space_identity_reason"]?.stringValue
            ?? (currentTarget == nil ? "space_identity_unavailable" : nil)
        unavailableReason = residentReason ?? observationReason ?? spaceReason
        status = object["resident_status"]?.stringValue
            ?? (globallyRunning ? (currentTarget == nil ? "Space unavailable" : "Running") : "Stopped")
    }

    mutating func menuWillOpen() {
        guard !menuTracking else { return }
        menuTracking = true
        menuTarget = currentTarget
        menuManagementEnabled = managementEnabled
        menuWindows = currentWindows
        menuRevision = revision
    }
    mutating func menuDidClose() {
        menuTracking = false; menuTarget = nil; menuManagementEnabled = nil; menuWindows = []
    }
    var toggleTarget: ResidentSpaceTarget? { menuTracking ? menuTarget : currentTarget }
    var toggleManagementEnabled: Bool? { menuTracking ? menuManagementEnabled : managementEnabled }
    var windowEntries: [ResidentWindowMenuEntry] { menuTracking ? menuWindows : currentWindows }

    /// A frozen entry is selectable only while its exact lifetime remains known
    /// and its original visible Space remains enabled. Focus changes are harmless.
    func selectionAction(windowID: Int64) -> ResidentMenuAction? {
        guard globallyRunning, let entry = windowEntries.first(where: { $0.windowID == windowID }),
              entry.selectable, targetIsEnabled(entry.target),
              let live = observedWindows.first(where: { $0.windowID == windowID }),
              live.selectable, live.target == entry.target, live.pid == entry.pid,
              live.windowGeneration == entry.windowGeneration, live.observerEpoch == entry.observerEpoch else { return nil }
        var arguments: JSONObject = ["window_id": .int(windowID)]
        if let pid = entry.pid { arguments["expected_pid"] = .int(pid) }
        if let lifetime = entry.windowGeneration { arguments["expected_window_generation"] = .int(lifetime) }
        if let epoch = entry.observerEpoch { arguments["expected_observer_epoch"] = .string(epoch) }
        return ResidentMenuAction(actionID: "window.select", arguments: .object(arguments),
            target: entry.target, expectedRevision: menuTracking ? menuRevision : revision)
    }

    func regutterAction() -> ResidentMenuAction? {
        guard globallyRunning, let target = toggleTarget, targetIsEnabled(target) else { return nil }
        return ResidentMenuAction(actionID: "layout.regutter", arguments: .object([:]), target: target,
            expectedRevision: menuTracking ? menuRevision : revision)
    }

    func targetIsEnabled(_ target: ResidentSpaceTarget) -> Bool {
        guard liveWorld.at(path: "management_enabled")?.boolValue != false,
              liveWorld.at(path: "persistence_available")?.boolValue != false,
              liveWorld.at(path: "observation.world_complete")?.boolValue != false,
              liveWorld.at(path: "space_identity_available")?.boolValue != false else { return false }
        if liveWorld.at(path: "space_activation")?.objectValue?[target.spaceKey]?.boolValue == false { return false }
        let contexts = (liveWorld.at(path: "space_contexts")?.arrayValue ?? [])
            + [liveWorld.at(path: "focused_space"), liveWorld.at(path: "active_context"), liveWorld.at(path: "focus")].compactMap { $0 }
        return contexts.contains {
            $0.at(path: "space_key")?.stringValue == target.spaceKey
                && $0.at(path: "display_id")?.stringValue == target.displayId
                && $0.at(path: "space_identity_available")?.boolValue != false
                && $0.at(path: "space_visible")?.boolValue != false
                && $0.at(path: "space_enabled")?.boolValue == true
        }
    }

    private static func windowEntries(world: JSONValue) -> [ResidentWindowMenuEntry] {
        // Membership is an authored model fact, including buried stack members.
        // Traversal reads bindings only; menu projection never allocates geometry.
        var membership = Set<Int64>()
        var obscured = Set<Int64>()
        func readBindings(_ arrangement: JSONValue) {
            for binding in (arrangement.at(path: "bindings")?.objectValue ?? [:]).values {
                if let nested = binding.at(path: "nested"), nested.objectValue != nil { readBindings(nested) }
                else {
                    let members = Arrangement.memberIDs(binding)
                    membership.formUnion(members)
                    obscured.formUnion(members.dropFirst())
                }
            }
        }
        readBindings(world.at(path: "model_state.arrangement") ?? .object([:]))
        let windows = world.at(path: "windows")?.arrayValue ?? []
        let counts = Dictionary(grouping: windows, by: { $0.at(path: "window_id")?.intValue })
        return windows.compactMap { window -> ResidentWindowMenuEntry? in
            guard let id = window.at(path: "window_id")?.intValue, id > 0, membership.contains(id),
                  counts[id]?.count == 1, window.at(path: "eligible")?.boolValue == true,
                  window.at(path: "managed")?.boolValue != false,
                  window.at(path: "minimized")?.boolValue != true, window.at(path: "destroyed")?.boolValue != true,
                  window.at(path: "space_visible")?.boolValue == true,
                  let space = window.at(path: "space_key")?.stringValue, !space.isEmpty, !space.contains("runtime:"),
                  let display = window.at(path: "display_id")?.stringValue, !display.isEmpty else { return nil }
            let app = window.at(path: "app_name")?.stringValue ?? window.at(path: "application")?.stringValue
                ?? window.at(path: "bundle_id")?.stringValue
            let title = window.at(path: "title")?.stringValue
            let label = [app, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
            let enabled = world.at(path: "space_activation")?.objectValue?[space]?.boolValue
                ?? window.at(path: "space_enabled")?.boolValue
            return ResidentWindowMenuEntry(windowID: id, title: label.isEmpty ? "Window \(id)" : label,
                target: ResidentSpaceTarget(spaceKey: space, displayId: display),
                pid: window.at(path: "pid")?.intValue, windowGeneration: window.at(path: "window_generation")?.intValue,
                observerEpoch: world.at(path: "observer_epoch")?.stringValue,
                obscured: obscured.contains(id), selectable: enabled == true)
        }.sorted { ($0.title.localizedStandardCompare($1.title) == .orderedAscending)
            || ($0.title == $1.title && $0.windowID < $1.windowID) }
    }
}
