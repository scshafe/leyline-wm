// @canonical targeted_projection_observation -- notification identity, frame,
// structural eligibility, and independently observed per-display Space context.
// Related: AccessibilityFocusObserver and ProjectionInputFeed. No AX setters,
// external processes, normal-state file reads, or ordinary window enumeration.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LeylineModel

/// @canonical projection_system_ui_owner -- only positively identified OS
/// composition surfaces are excluded before AX client enrollment. Bundle ID
/// alone, an unknown owner, or a user-provided executable never establishes this.
func projectionIsSystemUIOwner(bundleIdentifier: String?, executablePath: String?) -> Bool {
    bundleIdentifier == "com.apple.WindowManager"
        && executablePath == "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
}

@_silgen_name("_AXUIElementGetWindow")
private func projectionAXWindowID(_ element: AXUIElement,
                                  _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

struct ProjectionAXWindowIdentity: Equatable, Sendable {
    let windowId: CGWindowID
    let pid: pid_t
}

/// Uses the owner-PID/CGWindowID identity bridge. AX wrappers alone are never
/// evidence that a recycled ID is unchanged.
func liveProjectionAXWindowIdentity(_ element: AXUIElement) -> ProjectionAXWindowIdentity? {
    try? liveProjectionAXWindowIdentityResult(element).get()
}

/// Preserve an external messaging failure separately from an observed identity change.
func liveProjectionAXWindowIdentityResult(_ element: AXUIElement,
                                         beforeRead: () -> ProjectionObservationFailure? = { nil })
    -> Result<ProjectionAXWindowIdentity, ProjectionObservationFailure> {
    var windowId: CGWindowID = 0
    var pid: pid_t = 0
    if let failure = beforeRead() { return .failure(failure) }
    let windowError = projectionAXWindowID(element, &windowId)
    guard windowError == .success else {
        return .failure(.init(code: "ax_window_identity_read_failed:\(windowError.rawValue)"))
    }
    if let failure = beforeRead() { return .failure(failure) }
    let pidError = AXUIElementGetPid(element, &pid)
    guard pidError == .success else {
        return .failure(.init(code: "ax_window_owner_read_failed:\(pidError.rawValue)"))
    }
    guard windowId > 0, pid > 0 else {
        return .failure(.init(code: "ax_window_identity_invalid:id=\(windowId),pid=\(pid)"))
    }
    return .success(ProjectionAXWindowIdentity(windowId: windowId, pid: pid))
}

struct ProjectionObservationFailure: Error, Equatable, Sendable {
    let code: String
}

/// Reserve the whole fixed message allowance before every external call. A
/// shared AX element always uses the same cap, so observation/setter lanes cannot
/// race to relax each other's deadline near the end of a read.
func projectionAXReadBudgetAllowsCall(started: UInt64, now: UInt64) -> Bool {
    guard now >= started else { return false }
    return now - started <= TargetedProjectionSnapshot.axTotalReadBudgetNs
        - TargetedProjectionSnapshot.axMessageBudgetNs
}

struct TargetedWindowObservation: Equatable, Sendable {
    let windowId: Int64
    let pid: pid_t
    let frame: Frame
    let role: String
    let subrole: String
    let title: String
    let resizable: Bool
    let movable: Bool
    let minimized: Bool
    let onscreen: Bool
    var appName: String = ""
}

struct ProjectionWindowAttributeBatch: Equatable, Sendable {
    let frame: Frame
    let role: String
    let subrole: String
    let minimized: Bool
    let title: String
}

func projectionWindowReadAttributes() -> [CFString] {
    [kAXPositionAttribute as CFString, kAXSizeAttribute as CFString, kAXRoleAttribute as CFString,
     kAXSubroleAttribute as CFString, kAXMinimizedAttribute as CFString, kAXTitleAttribute as CFString]
}

/// @canonical projection_window_attribute_batch -- one SDK batch retains per-slot error semantics.
/// Only an explicitly absent title is optional; unknown mandatory attributes never prove ineligibility.
func projectionDecodeWindowAttributes(_ copiedValues: CFArray?)
    -> Result<ProjectionWindowAttributeBatch, ProjectionObservationFailure> {
    let attributes = projectionWindowReadAttributes()
    guard var values = copiedValues as? [AnyObject], values.count == attributes.count else {
        return .failure(.init(code: "ax_attribute_batch_malformed"))
    }
    for index in values.indices where CFGetTypeID(values[index]) == AXValueGetTypeID() {
        let value = unsafeDowncast(values[index], to: AXValue.self)
        if AXValueGetType(value) == .axError {
            var error = AXError.success
            guard AXValueGetValue(value, .axError, &error) else {
                return .failure(.init(code: "ax_attribute_error_malformed:\(attributes[index])"))
            }
            if index == 5, error == .noValue { values[index] = "" as NSString }
            else { return .failure(.init(code: "ax_attribute_read_failed:\(attributes[index]):\(error.rawValue)")) }
        }
    }
    guard CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID(),
          CFGetTypeID(values[2]) == CFStringGetTypeID(), CFGetTypeID(values[3]) == CFStringGetTypeID(),
          CFGetTypeID(values[4]) == CFBooleanGetTypeID(), CFGetTypeID(values[5]) == CFStringGetTypeID(),
          let role = values[2] as? String, let subrole = values[3] as? String,
          let minimized = values[4] as? Bool, let title = values[5] as? String else {
        return .failure(.init(code: "ax_attribute_type_mismatch"))
    }
    let positionValue = unsafeDowncast(values[0], to: AXValue.self), sizeValue = unsafeDowncast(values[1], to: AXValue.self)
    var position = CGPoint.zero, size = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
          AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
          position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else {
        return .failure(.init(code: "ax_frame_read_failed"))
    }
    return .success(.init(frame: Frame(x: position.x, y: position.y, w: size.width, h: size.height),
                          role: role, subrole: subrole, minimized: minimized, title: title))
}

struct ProjectionWindowHandle: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let windowId: Int64
}

struct ProjectionWindowReadback: Sendable {
    let handle: ProjectionWindowHandle
    let observation: TargetedWindowObservation
    let observerGeneration: UInt64
    let completedUptimeNs: UInt64
}

struct ProjectionWindowInventory: Sendable {
    let handles: [ProjectionWindowHandle]
    let visibleWindowIds: Set<Int64>
    let ownerPids: Set<pid_t>
    let ignoredWindowIds: Set<Int64>
    init(handles: [ProjectionWindowHandle], visibleWindowIds: Set<Int64>, ownerPids: Set<pid_t>, ignoredWindowIds: Set<Int64> = []) {
        self.handles = handles; self.visibleWindowIds = visibleWindowIds; self.ownerPids = ownerPids; self.ignoredWindowIds = ignoredWindowIds
    }
}

protocol TargetedProjectionWindowReading: Sendable {
    var supportsCacheAudit: Bool { get }
    func auditInventory(ignored: [ProjectionWindowHandle], beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure>
    func auditRead(handle: ProjectionWindowHandle, beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure>
    func inventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure>
    func focusedElement(pid: pid_t) -> Result<AXUIElement?, ProjectionObservationFailure>
    func read(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure>
    func freshWindowHandle(pid: pid_t, windowId: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure>
}

extension TargetedProjectionWindowReading {
    var supportsCacheAudit: Bool { false }
    func auditInventory(ignored: [ProjectionWindowHandle], beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> { .failure(.init(code: "cache_audit_reader_unsupported")) }
    func auditRead(handle: ProjectionWindowHandle, beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> { .failure(.init(code: "cache_audit_reader_unsupported")) }
    func freshWindowHandle(pid: pid_t, windowId: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        .failure(.init(code: "effect_fresh_handle_reader_unavailable"))
    }
    func inventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        .failure(.init(code: "world_inventory_reader_unavailable"))
    }
}

/// The exceptional owner query requires one exact candidate; aliases, foreign owners and unknown
/// identities are refusals rather than a guessed replacement for the immutable registered target.
func projectionUniqueFreshWindowHandle(_ candidates: [ProjectionWindowHandle], pid: pid_t, windowId: Int64)
    -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
    guard pid > 0, windowId > 0, candidates.allSatisfy({ $0.pid == pid && $0.windowId > 0 }) else {
        return .failure(.init(code: "effect_fresh_handle_foreign_or_unknown_identity"))
    }
    let matching = candidates.filter { $0.windowId == windowId }
    guard matching.count == 1 else {
        return .failure(.init(code: matching.isEmpty ? "effect_fresh_handle_missing" : "effect_fresh_handle_alias_ambiguous"))
    }
    return .success(matching[0])
}

func projectionEffectRefreshBudgetAllowsCall(started: UInt64, now: UInt64) -> Bool {
    now >= started && now - started <= TargetedProjectionSnapshot.effectRefreshTotalBudgetNs
        - TargetedProjectionSnapshot.effectRefreshMessageBudgetNs
}

struct ProjectionSpaceContext: Equatable, Sendable {
    let key: String
    let displayId: String
    let visible: Bool
}

typealias ProjectionAuditGuard = @Sendable () -> ProjectionObservationFailure?
typealias ProjectionDisplayTopologyRead = @Sendable ([String: Frame], @escaping ProjectionAuditGuard) -> Result<[JSONValue], ProjectionObservationFailure>

/// Canonical display read used by baseline and detached audit. AppKit usable frames are supplied
/// as an immutable mapping; no utility callback reaches NSScreen or changes the canonical cache.
func projectionReadDisplayTopology(_ usable: [String: Frame], beforeCall: @escaping ProjectionAuditGuard)
    -> Result<[JSONValue], ProjectionObservationFailure> {
    if let failure = beforeCall() { return .failure(failure) }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return .failure(.init(code: "cache_audit_topology_unavailable")) }
    if let failure = beforeCall() { return .failure(failure) }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .failure(.init(code: "cache_audit_topology_unavailable")) }
    var out: [JSONValue] = []
    for id in ids {
        if let failure = beforeCall() { return .failure(failure) }
        let frame = CGDisplayBounds(id)
        if let failure = beforeCall() { return .failure(failure) }
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        if let failure = beforeCall() { return .failure(failure) }
        var object: JSONObject = ["display_id": .string(uuid), "id": .int(Int64(id)), "main": .bool(id == CGMainDisplayID()),
            "frame": Frame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height).json,
            "usable_frame_known": .bool(usable[uuid] != nil)]
        if let value = usable[uuid] { object["usable_frame"] = value.json; object["usable"] = value.json }
        out.append(.object(object))
    }
    return .success(out.sorted { ($0.at(path: "id")?.intValue ?? 0) < ($1.at(path: "id")?.intValue ?? 0) })
}

protocol ProjectionSpaceObserving: Sendable {
    func makeAuditProbe() -> (@Sendable (Int64, @escaping @Sendable () -> ProjectionObservationFailure?) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>)?
    func rebaseline() -> Result<Void, ProjectionObservationFailure>
    func context(windowId: Int64) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>
    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure>
}

extension ProjectionSpaceObserving {
    func makeAuditProbe() -> (@Sendable (Int64, @escaping @Sendable () -> ProjectionObservationFailure?) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>)? { nil }
    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure> {
        .failure(.init(code: "independent_current_display_space_unavailable"))
    }
}

private func liveProjectionInventoryStringAttribute(_ element: AXUIElement, _ attribute: CFString)
    -> Result<String, ProjectionObservationFailure> {
    var raw: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
    guard error == .success, let value = raw as? String, !value.isEmpty else {
        return .failure(.init(code: "ax_inventory_classification_attribute_unavailable:\(attribute):\(error.rawValue)"))
    }
    return .success(value)
}

/// @canonical projection_named_window_description -- exact ID encoded as the
/// raw CGWindowID expected by Quartz, with no object retain/release callbacks.
/// Related: the retained reactor's rawCGWindowIDArray bridge.
func projectionNamedWindowDescription(windowID: CGWindowID,
    descriptionReader: (CFArray) -> CFArray? = CGWindowListCreateDescriptionFromArray
) -> Result<[String: Any], ProjectionObservationFailure> {
    guard windowID > 0 else { return .failure(.init(code: "cg_target_window_id_invalid")) }
    var rawValues: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(windowID))]
    let ids = rawValues.withUnsafeMutableBufferPointer {
        CFArrayCreate(kCFAllocatorDefault, $0.baseAddress, $0.count, nil)
    }
    guard let ids, let descriptions = descriptionReader(ids) as? [[String: Any]],
          descriptions.count == 1, let row = descriptions.first,
          (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID else {
        return .failure(.init(code: "cg_target_description_unavailable_or_mismatched"))
    }
    return .success(row)
}

