// Independently observed per-display Space context: the vocabulary, the
// canonical display read and the SkyLight-backed observer. Moved verbatim
// from TargetedProjectionSnapshot.swift.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LeylineModel

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
    func occupiesSpace(windowId: Int64) -> Bool
}

extension ProjectionSpaceObserving {
    func makeAuditProbe() -> (@Sendable (Int64, @escaping @Sendable () -> ProjectionObservationFailure?) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>)? { nil }
    func occupiesSpace(windowId: Int64) -> Bool { false }
    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure> {
        .failure(.init(code: "independent_current_display_space_unavailable"))
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
    /// SLSCopySpacesForWindows selector: every Space kind.
    private static let allSpacesMask: Int32 = 0x7
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
            guard let raw = self.windows!(cid, Self.allSpacesMask, [NSNumber(value: id)] as CFArray)?.takeRetainedValue(),
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
        guard let raw = windows(cid, Self.allSpacesMask, ids)?.takeRetainedValue(),
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

    /// Any Space counts, including one created after the baseline or a fullscreen
    /// Space; a destroyed window belongs to none.
    func occupiesSpace(windowId: Int64) -> Bool {
        guard windowId > 0, windowId <= Int64(UInt32.max), let connection, let windows,
              let raw = windows(connection(), Self.allSpacesMask, [NSNumber(value: windowId)] as CFArray)?.takeRetainedValue(),
              let memberships = raw as? [NSNumber] else { return false }
        return !memberships.isEmpty
    }

    /// Fresh Space-type read for the inventory guard. Uses only immutable function
    /// pointers, so the detached audit lane may call it; any failed read returns
    /// the empty set (every row stays required).
    func nonDesktopOnlyWindowIds(_ ids: Set<Int64>) -> Set<Int64> {
        guard !ids.isEmpty, let connection, let displays, let windows else { return [] }
        let cid = connection()
        guard let raw = displays(cid)?.takeRetainedValue(), let rows = raw as? [[String: Any]], !rows.isEmpty else { return [] }
        var types: [UInt64: Int] = [:]
        for row in rows {
            guard let entries = row["Spaces"] as? [[String: Any]] else { return [] }
            for entry in entries {
                guard let type = entry["type"] as? Int,
                      let id = (entry["ManagedSpaceID"] as? NSNumber ?? entry["id64"] as? NSNumber)?.uint64Value, id > 0,
                      types[id] == nil else { return [] }
                types[id] = type
            }
        }
        return projectionNonDesktopOnlyWindowIds(ids, spaceTypes: types) { id in
            guard id > 0, id <= Int64(UInt32.max),
                  let raw = windows(cid, Self.allSpacesMask, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() else { return nil }
            return (raw as? [NSNumber])?.map(\.uint64Value)
        }
    }

    /// The only no-window Space target is an exact OS display UUID.
    private func currentSpaceContext(displayUUID display: String)
        -> Result<ProjectionSpaceContext, ProjectionObservationFailure> {
        if let baselineFailure { return .failure(baselineFailure) }
        guard spaces.values.contains(where: { $0.displayId == display }) else {
            return .failure(.init(code: "independent_current_display_target_ambiguous"))
        }
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
