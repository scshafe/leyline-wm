// The only live AX read adapter for projection, with the inventory
// classification helpers it defaults to. Moved verbatim from
// TargetedProjectionSnapshot.swift; the struct is internal because the
// snapshot constructs it.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LeylineModel

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
struct LiveTargetedProjectionWindowReader: TargetedProjectionWindowReading {
    let sessionAvailable: @Sendable () -> Bool
    /// Rows outside the desktop eligibility contract (see
    /// `projectionNonDesktopOnlyWindowIds`); the default keeps every row required.
    var nonDesktopOnly: @Sendable (Set<Int64>) -> Set<Int64> = { _ in [] }
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
    private static let refreshTimeoutSeconds = Float(Double(TargetedProjectionSnapshot.effectRefreshMessageBudgetNs) / 1e9)

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
        let layerZero = rows.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid()
                && (($0[kCGWindowOwnerPID as String] as? NSNumber).map { !systemOwners.contains($0.int32Value) } ?? true)
        }
        if let failure = beforeExternalCall() { return .failure(failure) }
        let outsideDesktop = nonDesktopOnly(Set(layerZero.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.int64Value }))
        let visible = layerZero.filter {
            ($0[kCGWindowNumber as String] as? NSNumber).map { !outsideDesktop.contains($0.int64Value) } ?? true
        }
        let visibleIds = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.int64Value })
        if let failure = beforeExternalCall() { return .failure(failure) }
        let owners = projectionInventoryOwnerPids(
            visibleOwners: Set(visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }),
            regularApplications: applications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier),
            excluded: systemOwners.union([ProcessInfo.processInfo.processIdentifier]))
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