/// Quartz defines an absent kCGWindowIsOnscreen key as not ordered on screen.
/// A present non-boolean is malformed, not a successful visibility observation.
func projectionWindowOnscreen(_ value: Any?) -> Result<Bool, ProjectionObservationFailure> {
    guard let value else { return .success(false) }
    guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else {
        return .failure(.init(code: "cg_target_visibility_malformed"))
    }
    return .success(flag)
}

/// @canonical projection_inventory_identity -- structural exclusion precedes
/// identity refusal. Desktop/pseudo-window titles never authorize exclusion.
/// A nil result excludes only a positively observed nonmanaged element; every
/// standard-window candidate still needs the exact owning PID and positive CG ID.
func projectionInventoryWindowIdentity(
    element: AXUIElement, pid: pid_t,
    readStringAttribute: (AXUIElement, CFString) -> Result<String, ProjectionObservationFailure> = liveProjectionInventoryStringAttribute,
    readIdentity: (AXUIElement) -> ProjectionAXWindowIdentity? = liveProjectionAXWindowIdentity,
    uptimeNs: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    configureTimeout: (AXUIElement) -> AXError = { AXUIElementSetMessagingTimeout($0, TargetedProjectionSnapshot.axReadTimeoutSeconds) },
    onClassification: (Bool) -> Void = { _ in }
) -> Result<ProjectionAXWindowIdentity?, ProjectionObservationFailure> {
    guard configureTimeout(element) == .success else {
        return .failure(.init(code: "ax_inventory_timeout_configuration_failed:pid=\(pid)"))
    }
    let started = uptimeNs()
    func withinBudget() -> Bool { uptimeNs() &- started < TargetedProjectionSnapshot.axTotalReadBudgetNs }
    guard withinBudget() else { return .failure(.init(code: "ax_inventory_classification_deadline_exceeded:pid=\(pid)")) }
    let role: String
    switch readStringAttribute(element, kAXRoleAttribute as CFString) {
    case .failure(let failure): return .failure(.init(code: failure.code + ":pid=\(pid)"))
    case .success(let value): role = value
    }
    guard !role.isEmpty else { return .failure(.init(code: "ax_inventory_role_unknown:pid=\(pid)")) }
    var standard = false
    if role == kAXWindowRole as String {
        guard withinBudget() else { return .failure(.init(code: "ax_inventory_classification_deadline_exceeded:pid=\(pid)")) }
        switch readStringAttribute(element, kAXSubroleAttribute as CFString) {
        case .failure(let failure): return .failure(.init(code: failure.code + ":pid=\(pid)"))
        case .success(let subrole):
            guard !subrole.isEmpty else { return .failure(.init(code: "ax_inventory_subrole_unknown:pid=\(pid)")) }
            standard = subrole == kAXStandardWindowSubrole as String
        }
    }
    guard withinBudget() else { return .failure(.init(code: "ax_inventory_classification_deadline_exceeded:pid=\(pid)")) }
    onClassification(standard)
    guard let identity = readIdentity(element) else {
        return standard ? .failure(.init(code: "ax_inventory_identity_unavailable:pid=\(pid)")) : .success(nil)
    }
    guard withinBudget() else { return .failure(.init(code: "ax_inventory_classification_deadline_exceeded:pid=\(pid)")) }
    guard identity.windowId > 0, identity.pid == pid, pid > 0 else {
        return .failure(.init(code: "ax_inventory_identity_mismatch:pid=\(pid)"))
    }
    return .success(identity)
}

/// The only live AX read adapter for projection. Per-call timeouts and a total
/// deadline stop hostile apps from turning observations into indefinite waits.
private struct LiveTargetedProjectionWindowReader: TargetedProjectionWindowReading {
    let sessionAvailable: @Sendable () -> Bool
    var supportsCacheAudit: Bool { true }
    func auditInventory(ignored: [ProjectionWindowHandle], beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        guardedInventory(enrollOwners: { _ in .success(()) }, ignored: ignored, beforeExternalCall: beforeExternalCall)
    }
    func auditRead(handle: ProjectionWindowHandle, beforeExternalCall: @escaping @Sendable () -> ProjectionObservationFailure?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        guardedRead(element: handle.element, pid: handle.pid, expectedWindowId: handle.windowId, beforeExternalCall: beforeExternalCall)
    }

