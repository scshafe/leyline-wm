// Window-reading vocabulary shared by the projection snapshot, its live AX
// reader and the test fakes: identities, observations, attribute batches,
// handles, inventories and the TargetedProjectionWindowReading protocol.
// Moved verbatim from TargetedProjectionSnapshot.swift.
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

/// @canonical projection_inventory_owner_cohort -- the AX enrollment set is
/// visible-window owners plus regular applications, minus excluded owners and
/// any non-positive PID. LaunchServices can list a regular app with no process
/// (Xcode's Device Hub reports -1 for hours); AXObserverCreate(-1) fails, so
/// enrolling it refused every world read. A visible window whose owner PID is
/// dropped stays required by the completeness check, so nothing can vanish.
func projectionInventoryOwnerPids(visibleOwners: Set<pid_t>, regularApplications: [pid_t],
                                  excluded: Set<pid_t>) -> Set<pid_t> {
    visibleOwners.union(regularApplications).subtracting(excluded).filter { $0 > 0 }
}

/// @canonical projection_non_desktop_window -- a CG-visible row is outside the
/// desktop eligibility contract only when every Space it occupies is positively
/// known to be a non-desktop Space (type != 0: native full-screen, tiled system
/// Spaces). Native full-screen Safari's toolbar strip is a layer-0 CG window with
/// no AX counterpart; requiring its classification parks startup indefinitely.
/// An unknown Space, a desktop membership or an unreadable membership keeps the
/// row required, so a failed read can never shrink the visible set.
func projectionNonDesktopOnlyWindowIds(_ ids: Set<Int64>, spaceTypes: [UInt64: Int],
                                       memberships: (Int64) -> [UInt64]?) -> Set<Int64> {
    guard spaceTypes.values.contains(where: { $0 != 0 }) else { return [] }
    return ids.filter { id in
        guard let spaces = memberships(id), !spaces.isEmpty else { return false }
        return spaces.allSatisfy { spaceTypes[$0].map { $0 != 0 } ?? false }
    }
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