    /// Exceptional one-owner enumeration; ordinary notifications never invoke this method.
    func freshWindowHandle(pid: pid_t, windowId: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        let started = DispatchTime.now().uptimeNanoseconds
        func beforeRead() -> ProjectionObservationFailure? {
            guard sessionAvailable() else { return .init(code: "session_locked") }
            guard projectionEffectRefreshBudgetAllowsCall(started: started, now: DispatchTime.now().uptimeNanoseconds) else {
                return .init(code: "effect_fresh_handle_deadline_exceeded")
            }
            return nil
        }
        guard pid > 0, windowId > 0 else { return .failure(.init(code: "effect_fresh_handle_identity_invalid")) }
        if let failure = beforeRead() { return .failure(failure) }
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, Self.refreshTimeoutSeconds) == .success else {
            return .failure(.init(code: "effect_fresh_handle_timeout_configuration_failed"))
        }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let windows = raw as? [AXUIElement] else {
            return .failure(.init(code: "effect_fresh_handle_inventory_failed:pid=\(pid):\(error.rawValue)"))
        }
        var candidates: [ProjectionWindowHandle] = []
        for element in windows {
            if let failure = beforeRead() { return .failure(failure) }
            guard AXUIElementSetMessagingTimeout(element, Self.refreshTimeoutSeconds) == .success else {
                return .failure(.init(code: "effect_fresh_handle_timeout_configuration_failed"))
            }
            switch liveProjectionAXWindowIdentityResult(element, beforeRead: beforeRead) {
            case .failure(let failure): return .failure(failure)
            case .success(let identity):
                candidates.append(.init(element: element, pid: identity.pid, windowId: Int64(identity.windowId)))
            }
        }
        guard sessionAvailable(), DispatchTime.now().uptimeNanoseconds - started <= TargetedProjectionSnapshot.effectRefreshTotalBudgetNs else {
            return .failure(.init(code: "effect_fresh_handle_deadline_exceeded"))
        }
        return projectionUniqueFreshWindowHandle(candidates, pid: pid, windowId: windowId)
    }
    private static let refreshTimeoutSeconds: Float = 0.1

    func inventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        guardedInventory(enrollOwners: enrollOwners, ignored: [], beforeExternalCall: { nil })
    }
    private func guardedInventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>,
                                  ignored: [ProjectionWindowHandle], beforeExternalCall: () -> ProjectionObservationFailure?)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return .failure(.init(code: "cg_bootstrap_read_failed")) }
        if let failure = beforeExternalCall() { return .failure(failure) }
        let applications = NSWorkspace.shared.runningApplications
        let systemOwners = Set(applications.filter {
            projectionIsSystemUIOwner(bundleIdentifier: $0.bundleIdentifier,
                executablePath: $0.executableURL?.standardizedFileURL.path)
        }.map(\.processIdentifier))
        let visible = rows.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid()
                && (($0[kCGWindowOwnerPID as String] as? NSNumber).map { !systemOwners.contains($0.int32Value) } ?? true)
        }
        let visibleIds = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.int64Value })
        var owners = Set(visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        if let failure = beforeExternalCall() { return .failure(failure) }
        owners.formUnion(applications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        owners.subtract(systemOwners)
        owners.remove(ProcessInfo.processInfo.processIdentifier)
        if case .failure(let failure) = enrollOwners(owners) { return .failure(failure) }
        var handles: [ProjectionWindowHandle] = []
        // A prior ignored label covers only an absent ID. Visible IDs need a
        // fresh positive classification; an omitted/dead AX wrapper is unknown.
        var ignoredIds = Set(ignored.map(\.windowId)).subtracting(visibleIds)
        var inventoryCounts: [String] = []
        for pid in owners.sorted() {
            guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
            if let failure = beforeExternalCall() { return .failure(failure) }
            let app = AXUIElementCreateApplication(pid)
            guard AXUIElementSetMessagingTimeout(app, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
                return .failure(.init(code: "ax_inventory_timeout_configuration_failed"))
            }
            var raw: CFTypeRef?
            if let failure = beforeExternalCall() { return .failure(failure) }
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
            if error == .noValue { inventoryCounts.append("\(pid)=no_value"); continue }
            guard error == .success, let windows = raw as? [AXUIElement] else {
                return .failure(.init(code: "ax_inventory_read_failed:pid=\(pid):\(error.rawValue)"))
            }
            inventoryCounts.append("\(pid)=\(windows.count)")
            for element in windows {
                guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
                let knownIgnored = ignored.first { $0.pid == pid && CFEqual($0.element, element) }
                if let knownIgnored, !visibleIds.contains(knownIgnored.windowId) { continue }
                var standard = true
                if let failure = beforeExternalCall() { return .failure(failure) }
                switch projectionInventoryWindowIdentity(element: element, pid: pid, readStringAttribute: { element, attribute in
                    if let failure = beforeExternalCall() { return .failure(failure) }
                    return liveProjectionInventoryStringAttribute(element, attribute)
                }, readIdentity: { element in
                    try? liveProjectionAXWindowIdentityResult(element, beforeRead: beforeExternalCall).get()
                }, configureTimeout: { element in
                    if beforeExternalCall() != nil { return .cannotComplete }
                    return AXUIElementSetMessagingTimeout(element, TargetedProjectionSnapshot.axReadTimeoutSeconds)
                }, onClassification: { standard = $0 }) {
                case .failure(let failure):
                    // Invisible known rows were already excluded above. A
                    // CG-visible expired wrapper cannot certify that numeric ID.
                    return .failure(failure)
                case .success(let identity):
                    if let identity {
                        if !standard { ignoredIds.insert(Int64(identity.windowId)) }
                        else { ignoredIds.remove(Int64(identity.windowId)) }
                        handles.append(.init(element: element, pid: pid, windowId: Int64(identity.windowId)))
                    }
                }
            }
        }
        let observedIds = Set(handles.map(\.windowId))
        guard visibleIds.subtracting(observedIds.union(ignoredIds)).isEmpty else {
            let missing = visible.filter { row in
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.int64Value else { return true }
                return !observedIds.contains(id)
            }.map { row in
                "id=\((row[kCGWindowNumber as String] as? NSNumber)?.int64Value ?? 0),pid=\((row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)"
            }.joined(separator: ";")
            return .failure(.init(code: "world_visible_window_set_incomplete:\(missing):observed=\(observedIds.sorted()):inventory=\(inventoryCounts.joined(separator: ","))"))
        }
        return .success(.init(handles: handles, visibleWindowIds: visibleIds, ownerPids: owners, ignoredWindowIds: ignoredIds))
    }
    func focusedElement(pid: pid_t) -> Result<AXUIElement?, ProjectionObservationFailure> {
        guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            return .failure(.init(code: "ax_timeout_configuration_failed"))
        }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw)
        if error == .noValue || (error == .success && raw == nil) { return .success(nil) }
        guard error == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return .failure(.init(code: "ax_focused_window_read_failed:\(error.rawValue)"))
        }
        return .success(unsafeDowncast(raw, to: AXUIElement.self))
    }

    func read(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        guardedRead(element: element, pid: pid, expectedWindowId: expectedWindowId, beforeExternalCall: { nil })
    }
    private func guardedRead(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?, beforeExternalCall: () -> ProjectionObservationFailure?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
        guard let element else { return .failure(.init(code: "ax_notification_element_missing")) }
        guard AXUIElementSetMessagingTimeout(element, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            return .failure(.init(code: "ax_timeout_configuration_failed"))
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + TargetedProjectionSnapshot.axTotalReadBudgetNs
        var stage = "initial_identity"
        func prepareRead() -> ProjectionObservationFailure? {
            if let failure = beforeExternalCall() { return failure }
            let now = DispatchTime.now().uptimeNanoseconds
            return projectionAXReadBudgetAllowsCall(started: started, now: now)
                ? nil : .init(code: "ax_read_deadline_exceeded:stage=\(stage):elapsed_ns=\(now >= started ? now - started : 0)")
        }
        let identity: ProjectionAXWindowIdentity
        switch liveProjectionAXWindowIdentityResult(element, beforeRead: prepareRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): identity = value
        }
        guard identity.pid == pid,
              expectedWindowId == nil || expectedWindowId == Int64(identity.windowId) else {
            return .failure(.init(code: "ax_notification_identity_mismatch:expected=\(expectedWindowId.map(String.init) ?? "none"),observed=\(identity.windowId),pid=\(pid),owner=\(identity.pid)"))
        }
        guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
        stage = "attribute_batch"
        if let failure = prepareRead() { return .failure(failure) }
        var copiedValues: CFArray?
        let batchError = AXUIElementCopyMultipleAttributeValues(element, projectionWindowReadAttributes() as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &copiedValues)
        guard batchError == .success else { return .failure(.init(code: "ax_attribute_batch_read_failed:\(batchError.rawValue)")) }
        let attributes: ProjectionWindowAttributeBatch
        switch projectionDecodeWindowAttributes(copiedValues) {
        case .failure(let failure): return .failure(failure)
        case .success(let decoded): attributes = decoded
        }
        var resizable = DarwinBoolean(false)
        var movable = DarwinBoolean(false)
        stage = "size_capability"
        if let failure = prepareRead() { return .failure(failure) }
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
        guard sizeError == .success, DispatchTime.now().uptimeNanoseconds < deadline else {
            return .failure(.init(code: "ax_capability_read_failed:AXSize:\(sizeError.rawValue)"))
        }
        stage = "position_capability"
        if let failure = prepareRead() { return .failure(failure) }
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable)
        guard positionError == .success else {
            return .failure(.init(code: "ax_capability_read_failed:AXPosition:\(positionError.rawValue)"))
        }
        let finalIdentity: ProjectionAXWindowIdentity
        stage = "final_identity"
        switch liveProjectionAXWindowIdentityResult(element, beforeRead: prepareRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): finalIdentity = value
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            return .failure(.init(code: "ax_read_deadline_exceeded"))
        }
        guard finalIdentity == identity else {
            return .failure(.init(code: "ax_identity_changed_during_read"))
        }
        // Request only this exact ID. List options select relative window
        // lists, not a single-window description. Owner must agree with AX.
        guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
        let row: [String: Any]
        if let failure = beforeExternalCall() { return .failure(failure) }
        switch projectionNamedWindowDescription(windowID: identity.windowId) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): row = value
        }
        guard
              (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowId,
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let ownerName = row[kCGWindowOwnerName as String] as? String else {
            let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return .failure(.init(code: "cg_target_identity_read_failed:id=\(identity.windowId),pid=\(pid),owner=\(owner),onscreen=\(row[kCGWindowIsOnscreen as String] != nil),owner_name=\(row[kCGWindowOwnerName as String] != nil)"))
        }
        let onscreen: Bool
        switch projectionWindowOnscreen(row[kCGWindowIsOnscreen as String]) {
        case .failure(let failure): return .failure(failure)
        case .success(let visible): onscreen = visible
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            return .failure(.init(code: "ax_read_deadline_exceeded"))
        }
        return .success(TargetedWindowObservation(
            windowId: Int64(identity.windowId), pid: pid,
            frame: attributes.frame, role: attributes.role, subrole: attributes.subrole, title: attributes.title,
            resizable: resizable.boolValue, movable: movable.boolValue, minimized: attributes.minimized,
            onscreen: onscreen, appName: ownerName))
    }
}

/// @canonical projection_space_observation -- independent OS Space UUIDs and
/// per-display current membership. Runtime counters and kCGWindowWorkspace are
/// never substituted. Private read ABI follows yabai/src/misc/extern.h and
/// Hammerspoon/extensions/spaces/libspaces.m; missing support fails closed.
final class IndependentProjectionSpaceObserver: ProjectionSpaceObserving, @unchecked Sendable {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyWindowDisplay = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    private typealias CurrentDisplaySpace = @convention(c) (Int32, CFString) -> UInt64
    private struct Space: Sendable { let key: String; let displayId: String; let visible: Bool }
    private let handle: UnsafeMutableRawPointer?
    private let connection: MainConnection?
    private let displays: CopyDisplaySpaces?
    private let windows: CopyWindowSpaces?
    private let windowDisplay: CopyWindowDisplay?
    private let currentSpace: CurrentDisplaySpace?
    private var spaces: [UInt64: Space] = [:]
    private var baselineFailure: ProjectionObservationFailure? = .init(code: "space_not_baselined")

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        self.handle = handle
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connection = symbol("SLSMainConnectionID", as: MainConnection.self)
        displays = symbol("SLSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
        windows = symbol("SLSCopySpacesForWindows", as: CopyWindowSpaces.self)
        windowDisplay = symbol("SLSCopyManagedDisplayForWindow", as: CopyWindowDisplay.self)
        currentSpace = symbol("SLSManagedDisplayGetCurrentSpace", as: CurrentDisplaySpace.self)
    }

    deinit { if let handle { dlclose(handle) } }

    /// Freeze the UUID namespace on the canonical lane; utility work reads only this immutable
    /// copy and immutable function pointers, never the observer's mutable baseline dictionaries.
    func makeAuditProbe() -> (@Sendable (Int64, @escaping @Sendable () -> ProjectionObservationFailure?) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>)? {
        guard baselineFailure == nil, connection != nil, windows != nil, windowDisplay != nil, currentSpace != nil else { return nil }
        let namespace = spaces
        return { [self] id, beforeCall in
            guard id > 0, id <= Int64(UInt32.max) else { return .failure(.init(code: "cache_audit_space_identity_invalid")) }
            if let failure = beforeCall() { return .failure(failure) }
            let cid = self.connection!()
            if let failure = beforeCall() { return .failure(failure) }
            guard let raw = self.windows!(cid, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue(),
                  let memberships = raw as? [NSNumber], memberships.count == 1,
                  let space = namespace[memberships[0].uint64Value] else { return .failure(.init(code: "cache_audit_space_unknown")) }
            if let failure = beforeCall() { return .failure(failure) }
            guard let display = self.windowDisplay!(cid, UInt32(id))?.takeRetainedValue(),
                  display as String == space.displayId else { return .failure(.init(code: "cache_audit_display_changed")) }
            if let failure = beforeCall() { return .failure(failure) }
            let current = self.currentSpace!(cid, display)
            guard current > 0 else { return .failure(.init(code: "cache_audit_space_unknown")) }
            return .success(.init(key: space.key, displayId: space.displayId, visible: current == memberships[0].uint64Value))
        }
    }

    func rebaseline() -> Result<Void, ProjectionObservationFailure> {
        spaces.removeAll()
        guard let connection, let displays, windows != nil, windowDisplay != nil, currentSpace != nil,
              let raw = displays(connection())?.takeRetainedValue(),
              let rows = raw as? [[String: Any]], !rows.isEmpty else {
            baselineFailure = .init(code: "independent_space_observation_unavailable")
            return .failure(baselineFailure!)
        }
        var next: [UInt64: Space] = [:]
        for row in rows {
            guard let display = row["Display Identifier"] as? String, !display.isEmpty,
                  let current = row["Current Space"] as? [String: Any],
                  let currentId = (current["ManagedSpaceID"] as? NSNumber ?? current["id64"] as? NSNumber)?.uint64Value,
                  let entries = row["Spaces"] as? [[String: Any]], !entries.isEmpty else {
                baselineFailure = .init(code: "independent_display_space_incomplete")
                return .failure(baselineFailure!)
            }
            for entry in entries {
                guard let type = entry["type"] as? Int else {
                    baselineFailure = .init(code: "independent_space_type_unknown")
                    return .failure(baselineFailure!)
                }
                if type != 0 { continue }
                guard let id = (entry["ManagedSpaceID"] as? NSNumber ?? entry["id64"] as? NSNumber)?.uint64Value,
                      id > 0, let uuid = entry["uuid"] as? String, !uuid.isEmpty else {
                    baselineFailure = .init(code: "independent_space_identity_incomplete")
                    return .failure(baselineFailure!)
                }
                // Native fullscreen and tiled system Spaces are outside the
                // desktop eligibility contract; no active desktop is invented.
                guard next[id] == nil else {
                    baselineFailure = .init(code: "independent_space_identity_ambiguous")
                    return .failure(baselineFailure!)
                }
                next[id] = Space(key: "space:uuid:\(uuid)", displayId: display, visible: id == currentId)
            }
        }
        spaces = next
        baselineFailure = nil
        return .success(())
    }

    func context(windowId: Int64) -> Result<ProjectionSpaceContext, ProjectionObservationFailure> {
        if let baselineFailure { return .failure(baselineFailure) }
        guard windowId > 0, windowId <= Int64(UInt32.max), let connection, let windows,
              let windowDisplay, let currentSpace else { return .failure(.init(code: "independent_space_observation_unavailable")) }
        let cid = connection()
        let ids = [NSNumber(value: windowId)] as CFArray
        guard let raw = windows(cid, 0x7, ids)?.takeRetainedValue(),
              let memberships = raw as? [NSNumber], memberships.count == 1,
              let space = spaces[memberships[0].uint64Value],
              let rawDisplay = windowDisplay(cid, UInt32(windowId))?.takeRetainedValue(),
              (rawDisplay as String) == space.displayId else {
            return .failure(.init(code: "independent_window_space_unknown_or_ambiguous"))
        }
        let activeId = currentSpace(cid, rawDisplay)
        guard activeId > 0 else { return .failure(.init(code: "independent_current_display_space_unavailable")) }
        return .success(.init(key: space.key, displayId: space.displayId,
                             visible: memberships[0].uint64Value == activeId))
    }

    /// The only no-window Space target is an exact OS display UUID. Omitted
    /// display selection succeeds for one independently observed display only.
    func currentSpaceContext(displayUUID: String? = nil)
        -> Result<ProjectionSpaceContext, ProjectionObservationFailure> {
        if let baselineFailure { return .failure(baselineFailure) }
        let displayIds = Set(spaces.values.map(\.displayId))
        let display: String
        if let displayUUID, displayIds.contains(displayUUID) { display = displayUUID }
        else if displayUUID == nil, displayIds.count == 1 { display = displayIds.first! }
        else { return .failure(.init(code: "independent_current_display_target_ambiguous")) }
        guard let connection, let currentSpace,
              let space = spaces[currentSpace(connection(), display as CFString)] else {
            return .failure(.init(code: "independent_current_display_space_unavailable"))
        }
        return .success(.init(key: space.key, displayId: display, visible: true))
    }

    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure> {
        if let baselineFailure { return .failure(baselineFailure) }
        var contexts: [ProjectionSpaceContext] = []
        for display in Set(spaces.values.map(\.displayId)).sorted() {
            switch currentSpaceContext(displayUUID: display) {
            case .success(let context): contexts.append(context)
            case .failure(let failure): return .failure(failure)
            }
        }
        guard !contexts.isEmpty else { return .failure(.init(code: "independent_current_display_space_unavailable")) }
        return .success(contexts)
    }
}

/// A serial observation lane owns this object. Every ordinary event reads its
/// exact target. A complete cache additionally requires all-app lifecycle
/// registration and an independently observed Space for every eligible window.
final class TargetedProjectionSnapshot: @unchecked Sendable {
    static let effectRefreshMessageBudgetNs: UInt64 = 100_000_000
    static let effectRefreshTotalBudgetNs: UInt64 = 200_000_000
    static let axMessageBudgetNs: UInt64 = 100_000_000
    static let axReadTimeoutSeconds: Float = 0.1
    static let axTotalReadBudgetNs: UInt64 = 200_000_000
    private let trusted: @Sendable () -> Bool
    private let sessionAvailable: @Sendable () -> Bool
    private let sessionGeneration: @Sendable () -> UInt64
    private let reader: any TargetedProjectionWindowReading
    private let spaces: any ProjectionSpaceObserving
    private let spaceEnabled: @Sendable (String) -> Bool
    private let rules: JSONValue
    private let displayTopologyReader: ProjectionDisplayTopologyRead
    private let identityIsCurrent: @Sendable (ProjectionWindowHandle) -> Bool
    private let identityProof: @Sendable (ProjectionWindowHandle) -> Result<Bool, ProjectionObservationFailure>
    private let elementsMatch: @Sendable (AXUIElement, AXUIElement) -> Bool
    private let worldObserver: (any ProjectionWorldObserving)?
    var onWorldEvent: (@Sendable (AccessibilityFocusEvent) -> Void)? {
        didSet {
            worldEventLock.lock()
            worldEventDelivery = onWorldEvent
            worldEventLock.unlock()
            worldObserver?.onEvent = { [weak self] in self?.forwardWorldEvent($0) }
        }
    }
    // Lifecycle sources survive foreground/Space feed rebindings. The lock is
    // only the callback-to-serial-lane bridge; window authority stays on that lane.
    private let worldEventLock = NSLock()
    private var worldEventDelivery: (@Sendable (AccessibilityFocusEvent) -> Void)?
    private var worldObserverGeneration: UInt64 = 0
    private var worldFeedGeneration: UInt64 = 0
    private var worldObservationActive = false
    private var handles: [Int64: ProjectionWindowHandle] = [:]
    private var cachedWindows: [Int64: JSONObject] = [:]
    private var ownerPids: Set<pid_t> = []
    private var observedOwnerPids: Set<pid_t> = []
    private var coveredWindowIds: Set<Int64> = []
    private var cachedTopology: [JSONValue] = []
    private var usableDisplayFrames: [String: Frame] = [:]
    private var focusId: Int64?
    private struct WindowLifetime {
        let pid: pid_t
        let generation: UInt64
    }
    private var windowLifetimes: [Int64: WindowLifetime] = [:]
    private var nextWindowLifetime: UInt64 = 0
    private var latestTargetObservation: JSONObject = [:]
    private var observerGeneration: UInt64 = 0
    private var worldComplete = false
    private var worldFailure: ProjectionObservationFailure? = .init(code: "world_not_seeded")
    private var count: Int64 = 0
    private var fullEnumerations: Int64 = 0
    private var targetedReads: Int64 = 0
    private var failures: Int64 = 0
    private var spaceBaselines: Int64 = 0
    private var displayEnumerations: Int64 = 0
    private var effectHandleRefreshes: Int64 = 0
    private let auditLock = NSLock()
    private var auditActivityRevision: UInt64 = 0
    private var auditEnumerations: Int64 = 0
    private var auditReads: Int64 = 0
    private var auditDisplays: Int64 = 0
    private func markAuditActivity() { auditLock.lock(); auditActivityRevision &+= 1; auditLock.unlock() }
    private var currentAuditRevision: UInt64 { auditLock.lock(); defer { auditLock.unlock() }; return auditActivityRevision }

    /// The canonical lane freezes one valid cohort; collection is strictly read-only and guarded
    /// before each backend call. An unsupported backend cannot certify a clean audit.
    func makeCacheAuditSeed(observerGeneration: UInt64, observationEpoch: UInt64) -> Result<ProjectionCacheAuditSeed, ProjectionObservationFailure> {
        guard sessionAvailable(), trusted(), worldComplete, worldObservationActive, self.observerGeneration == observerGeneration else {
            return .failure(.init(code: "cache_audit_authority_unavailable"))
        }
        guard reader.supportsCacheAudit, let spaceProbe = spaces.makeAuditProbe() else { return .failure(.init(code: "cache_audit_backend_unsupported")) }
        let revision = currentAuditRevision, session = sessionGeneration(), owners = ownerPids
        let observed = cachedWindows, retained = handles, reader = reader, matches = elementsMatch, rules = rules
        let topologyReader = displayTopologyReader, topology = cachedTopology, usable = usableDisplayFrames
        let ignored = retained.values.filter { handle in
            guard let record = observed[handle.windowId], let role = record["role"]?.stringValue, let subrole = record["subrole"]?.stringValue else { return false }
            return role != "AXWindow" || subrole != "AXStandardWindow"
        }
        let expected = Set(observed.filter { $0.value["eligible"]?.boolValue == true }.map(\.key))
        guard !expected.isEmpty else { return .failure(.init(code: "cache_audit_empty_cohort_unsupported")) }
        guard expected.allSatisfy({ id in
            guard let handle = retained[id], let lifetime = windowLifetimes[id], let record = observed[id] else { return false }
            return coveredWindowIds.contains(id) && lifetime.pid == handle.pid && lifetime.generation > 0
                && record["window_generation"]?.intValue == Int64(clamping: lifetime.generation)
        }) else { return .failure(.init(code: "cache_audit_lifetime_authority_unavailable")) }
        let alive: @Sendable () -> Bool = { [self] in
            currentAuditRevision == revision && sessionAvailable() && sessionGeneration() == session && trusted()
        }
        return .success(.init(observerGeneration: observerGeneration, sessionGeneration: session, observationEpoch: observationEpoch,
            activityRevision: revision, isCurrent: alive, collect: { beforeCall, recordCost in
                var enumerations: Int64 = 0, reads: Int64 = 0, displays: Int64 = 0
                func failed(_ failure: ProjectionObservationFailure) -> ProjectionCacheAuditProbe { .init(failure: failure, enumerations: enumerations, reads: reads, displayEnumerations: displays) }
                if let failure = beforeCall() { return failed(failure) }
                displays = 1; recordCost(enumerations, reads, displays)
                switch topologyReader(usable, beforeCall) {
                case .failure(let failure): return failed(failure)
                case .success(let current):
                    guard current == topology else { return failed(.init(code: "cache_audit_topology_changed")) }
                }
                enumerations = 1; recordCost(enumerations, reads, displays)
                let inventory: ProjectionWindowInventory
                switch reader.auditInventory(ignored: ignored, beforeExternalCall: beforeCall) {
                case .failure(let failure): return failed(failure)
                case .success(let value): inventory = value
                }
                guard inventory.ownerPids == owners else { return failed(.init(code: "cache_audit_owner_cohort_changed")) }
                var actual: Set<Int64> = []
                for handle in inventory.handles.sorted(by: { $0.windowId < $1.windowId }) where inventory.visibleWindowIds.contains(handle.windowId)
                    && !inventory.ignoredWindowIds.contains(handle.windowId) {
                    if let failure = beforeCall() { return failed(failure) }
                    reads += 1; recordCost(enumerations, reads, displays)
                    let window: TargetedWindowObservation
                    switch reader.auditRead(handle: handle, beforeExternalCall: beforeCall) {
                    case .failure(let failure): return failed(failure)
                    case .success(let value): window = value
                    }
                    guard window.windowId == handle.windowId, window.pid == handle.pid else { return failed(.init(code: "cache_audit_read_identity_changed")) }
                    let tileable: JSONValue = .object(["role": .string(window.role), "subrole": .string(window.subrole),
                        "resizable": .bool(window.resizable), "app": .string(window.appName), "title": .string(window.title)])
                    if !window.onscreen || window.minimized || !window.movable || !Autotile.tileable(tileable, rules) { continue }
                    guard actual.insert(window.windowId).inserted, let prior = retained[window.windowId],
                          prior.pid == window.pid, matches(prior.element, handle.element), let record = observed[window.windowId] else {
                        return failed(.init(code: "cache_audit_new_or_changed_identity"))
                    }
                    switch spaceProbe(window.windowId, beforeCall) {
                    case .failure(let failure): return failed(failure)
                    case .success(let context):
                        guard context.visible, context.key == record["space_key"]?.stringValue,
                              context.displayId == record["display_id"]?.stringValue else { return failed(.init(code: "cache_audit_space_changed")) }
                    }
                    guard let priorFrame = Frame.from(record["frame"]), Geometry.frameEq(priorFrame, window.frame, tol: 1) else {
                        return failed(.init(code: "cache_audit_frame_changed"))
                    }
                }
                if let failure = beforeCall() { return failed(failure) }
                guard actual == expected else { return failed(.init(code: "cache_audit_managed_cohort_changed")) }
                return .init(failure: nil, enumerations: enumerations, reads: reads, displayEnumerations: displays)
            }))
    }

    /// Observation-lane completion. A clean audit publishes evidence only; uncertain current
    /// evidence fences authority and requests the existing explicit recovery, never a layout replay.
    func finishCacheAudit(seed: ProjectionCacheAuditSeed, probe: ProjectionCacheAuditProbe) -> JSONObject {
        fullEnumerations += probe.enumerations; targetedReads += probe.reads
        auditEnumerations += probe.enumerations; auditReads += probe.reads
        displayEnumerations += probe.displayEnumerations; auditDisplays += probe.displayEnumerations
        let current = seed.isCurrent() && self.observerGeneration == seed.observerGeneration
        let superseded = !current || probe.failure?.code == "cache_audit_superseded"
        let status = superseded ? "superseded" : probe.failure == nil ? "clean" : "failed"
        var delta: JSONObject = ["event": .string("cache_audit_completed"), "cache_audit_requires_recovery": .bool(false), "cache_integrity": .object([
            "status": .string(status), "failure_code": probe.failure.map { .string($0.code) } ?? .null,
            "enumeration_count": .int(auditEnumerations), "targeted_read_count": .int(auditReads),
            "display_enumeration_count": .int(auditDisplays),
            "observer_generation": .int(Int64(clamping: seed.observerGeneration)), "session_generation": .int(Int64(clamping: seed.sessionGeneration)),
            "observation_epoch": .int(Int64(clamping: seed.observationEpoch)), "activity_revision": .int(Int64(clamping: seed.activityRevision))])]
        if !superseded, let failure = probe.failure {
            markAuditActivity(); revokeWorldObservation(failure, generation: seed.observerGeneration)
            delta["focus"] = .null
            delta["observation"] = .object(["world_complete": .bool(false), "failure_code": .string(failure.code), "world_failure_code": .string(failure.code),
                "session_generation": .int(Int64(clamping: sessionGeneration()))])
            delta["cache_audit_requires_recovery"] = .bool(true)
        }
        return delta
    }

    convenience init(trusted: Bool, spaceEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
                     rules: JSONValue = .array([]),
                     sessionAvailable: @escaping @Sendable () -> Bool = { true },
                     sessionGeneration: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.init(trustedProvider: { trusted && AXIsProcessTrusted() }, spaceEnabled: spaceEnabled,
            rules: rules, sessionAvailable: sessionAvailable, sessionGeneration: sessionGeneration)
    }

    convenience init(trustedProvider: @escaping @Sendable () -> Bool,
                     spaceEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
                     rules: JSONValue = .array([]),
                     sessionAvailable: @escaping @Sendable () -> Bool = { true },
                     sessionGeneration: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.init(trusted: trustedProvider,
                  reader: LiveTargetedProjectionWindowReader(sessionAvailable: sessionAvailable),
                  spaces: IndependentProjectionSpaceObserver(), spaceEnabled: spaceEnabled,
                  rules: rules, worldObserver: AccessibilityWorldObserver(trustedProvider: { trustedProvider() && sessionAvailable() }),
                  sessionAvailable: sessionAvailable, sessionGeneration: sessionGeneration)
    }

    init(trusted: @escaping @Sendable () -> Bool,
         reader: any TargetedProjectionWindowReading,
         spaces: any ProjectionSpaceObserving,
         spaceEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
         rules: JSONValue = .array([]), worldObserver: (any ProjectionWorldObserving)? = nil,
         identityIsCurrent: (@Sendable (ProjectionWindowHandle) -> Bool)? = nil,
         elementsMatch: @escaping @Sendable (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) },
         sessionAvailable: @escaping @Sendable () -> Bool = { true },
         sessionGeneration: @escaping @Sendable () -> UInt64 = { 0 },
         displayTopologyReader: @escaping ProjectionDisplayTopologyRead = projectionReadDisplayTopology) {
        self.trusted = trusted
        self.sessionAvailable = sessionAvailable
        self.sessionGeneration = sessionGeneration
        self.reader = reader
        self.spaces = spaces
        self.spaceEnabled = spaceEnabled
        self.rules = rules
        self.displayTopologyReader = displayTopologyReader
        self.worldObserver = worldObserver
        let proof: @Sendable (ProjectionWindowHandle) -> Result<Bool, ProjectionObservationFailure>
        if let identityIsCurrent { proof = { .success(identityIsCurrent($0)) } }
        else { proof = { handle in
            liveProjectionAXWindowIdentityResult(handle.element).map {
                $0 == ProjectionAXWindowIdentity(windowId: CGWindowID(handle.windowId), pid: handle.pid)
            }
        } }
        self.identityProof = proof
        self.identityIsCurrent = { handle in
            if case .success(true) = proof(handle) { return true }
            return false
        }
        self.elementsMatch = elementsMatch
    }

    private func forwardWorldEvent(_ event: AccessibilityFocusEvent) {
        worldEventLock.lock()
        let delivery = worldEventDelivery
        let feedGeneration = worldFeedGeneration
        let admitted = worldObservationActive && event.generation == worldObserverGeneration
        worldEventLock.unlock()
        guard admitted, sessionAvailable() else { return }
        delivery?(AccessibilityFocusEvent(kind: event.kind, pid: event.pid, generation: feedGeneration,
            windowGeneration: event.windowGeneration, element: event.element, windowId: event.windowId,
            receiptUptimeNs: event.receiptUptimeNs, isWorldObservation: true, degradedReason: event.degradedReason,
            sourceObserverGeneration: event.generation))
    }

    private func updateWorldFeedGeneration(_ generation: UInt64) {
        worldEventLock.lock()
        worldFeedGeneration = generation
        worldEventLock.unlock()
    }

    /// A stopped source cannot distinguish a survivor from same-PID ID reuse.
    /// Retire its tokens before recovery, including windows absent from a cache.
    private func revokeWorldObservation(_ failure: ProjectionObservationFailure, generation: UInt64) {
        worldEventLock.lock()
        worldObservationActive = false
        worldFeedGeneration = generation
        worldEventLock.unlock()
        worldObserver?.stop(generation: worldObserverGeneration)
        worldComplete = false
        worldFailure = failure
        focusId = nil
        cachedWindows.removeAll()
        handles.removeAll()
        ownerPids.removeAll()
        observedOwnerPids.removeAll()
        coveredWindowIds.removeAll()
        windowLifetimes.removeAll()
    }

    private func retireWindow(_ id: Int64) {
        windowLifetimes.removeValue(forKey: id)
        handles.removeValue(forKey: id)
        cachedWindows.removeValue(forKey: id)
        coveredWindowIds.remove(id)
        if focusId == id { focusId = nil }
    }

    /// Resolves an already observed member without enumeration. Failure revokes
    /// authorization: no stale AX wrapper, recycled ID, or old context is used.
    var windowGenerations: [String: UInt64] {
        Dictionary(uniqueKeysWithValues: cachedWindows.keys.compactMap { id in
            windowLifetimes[id].map { (String(id), $0.generation) }
        })
    }

    func resolveWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        markAuditActivity()
        let session = sessionGeneration()
        guard sessionAvailable() else {
            sessionUnavailable()
            return .failure(.init(code: "session_locked"))
        }
        guard trusted() else {
            let failure = ProjectionObservationFailure(code: "ax_untrusted")
            revokeWorldObservation(failure, generation: observerGeneration)
            return .failure(failure)
        }
        guard observerGeneration == self.observerGeneration else {
            return .failure(.init(code: "window_resolver_generation_mismatch"))
        }
        if let expectedWindowGeneration, windowLifetimes[windowId]?.generation != expectedWindowGeneration {
            return .failure(.init(code: "window_resolver_lifetime_generation_mismatch"))
        }
        guard worldComplete, worldObservationActive, coveredWindowIds.contains(windowId), let handle = handles[windowId],
              let record = cachedWindows[windowId], record["eligible"]?.boolValue == true,
              record["space_visible"]?.boolValue == true,
              let key = record["space_key"]?.stringValue, spaceEnabled(key) else {
            return .failure(.init(code: "window_resolver_authority_unavailable"))
        }
        guard AXUIElementSetMessagingTimeout(handle.element, Self.axReadTimeoutSeconds) == .success else {
            return .failure(.init(code: "ax_timeout_configuration_failed"))
        }
        let identityFailure: ProjectionObservationFailure?
        switch identityProof(handle) {
        case .success(true): identityFailure = nil
        case .success(false): identityFailure = .init(code: "window_resolver_identity_changed")
        case .failure(let failure): identityFailure = failure
        }
        if let identityFailure {
            retireWindow(windowId)
            worldComplete = false
            worldFailure = identityFailure
            return .failure(identityFailure)
        }
        guard sessionAvailable(), sessionGeneration() == session else {
            sessionUnavailable()
            return .failure(.init(code: "session_locked"))
        }
        switch spaces.context(windowId: windowId) {
        case .failure(let failure):
            retireWindow(windowId)
            worldComplete = false
            worldFailure = failure
            return .failure(failure)
        case .success(let context):
            guard context.key == key, context.displayId == record["display_id"]?.stringValue,
                  context.visible, spaceEnabled(context.key) else {
                retireWindow(windowId)
                worldComplete = false
                worldFailure = .init(code: "window_resolver_space_changed")
                return .failure(worldFailure!)
            }
        }
        guard sessionAvailable(), sessionGeneration() == session else {
            sessionUnavailable()
            return .failure(.init(code: "session_locked"))
        }
        return .success(handle)
    }

    /// Completes an effect by the same targeted reader used for notifications;
    /// a setter response itself is never represented as landed evidence.
    func readWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        readWindowWithHandle(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration).map(\.observation)
    }

    /// Canonical read/handle pairing. A caller that needs a setter handle must not resolve again
    /// around this read: the returned handle passed the same lifetime/session/Space admission gate.
    func readWindowWithHandle(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<ProjectionWindowReadback, ProjectionObservationFailure> {
        let session = sessionGeneration()
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle):
            targetedReads += 1
            let result = reader.read(element: handle.element, pid: handle.pid, expectedWindowId: windowId)
            guard sessionAvailable(), sessionGeneration() == session else {
                sessionUnavailable()
                return .failure(.init(code: "session_locked"))
            }
            switch result {
            case .failure(let failure):
                retireWindow(windowId)
                worldComplete = false
                worldFailure = failure
                return .failure(failure)
            case .success(let window):
                guard window.windowId == windowId, window.pid == handle.pid else {
                    retireWindow(windowId)
                    worldComplete = false
                    worldFailure = .init(code: "ax_notification_identity_mismatch")
                    return .failure(worldFailure!)
                }
                let request = ProjectionSnapshotRequest(reason: "effect_readback", application: nil,
                    observerGeneration: observerGeneration, accessibilityEvent: nil)
                switch windowObject(window, request: request, appName: cachedWindows[windowId]?["app"]?.stringValue ?? "") {
                case .success(let object): cachedWindows[windowId] = object
                case .failure(let failure):
                    retireWindow(windowId)
                    worldComplete = false
                    worldFailure = failure
                    return .failure(failure)
                }
                return .success(.init(handle: handle, observation: window, observerGeneration: observerGeneration,
                                      completedUptimeNs: DispatchTime.now().uptimeNanoseconds))
            }
        }
    }

    /// A once-per-effect repair preserves its concrete lifecycle source and lifetime. This method
    /// never rebuilds the world or replaces an unequal AX element using only matching PID/CG IDs.
    func refreshEffectWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64)
        -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        let session = sessionGeneration()
        let retained: ProjectionWindowHandle
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle): retained = handle
        }
        guard expectedWindowGeneration > 0, let prior = cachedWindows[windowId] else {
            return .failure(.init(code: "effect_refresh_lifetime_unavailable"))
        }
        effectHandleRefreshes += 1
        let fresh: ProjectionWindowHandle
        switch reader.freshWindowHandle(pid: retained.pid, windowId: windowId) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle): fresh = handle
        }
        guard fresh.pid == retained.pid, fresh.windowId == windowId,
              elementsMatch(retained.element, fresh.element) else {
            return .failure(.init(code: "effect_refresh_registered_identity_changed"))
        }
        switch identityProof(fresh) {
        case .failure(let failure): return .failure(failure)
        case .success(false): return .failure(.init(code: "effect_refresh_fresh_identity_changed"))
        case .success(true): break
        }
        targetedReads += 1
        let observed: TargetedWindowObservation
        switch reader.read(element: fresh.element, pid: fresh.pid, expectedWindowId: windowId) {
        case .failure(let failure): return .failure(failure)
        case .success(let window): observed = window
        }
        guard sessionAvailable(), sessionGeneration() == session else {
            sessionUnavailable(); return .failure(.init(code: "session_locked"))
        }
        guard observed.windowId == windowId, observed.pid == retained.pid else {
            return .failure(.init(code: "effect_refresh_read_identity_changed"))
        }
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let current):
            guard elementsMatch(current.element, retained.element) else {
                return .failure(.init(code: "effect_refresh_retained_identity_changed"))
            }
        }
        let request = ProjectionSnapshotRequest(reason: "effect_handle_refresh", application: nil,
            observerGeneration: observerGeneration, accessibilityEvent: nil)
        let object: JSONObject
        switch windowObject(observed, request: request, appName: prior["app"]?.stringValue ?? "") {
        case .failure(let failure): return .failure(failure)
        case .success(let value): object = value
        }
        guard trusted(), sessionAvailable(), sessionGeneration() == session,
              self.observerGeneration == observerGeneration,
              windowLifetimes[windowId]?.generation == expectedWindowGeneration,
              object["eligible"]?.boolValue == true, object["space_visible"]?.boolValue == true,
              object["space_enabled"]?.boolValue == true,
              object["space_key"] == prior["space_key"], object["display_id"] == prior["display_id"] else {
            return .failure(.init(code: "effect_refresh_context_changed"))
        }
        handles[windowId] = fresh; cachedWindows[windowId] = object
        return .success(fresh)
    }

    func stop() {
        markAuditActivity()
        revokeWorldObservation(.init(code: "world_observation_stopped"), generation: observerGeneration)
    }

    /// The observation lane retires every pre-lock lifetime even when unlock
    /// arrived before this queued revocation ran. Usable-frame configuration is
    /// retained; the next recovery obtains a new window/Space/display baseline.
    func sessionUnavailable() {
        markAuditActivity()
        revokeWorldObservation(.init(code: "session_locked"), generation: observerGeneration)
        cachedTopology.removeAll()
        latestTargetObservation = [:]
        count = 0
    }

    /// AppKit owns usable insets. The main-thread adapter supplies fresh CG
    /// coordinates on bootstrap/display changes; absence remains unavailable.
    func setUsableDisplayFrames(_ frames: [String: Frame]) {
        markAuditActivity()
        usableDisplayFrames = frames
        guard sessionAvailable() else { sessionUnavailable(); return }
        cachedTopology = captureDisplayTopology()
        if cachedTopology.isEmpty {
            revokeWorldObservation(.init(code: "world_display_topology_unavailable"), generation: observerGeneration)
        }
    }

    func capture(_ request: ProjectionSnapshotRequest) -> ProjectionWorldSnapshot {
        markAuditActivity()
        let started = DispatchTime.now().uptimeNanoseconds
        let session = sessionGeneration()
        latestTargetObservation = [:]
        updateWorldFeedGeneration(request.observerGeneration)
        var error: ProjectionObservationFailure?
        let isSweep = ["world_seed", "space_changed", "topology_changed", "wake_recovery",
                       "trust_changed", "explicit_recovery", "application_launch_recovery", "cache_audit"].contains(request.reason)
        var refreshedWorld = isSweep
        var activationRecovery = false
        if !sessionAvailable() {
            sessionUnavailable()
            error = worldFailure
        } else if !trusted() {
            revokeWorldObservation(.init(code: "ax_untrusted"), generation: request.observerGeneration)
            error = worldFailure
        } else {
            if isSweep {
                rebaselineWorld(request)
            } else if let terminated = request.lifecyclePid {
                cachedWindows = cachedWindows.filter { $0.value["pid"]?.intValue != Int64(terminated) }
                handles = handles.filter { $0.value.pid != terminated }
                ownerPids.remove(terminated)
                windowLifetimes = windowLifetimes.filter { $0.value.pid != terminated }
                refreshedWorld = true
                refreshWorld(request)
            } else if observerGeneration != request.observerGeneration, !handles.isEmpty || !ownerPids.isEmpty {
                rebindWorldObserver(generation: request.observerGeneration)
            }
            if request.reason == "app_activated", !worldComplete {
                // An activation is independent lifecycle evidence, not an AX
                // retry. Replace a partial cache with one complete observation;
                // every unvalidated prior handle keeps its retired lifetime.
                latestTargetObservation["world_recovery_reason"] = worldFailure.map { .string($0.code) } ?? .null
                activationRecovery = true
                refreshedWorld = true
                rebaselineWorld(request)
            }
            observerGeneration = request.observerGeneration
            if !worldObservationActive || (refreshedWorld && !worldComplete) {
                // A focused read cannot certify a failed inventory or restore
                // lifetime authority after its lifecycle source was stopped.
                error = worldFailure
            } else if let event = request.accessibilityEvent {
                latestTargetObservation = [
                    "source_observer_generation": (event.sourceObserverGeneration
                        ?? (event.isWorldObservation ? nil : event.generation)).map { .int(Int64(clamping: $0)) } ?? .null,
                    "admission_observer_generation": .int(Int64(clamping: request.observerGeneration)),
                    "source_receipt_uptime_ns": .int(Int64(clamping: event.receiptUptimeNs)),
                ]
                if let sourceGeneration = event.sourceObserverGeneration,
                   sourceGeneration != worldObserverGeneration || !worldObservationActive {
                    error = .init(code: "world_notification_source_generation_mismatch")
                } else if event.kind == .worldObserverDegraded {
                    revokeWorldObservation(.init(code: event.degradedReason ?? "ax_world_observer_degraded"),
                                           generation: request.observerGeneration)
                    error = worldFailure
                } else if event.kind == .focusedWindowDestroyed || event.kind == .focusedWindowMinimized {
                    if let id = event.windowId {
                        // A late destroyed/minimized callback must identify the
                        // retained concrete window, rather than only a reused ID.
                        if let prior = handles[id],
                           (prior.pid != event.pid || event.element == nil
                            || !elementsMatch(prior.element, event.element!)) {
                            error = .init(code: "lifecycle_notification_identity_mismatch")
                        } else if event.kind == .focusedWindowDestroyed {
                            retireWindow(id)
                        } else if var record = cachedWindows[id] {
                            record["minimized"] = .bool(true)
                            record["eligible"] = .bool(false)
                            record["managed"] = .bool(false)
                            cachedWindows[id] = record
                        }
                        if error == nil, focusId == id { focusId = nil }
                    } else {
                        worldComplete = false
                        worldFailure = .init(code: "lifecycle_notification_identity_missing")
                        focusId = nil
                        error = worldFailure
                    }
                } else if event.kind == .focusedWindowChanged, event.element == nil {
                    focusId = nil
                } else {
                    error = updateTarget(element: event.element, pid: event.pid,
                                         expectedId: event.windowId, request: request,
                                         becomesFocus: !event.isWorldObservation)
                }
            } else if ["telemetry", "mode_changed", "configuration_changed", "presentation_health"].contains(request.reason) {
                // Re-publishing state supplies no new window receipt/read.
            } else if request.reason == "ax_observer_degraded" {
                focusId = nil
                error = .init(code: "ax_observer_degraded")
            } else if let application = request.application {
                switch reader.focusedElement(pid: application.pid) {
                case .failure(let failure): focusId = nil; error = failure
                case .success(let element):
                    if let element {
                        error = updateTarget(element: element, pid: application.pid, expectedId: nil,
                                             request: request, becomesFocus: true)
                    } else { focusId = nil }
                }
            } else { focusId = nil }
        }
        latestTargetObservation["inventory_is_cached"] = .bool(!refreshedWorld
            && latestTargetObservation["ignored_retained_cohort_validation_performed"]?.boolValue != true)
        if !sessionAvailable() || sessionGeneration() != session {
            sessionUnavailable()
            error = worldFailure
        }
        latestTargetObservation["world_recovered"] = .bool(activationRecovery && worldComplete && error == nil)
        if error != nil { failures += 1 }
        count = Int64(cachedWindows.values.filter { $0["onscreen"]?.boolValue == true && $0["minimized"]?.boolValue != true }.count)
        let focus = error == nil && worldComplete
            ? focusId.flatMap { cachedWindows[$0] }.map(JSONValue.object) ?? .null : .null
        return snapshot(request, focus: focus, error: error, started: started, session: session)
    }

    private func refreshWorld(_ request: ProjectionSnapshotRequest) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        worldComplete = false
        worldFailure = nil
        let priorHandles = handles
        let priorSourceGeneration = worldObservationActive ? worldObserverGeneration : nil
        cachedWindows.removeAll()
        handles.removeAll()
        observerGeneration = request.observerGeneration
        fullEnumerations += 1
        switch reader.inventory(enrollOwners: { [self] owners in
            guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
            guard let worldObserver else { return .failure(.init(code: "world_lifecycle_observer_unavailable")) }
            if worldObservationActive, owners == observedOwnerPids { return .success(()) }
            revokeWorldObservation(.init(code: "world_observation_membership_changed"), generation: request.observerGeneration)
            worldFailure = nil
            worldEventLock.lock()
            worldObserverGeneration &+= 1
            worldObservationActive = true
            worldEventLock.unlock()
            let result = worldObserver.begin(ownerPids: owners, generation: worldObserverGeneration)
            if case .success = result { observedOwnerPids = owners }
            return result
        }) {
        case .failure(let failure):
            revokeWorldObservation(failure, generation: request.observerGeneration)
            return
        case .success(let inventory):
            let presentIds = Set(inventory.handles.map(\.windowId))
            // A recovery survivor needs an actual retained handle and uninterrupted
            // lifecycle coverage. Matching PID/ID alone never preserves a token.
            windowLifetimes = windowLifetimes.filter { id, lifetime in
                let fresh = inventory.handles.filter { $0.windowId == id }
                guard priorSourceGeneration == worldObserverGeneration, worldObservationActive,
                      presentIds.contains(id), let prior = priorHandles[id],
                      prior.pid == lifetime.pid, coveredWindowIds.contains(id), fresh.count == 1,
                      fresh[0].pid == lifetime.pid, elementsMatch(fresh[0].element, prior.element) else { return false }
                return identityIsCurrent(prior)
            }
            ownerPids = inventory.ownerPids
            for handle in inventory.handles {
                guard sessionAvailable() else { sessionUnavailable(); return }
                handles[handle.windowId] = handle
                targetedReads += 1
                let read = reader.read(element: handle.element, pid: handle.pid, expectedWindowId: handle.windowId)
                guard sessionAvailable() else { sessionUnavailable(); return }
                switch read {
                case .failure(let failure):
                    retireWindow(handle.windowId)
                    worldFailure = worldFailure ?? failure
                case .success(let window):
                    guard window.windowId == handle.windowId, window.pid == handle.pid else {
                        retireWindow(handle.windowId)
                        worldFailure = worldFailure ?? .init(code: "ax_inventory_identity_changed_during_read")
                        continue
                    }
                    switch windowObject(window, request: request, appName: "") {
                    case .failure(let failure):
                        retireWindow(handle.windowId)
                        worldFailure = worldFailure ?? failure
                    case .success(let object): cachedWindows[window.windowId] = object
                    }
                }
            }
            guard inventory.visibleWindowIds.subtracting(Set(cachedWindows.keys)).isEmpty else {
                worldFailure = worldFailure ?? .init(code: "world_visible_window_set_incomplete")
                return
            }
            rebindWorldObserver(generation: request.observerGeneration)
        }
        cachedTopology = captureDisplayTopology()
        if cachedTopology.isEmpty {
            revokeWorldObservation(.init(code: "world_display_topology_unavailable"), generation: request.observerGeneration)
        }
    }

    private func rebaselineWorld(_ request: ProjectionSnapshotRequest) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        spaceBaselines += 1
        switch spaces.rebaseline() {
        case .failure(let failure): revokeWorldObservation(failure, generation: request.observerGeneration)
        case .success: refreshWorld(request)
        }
    }

    private func rebindWorldObserver(generation: UInt64) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        guard let worldObserver else {
            revokeWorldObservation(.init(code: "world_lifecycle_observer_unavailable"), generation: generation)
            return
        }
        if !worldObservationActive || ownerPids != observedOwnerPids {
            revokeWorldObservation(.init(code: "world_lifecycle_observer_authority_unavailable"), generation: generation)
            return
        }
        // Owner changes force the observer implementation to replace concrete
        // sources, ending continuity for every prior lifetime.
        let invalid = handles.keys.sorted().filter { id in handles[id].map { !identityIsCurrent($0) } ?? true }
        let onlyIgnored = !invalid.isEmpty && invalid.allSatisfy { id in
            guard let row = cachedWindows[id] else { return false }
            return row["eligible"]?.boolValue == false && row["managed"]?.boolValue == false
                && row["role"]?.stringValue == "AXWindow"
                && ["AXDialog", "AXSystemDialog", "AXHelpTag"].contains(row["subrole"]?.stringValue ?? "")
        }
        if invalid.contains(where: { id in
            guard let row = cachedWindows[id], row["role"]?.stringValue == "AXWindow" else { return true }
            return !["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXHelpTag"].contains(row["subrole"]?.stringValue ?? "")
        }) {
            revokeWorldObservation(.init(code: "ax_retained_unclassified_identity_unavailable"), generation: generation)
            return
        }
        if onlyIgnored {
            switch validateIgnoredRetirement(Set(invalid), generation: generation) {
            case .success:
                latestTargetObservation["ignored_retained_window_ids"] = .array(invalid.map(JSONValue.int))
                for id in invalid { retireWindow(id) }
            case .failure(let failure):
                latestTargetObservation["ignored_retained_validation_failure"] = .string(failure.code)
                revokeWorldObservation(failure, generation: generation)
                return
            }
        }
        var retiredIdentities: [JSONValue] = []
        for id in onlyIgnored ? [] : invalid {
            guard let prior = handles[id], let lifetime = windowLifetimes[id] else { continue }
            retiredIdentities.append(.object(["window_id": .int(id), "pid": .int(Int64(prior.pid)),
                "window_generation": .int(Int64(clamping: lifetime.generation))]))
            retireWindow(id)
            worldFailure = worldFailure ?? .init(code: "ax_retained_window_identity_unavailable:id=\(id),pid=\(prior.pid)")
        }
        if !retiredIdentities.isEmpty {
            latestTargetObservation["retired_window_identities"] = .array(retiredIdentities)
        }
        let inventory = ProjectionWindowInventory(handles: Array(handles.values),
            visibleWindowIds: Set(cachedWindows.values.filter { $0["onscreen"]?.boolValue == true }.compactMap { $0["window_id"]?.intValue }),
            ownerPids: ownerPids)
        switch worldObserver.replace(inventory: inventory, generation: worldObserverGeneration) {
        case .failure(let failure): revokeWorldObservation(failure, generation: generation)
        case .success:
            coveredWindowIds.formUnion(handles.keys)
            worldComplete = worldFailure == nil
        }
        for id in cachedWindows.keys {
            cachedWindows[id]?["observer_generation"] = .int(Int64(clamping: generation))
        }
        observerGeneration = generation
    }

    /// A dead positively ignored AX row may disappear without ending managed
    /// authority. Prove the current live cohort first; never infer identity from
    /// frame/z-order, refresh a managed wrapper, or carry a token through failure.
    private func validateIgnoredRetirement(_ retired: Set<Int64>, generation: UInt64) -> Result<Void, ProjectionObservationFailure> {
        let source = worldObserverGeneration, session = sessionGeneration(), started = DispatchTime.now().uptimeNanoseconds
        let topology = cachedTopology, usable = usableDisplayFrames
        let guardRead: ProjectionAuditGuard = { [self] in
            guard sessionAvailable(), sessionGeneration() == session, trusted(), worldObservationActive, worldObserverGeneration == source,
                  worldFeedGeneration == generation, cachedTopology == topology, usableDisplayFrames == usable,
                  worldComplete, worldFailure == nil else { return .init(code: "ignored_retained_authority_unavailable") }
            return projectionAXReadBudgetAllowsCall(started: started, now: DispatchTime.now().uptimeNanoseconds)
                ? nil : .init(code: "ignored_retained_validation_deadline")
        }
        fullEnumerations += 1
        latestTargetObservation["inventory_is_cached"] = .bool(false)
        latestTargetObservation["ignored_retained_cohort_validation_performed"] = .bool(true)
        let ignored = retired.compactMap { handles[$0] }
        let inventory: ProjectionWindowInventory
        switch reader.auditInventory(ignored: ignored, beforeExternalCall: guardRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): inventory = value
        }
        guard inventory.ownerPids == ownerPids, ownerPids == observedOwnerPids, retired.isDisjoint(with: inventory.visibleWindowIds),
              Set(inventory.handles.map(\.windowId)).count == inventory.handles.count,
              inventory.handles.allSatisfy({ $0.windowId > 0 && $0.pid > 0 && !retired.contains($0.windowId) }) else {
            return .failure(.init(code: "ignored_retained_inventory_owner_or_alias_changed"))
        }
        displayEnumerations += 1
        switch displayTopologyReader(usable, guardRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let current):
            guard current == topology else { return .failure(.init(code: "ignored_retained_display_topology_changed")) }
        }
        let expected = Set(cachedWindows.filter { _, row in row["eligible"]?.boolValue == true
            && row["onscreen"]?.boolValue == true && row["space_visible"]?.boolValue == true }.keys)
        var actual: Set<Int64> = []
        var newIgnored: [(ProjectionWindowHandle, TargetedWindowObservation)] = []
        for fresh in inventory.handles {
            if let failure = guardRead() { return .failure(failure) }
            let window: TargetedWindowObservation
            targetedReads += 1
            switch reader.auditRead(handle: fresh, beforeExternalCall: guardRead) {
            case .failure(let failure): return .failure(failure)
            case .success(let value): window = value
            }
            guard window.windowId == fresh.windowId, window.pid == fresh.pid else {
                return .failure(.init(code: "ignored_retained_inventory_identity_changed"))
            }
            let knownIgnored = window.role == "AXWindow" && ["AXDialog", "AXSystemDialog", "AXHelpTag"].contains(window.subrole)
            guard window.role == "AXWindow", window.subrole == "AXStandardWindow" || knownIgnored else {
                return .failure(.init(code: "ignored_retained_inventory_classification_unknown"))
            }
            if let prior = handles[window.windowId] {
                if let failure = guardRead() { return .failure(failure) }
                guard prior.pid == fresh.pid, elementsMatch(prior.element, fresh.element), identityIsCurrent(prior) else {
                    return .failure(.init(code: "ignored_retained_inventory_alias_or_pid_changed"))
                }
            } else {
                guard knownIgnored, cachedWindows[window.windowId] == nil else {
                    return .failure(.init(code: "ignored_retained_inventory_new_managed_identity"))
                }
                newIgnored.append((fresh, window))
            }
            let facts = windowFacts(window, appName: cachedWindows[window.windowId]?["app"]?.stringValue ?? "")
            let eligible = window.movable && !window.minimized && window.onscreen && Autotile.tileable(.object(facts), rules)
            guard eligible else { continue }
            let context: ProjectionSpaceContext
            if let failure = guardRead() { return .failure(failure) }
            switch spaces.context(windowId: window.windowId) {
            case .failure(let failure): return .failure(failure)
            case .success(let value): context = value
            }
            if let failure = guardRead() { return .failure(failure) }
            guard context.visible else { continue }
            actual.insert(window.windowId)
            guard expected.contains(window.windowId), inventory.visibleWindowIds.contains(window.windowId),
                  let prior = handles[window.windowId], let lifetime = windowLifetimes[window.windowId],
                  let row = cachedWindows[window.windowId], coveredWindowIds.contains(window.windowId),
                  prior.pid == fresh.pid, lifetime.pid == fresh.pid, elementsMatch(prior.element, fresh.element),
                  row["pid"]?.intValue == Int64(window.pid), row["window_generation"]?.intValue == Int64(clamping: lifetime.generation),
                  row["space_key"]?.stringValue == context.key, row["display_id"]?.stringValue == context.displayId,
                  row["space_enabled"]?.boolValue == spaceEnabled(context.key) else {
                return .failure(.init(code: "ignored_retained_managed_identity_or_scope_changed"))
            }
        }
        guard actual == expected, guardRead() == nil else {
            return .failure(.init(code: "ignored_retained_managed_cohort_incomplete"))
        }
        let request = ProjectionSnapshotRequest(reason: "app_activated", application: nil, observerGeneration: generation, accessibilityEvent: nil)
        for (handle, window) in newIgnored {
            if let failure = guardRead() { return .failure(failure) }
            switch windowObject(window, request: request, appName: "") {
            case .failure(let failure): return .failure(failure)
            case .success(let row): handles[handle.windowId] = handle; cachedWindows[handle.windowId] = row
            }
        }
        if let failure = guardRead() { return .failure(failure) }
        return .success(())
    }

    private func updateTarget(element: AXUIElement?, pid: pid_t, expectedId: Int64?,
                              request: ProjectionSnapshotRequest, becomesFocus: Bool) -> ProjectionObservationFailure? {
        guard sessionAvailable() else { sessionUnavailable(); return worldFailure }
        targetedReads += 1
        let read = reader.read(element: element, pid: pid, expectedWindowId: expectedId)
        guard sessionAvailable() else { sessionUnavailable(); return worldFailure }
        switch read {
        case .failure(let failure):
            if let expectedId { retireWindow(expectedId) }
            worldComplete = false
            worldFailure = failure
            if becomesFocus || focusId == expectedId { focusId = nil }
            return failure
        case .success(let window):
            guard window.pid == pid, expectedId == nil || expectedId == window.windowId else {
                if let expectedId { retireWindow(expectedId) }
                worldComplete = false
                worldFailure = .init(code: "ax_notification_identity_mismatch")
                focusId = nil
                return worldFailure
            }
            var retainedCanonical: ProjectionWindowHandle?
            if let prior = handles[window.windowId] {
                if request.accessibilityEvent?.isWorldObservation == true,
                   request.accessibilityEvent?.kind != .windowCreated,
                   (prior.pid != pid || element == nil || !elementsMatch(prior.element, element!)) {
                    return .init(code: "ax_notification_retained_handle_mismatch")
                }
                if !worldObservationActive || !coveredWindowIds.contains(window.windowId)
                    || prior.pid != pid || !identityIsCurrent(prior) {
                    windowLifetimes.removeValue(forKey: window.windowId)
                } else if request.accessibilityEvent?.kind != .windowCreated,
                          windowLifetimes[window.windowId]?.pid == pid,
                          let element, elementsMatch(prior.element, element) {
                    // A registered callback may carry the pre-repair equivalent wrapper. Its
                    // immutable capsule remains read evidence; the refreshed setter wrapper wins.
                    retainedCanonical = prior
                }
            } else { windowLifetimes.removeValue(forKey: window.windowId) }
            if let retainedCanonical { handles[window.windowId] = retainedCanonical }
            else if let element { handles[window.windowId] = .init(element: element, pid: pid, windowId: window.windowId) }
            switch windowObject(window, request: request, appName: request.application?.pid == pid ? request.application?.name ?? "" : "") {
            case .failure(let failure):
                retireWindow(window.windowId)
                worldComplete = false
                worldFailure = failure
                if becomesFocus || focusId == window.windowId { focusId = nil }
                return failure
            case .success(let object):
                cachedWindows[window.windowId] = object
                if let event = request.accessibilityEvent {
                    if event.isWorldObservation, event.kind == .windowCreated {
                        coveredWindowIds.insert(window.windowId)
                    }
                    latestTargetObservation.merge([
                        "target_window_id": .int(window.windowId), "target_pid": .int(Int64(window.pid)),
                        "target_receipt_uptime_ns": .int(Int64(clamping: event.receiptUptimeNs)),
                        "target_read_completed_uptime_ns": object["observed_uptime_ns"] ?? .null,
                        "target_read_performed": .bool(true), "target_kind": .string(event.kind.rawValue),
                        "target_registration_generation": .int(Int64(clamping: event.windowGeneration)),
                        "target_source_observer_generation": object["source_observer_generation"] ?? .null,
                        "target_window_generation": object["window_generation"] ?? .null,
                    ], uniquingKeysWith: { _, new in new })
                }
                if becomesFocus { focusId = window.windowId }
                return nil
            }
        }
    }

    private func windowObject(_ window: TargetedWindowObservation, request: ProjectionSnapshotRequest,
                              appName: String) -> Result<JSONObject, ProjectionObservationFailure> {
        let isCreation = request.accessibilityEvent?.kind == .windowCreated
        if isCreation || windowLifetimes[window.windowId]?.pid != window.pid {
            nextWindowLifetime &+= 1
            windowLifetimes[window.windowId] = WindowLifetime(pid: window.pid, generation: nextWindowLifetime)
        }
        var object = windowFacts(window, appName: appName)
        object["observer_generation"] = .int(Int64(request.observerGeneration))
        object["source_observer_generation"] = .int(Int64(clamping: request.accessibilityEvent?.sourceObserverGeneration
            ?? request.accessibilityEvent?.generation ?? worldObserverGeneration))
        object["window_generation"] = .int(Int64(clamping: windowLifetimes[window.windowId]!.generation))
        object["registration_generation"] = .int(Int64(clamping: request.accessibilityEvent?.windowGeneration ?? 0))
        let eligible = window.movable && !window.minimized && window.onscreen
            && Autotile.tileable(.object(object), rules)
        object["eligible"] = .bool(eligible)
        object["managed"] = .bool(eligible)
        switch spaces.context(windowId: window.windowId) {
        case .failure(let failure):
            if eligible { return .failure(failure) }
            object["space_identity_available"] = .bool(false)
            object["space_identity_failure"] = .string(failure.code)
        case .success(let context):
            object["space_key"] = .string(context.key)
            object["desktop_space_key"] = .string(context.key)
            object["display_id"] = .string(context.displayId)
            object["space_visible"] = .bool(context.visible)
            object["space_enabled"] = .bool(spaceEnabled(context.key))
            object["space_identity_source"] = .string("window_server_space_uuid")
            object["space_identity_available"] = .bool(true)
        }
        object["observed_uptime_ns"] = .int(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
        return .success(object)
    }

    private func windowFacts(_ window: TargetedWindowObservation, appName: String) -> JSONObject {
        [
            "window_id": .int(window.windowId), "pid": .int(Int64(window.pid)),
            "app": .string(window.appName.isEmpty ? appName : window.appName), "title": .string(window.title),
            "frame": .object(["x": .double(window.frame.x), "y": .double(window.frame.y),
                              "w": .double(window.frame.w), "h": .double(window.frame.h)]),
            "role": .string(window.role), "subrole": .string(window.subrole),
            "resizable": .bool(window.resizable), "movable": .bool(window.movable),
            "minimized": .bool(window.minimized), "destroyed": .bool(false), "onscreen": .bool(window.onscreen),
        ]
    }

    private func captureDisplayTopology() -> [JSONValue] {
        guard sessionAvailable() else { return [] }
        displayEnumerations += 1
        return (try? displayTopologyReader(usableDisplayFrames, { [self] in sessionAvailable() ? nil : .init(code: "session_locked") }).get()) ?? []
    }

    private func snapshot(_ request: ProjectionSnapshotRequest, focus suppliedFocus: JSONValue,
                          error suppliedError: ProjectionObservationFailure?, started: UInt64,
                          session: UInt64) -> ProjectionWorldSnapshot {
        var focus = suppliedFocus
        var error = suppliedError
        var contexts: [JSONValue] = []
        var activeContext: JSONValue = .null
        if sessionAvailable(), sessionGeneration() == session, trusted(), case .success(let current) = spaces.currentContexts() {
            contexts = current.map { context in
                .object(["space_key": .string(context.key), "display_id": .string(context.displayId),
                         "space_enabled": .bool(spaceEnabled(context.key)), "space_visible": .bool(context.visible),
                         "space_identity_available": .bool(true),
                         "space_identity_source": .string("window_server_space_uuid")])
            }
            if let display = focus.at(path: "display_id")?.stringValue {
                activeContext = contexts.first { $0.at(path: "display_id")?.stringValue == display } ?? .null
            } else if contexts.count == 1 { activeContext = contexts[0] }
        }
        if !sessionAvailable() || sessionGeneration() != session {
            sessionUnavailable()
            error = worldFailure
            focus = .null
            activeContext = .null
            contexts = []
        }
        var observation: JSONObject = [
            "ready": .bool(error == nil), "failure_code": error.map { .string($0.code) } ?? .null,
            "world_complete": .bool(worldComplete), "world_failure_code": worldFailure.map { .string($0.code) } ?? .null,
            "reason": .string(request.reason), "inventory_is_cached": .bool(request.reason != "world_seed"),
            "full_enumeration_count": .int(fullEnumerations), "targeted_read_count": .int(targetedReads),
            "effect_handle_refresh_count": .int(effectHandleRefreshes),
            "cache_audit_enumeration_count": .int(auditEnumerations), "cache_audit_targeted_read_count": .int(auditReads),
            "cache_audit_display_enumeration_count": .int(auditDisplays),
            "failure_count": .int(failures), "space_baseline_count": .int(spaceBaselines),
            "display_enumeration_count": .int(displayEnumerations),
            "session_generation": .int(Int64(clamping: session)),
            "read_started_uptime_ns": .int(Int64(clamping: started)),
            "read_completed_uptime_ns": .int(Int64(clamping: DispatchTime.now().uptimeNanoseconds)),
            "ax_call_timeout_ms": .int(Int64(Self.axMessageBudgetNs / 1_000_000)), "ax_total_read_budget_ms": .int(200),
            "world_source_observer_generation": worldObservationActive ? .int(Int64(clamping: worldObserverGeneration)) : .null,
            "admission_observer_generation": .int(Int64(clamping: request.observerGeneration)),
            "source_observer_generation": .null,
            "space_identity_source": .string("window_server_space_uuid"),
            "target_window_id": .null, "target_receipt_uptime_ns": .null,
            "target_read_completed_uptime_ns": .null, "target_read_performed": .bool(false), "target_kind": .null,
        ]
        for (key, value) in latestTargetObservation { observation[key] = value }
        return ProjectionWorldSnapshot(windowsOnscreen: count, focus: focus, observation: observation,
           windows: cachedWindows.keys.sorted().compactMap { cachedWindows[$0].map(JSONValue.object) },
           topology: cachedTopology, activeContext: activeContext, spaceContexts: contexts)
    }
}
