import ApplicationServices
import Foundation
import LeylineModel

private final class CacheAuditFixture: TargetedProjectionWindowReading, ProjectionSpaceObserving, AccessibilityFocusObserving, @unchecked Sendable {
    let condition = NSCondition()
    var onEvent: ((AccessibilityFocusEvent) -> Void)?
    var onHealthChanged: ((AccessibilityObserverHealth) -> Void)?
    var worldOnEvent: (@Sendable (AccessibilityFocusEvent) -> Void)?
    var records: [Int64: TargetedWindowObservation] = [:]
    var handles: [Int64: ProjectionWindowHandle] = [:]
    var mode = "clean"
    var blocked = false
    var entered = false
    var released = false
    var session: UInt64 = 1
    var epoch: UInt64 = 1
    var live = true
    var observerBegins = 0
    var inventories = 0
    var auditInventories = 0
    var auditReadIds: [Int64] = []
    var fresh: ProjectionWindowHandle?
    func freshWindowHandle(pid: pid_t, windowId: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> { .success(fresh ?? handles[windowId]!) }
    var captures: [String] = []
    var deltas: [JSONObject] = []
    var operations: [@Sendable () -> Void] = []
    var deadlines: [@Sendable () -> Void] = []
    let topology: [JSONValue] = [.object(["id": .int(1), "display_id": .string("fixture-display"), "main": .bool(true),
        "frame": .object(["x": .int(0), "y": .int(0), "w": .int(1600), "h": .int(1200)]), "usable_frame_known": .bool(false)])]
    init() {
        for index in 0..<21 {
            let id = Int64(1000 + index), element = AXUIElementCreateApplication(111)
            handles[id] = .init(element: element, pid: 111, windowId: id)
            records[id] = .init(windowId: id, pid: 111, frame: Frame(x: Double(index % 5) * 300, y: Double(index / 5) * 200, w: 280, h: 180),
                role: "AXWindow", subrole: index == 20 ? "AXDialog" : "AXStandardWindow", title: "Fixture", resizable: true,
                movable: true, minimized: false, onscreen: true)
        }
    }
    var supportsCacheAudit: Bool { true }
    func inventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>) -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        if case .failure(let failure) = enrollOwners([111]) { return .failure(failure) }
        condition.lock(); inventories += 1; let result = inventoryLocked(audit: false); condition.unlock(); return .success(result)
    }
    private func inventoryLocked(audit: Bool) -> ProjectionWindowInventory {
        var selected = Array(handles.values)
        if audit {
            selected.removeAll { $0.windowId == 1020 }
            if mode == "missing" { selected.removeAll { $0.windowId == 1000 } }
            if mode == "changed_id" { selected.removeAll { $0.windowId == 1000 }; selected.append(.init(element: handles[1000]!.element, pid: 111, windowId: 9999)) }
            if mode == "alias" { selected.removeAll { $0.windowId == 1000 }; selected.append(.init(element: AXUIElementCreateApplication(111), pid: 111, windowId: 1000)) }
            if mode == "extra" { selected.append(.init(element: AXUIElementCreateApplication(111), pid: 111, windowId: 9999)) }
            if mode == "duplicate" { selected.append(handles[1000]!) }
        }
        return .init(handles: selected, visibleWindowIds: Set(selected.map(\.windowId)), ownerPids: [111], ignoredWindowIds: [1020])
    }
    func auditInventory(ignored: [ProjectionWindowHandle], beforeExternalCall: @escaping ProjectionAuditGuard) -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        condition.lock(); auditInventories += 1
        if blocked { entered = true; condition.broadcast(); while !released { condition.wait() } }
        let value = inventoryLocked(audit: true); condition.unlock()
        if let failure = beforeExternalCall() { return .failure(failure) }
        return .success(value)
    }
    func auditRead(handle: ProjectionWindowHandle, beforeExternalCall: @escaping ProjectionAuditGuard) -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        condition.lock(); defer { condition.unlock() }; auditReadIds.append(handle.windowId)
        if mode == "read_failure" { return .failure(.init(code: "fixture_audit_unavailable")) }
        return .success(records[handle.windowId] ?? .init(windowId: handle.windowId, pid: 111, frame: Frame(x: 0, y: 0, w: 280, h: 180),
            role: "AXWindow", subrole: "AXStandardWindow", title: "Extra", resizable: true, movable: true, minimized: false, onscreen: true))
    }
    func focusedElement(pid: pid_t) -> Result<AXUIElement?, ProjectionObservationFailure> { .success(handles[1000]!.element) }
    func read(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?) -> Result<TargetedWindowObservation, ProjectionObservationFailure> { .success(records[expectedWindowId ?? 1000]!) }
    func rebaseline() -> Result<Void, ProjectionObservationFailure> { .success(()) }
    func context(windowId: Int64) -> Result<ProjectionSpaceContext, ProjectionObservationFailure> {
        condition.lock(); let changed = mode == "space_changed"; condition.unlock()
        return .success(.init(key: changed ? "different-space" : "fixture-space", displayId: "fixture-display", visible: true))
    }
    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure> { .success([.init(key: "fixture-space", displayId: "fixture-display", visible: true)]) }
    func makeAuditProbe() -> (@Sendable (Int64, @escaping ProjectionAuditGuard) -> Result<ProjectionSpaceContext, ProjectionObservationFailure>)? {
        { [self] id, guardCall in if let failure = guardCall() { return .failure(failure) }; return context(windowId: id) }
    }
    func begin(ownerPids: Set<pid_t>, generation: UInt64) -> Result<Void, ProjectionObservationFailure> { observerBegins += 1; return .success(()) }
    func replace(inventory: ProjectionWindowInventory, generation: UInt64) -> Result<Void, ProjectionObservationFailure> { .success(()) }
    func stop(generation: UInt64) {}
    func attach(to pid: pid_t, generation: UInt64) -> AccessibilityObserverHealth { .init(ready: true, pid: pid, generation: generation, windowNotificationsReady: true, degradedReason: nil) }
    func detach(generation: UInt64) {}
    func enqueue(_ operation: @escaping @Sendable () -> Void) { condition.lock(); operations.append(operation); condition.broadcast(); condition.unlock() }
    func drainOne() -> Bool {
        condition.lock(); let limit = Date().addingTimeInterval(2)
        while operations.isEmpty { if !condition.wait(until: limit) { condition.unlock(); return false } }
        let operation = operations.removeFirst(); condition.unlock(); operation(); return true
    }
    func deadline(_ ms: UInt64, _ operation: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let state = CacheAuditDeadlineFixture(operation)
        condition.lock(); deadlines.append { state.fire() }; condition.unlock(); return { state.cancel() }
    }
    func fireDeadline() { condition.lock(); let item = deadlines.isEmpty ? nil : deadlines.removeFirst(); condition.unlock(); item?() }
    func waitEntered() -> Bool { condition.lock(); defer { condition.unlock() }; let limit = Date().addingTimeInterval(2); while !entered { if !condition.wait(until: limit) { return false } }; return true }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func delivery(_ delta: JSONObject) { condition.lock(); deltas.append(delta); condition.unlock() }
}
private final class CacheAuditDeadlineFixture: @unchecked Sendable {
    let lock = NSLock(); var cancelled = false; let operation: @Sendable () -> Void
    init(_ operation: @escaping @Sendable () -> Void) { self.operation = operation }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func fire() { lock.lock(); let allowed = !cancelled; lock.unlock(); if allowed { operation() } }
}
// Separate protocol adapter avoids combining focused callback and sendable world-callback storage.
private final class CacheAuditWorldFixture: ProjectionWorldObserving, @unchecked Sendable {
    let source: CacheAuditFixture
    var onEvent: (@Sendable (AccessibilityFocusEvent) -> Void)?
    init(_ source: CacheAuditFixture) { self.source = source }
    func begin(ownerPids: Set<pid_t>, generation: UInt64) -> Result<Void, ProjectionObservationFailure> { source.begin(ownerPids: ownerPids, generation: generation) }
    func replace(inventory: ProjectionWindowInventory, generation: UInt64) -> Result<Void, ProjectionObservationFailure> { source.replace(inventory: inventory, generation: generation) }
    func stop(generation: UInt64) {}
}
private final class CacheAuditRig {
    let data = CacheAuditFixture()
    let snapshot: TargetedProjectionSnapshot
    let feed: ProjectionInputFeed
    let audit: ProjectionCacheIntegrityAudit
    init() {
        let data = data
        snapshot = TargetedProjectionSnapshot(trusted: { data.live }, reader: data, spaces: data,
            worldObserver: CacheAuditWorldFixture(data), identityIsCurrent: { _ in true },
            elementsMatch: { ObjectIdentifier($0) == ObjectIdentifier($1) }, sessionAvailable: { data.live }, sessionGeneration: { data.session },
            displayTopologyReader: { _, guardCall in
                if let failure = guardCall() { return .failure(failure) }
                data.condition.lock(); let changed = data.mode == "topology_changed"; data.condition.unlock()
                return .success(changed ? [] : data.topology)
            })
        let snapshot = snapshot
        feed = ProjectionInputFeed(observer: data, captureTargeted: { request in data.captures.append(request.reason); return snapshot.capture(request) },
            executeOnMain: { data.enqueue($0) }, recoverySessionGeneration: { data.session }, recoveryObservationEpoch: { data.epoch },
            recoveryPermitted: { data.live }, deliver: { data.delivery($0) })
        audit = ProjectionCacheIntegrityAudit(executeCompletion: { data.enqueue($0) }, permitted: { seed in data.live && data.epoch == seed.observationEpoch && data.session == seed.sessionGeneration },
            schedule: { data.deadline($0, $1) })
        feed.configureCacheAudit(audit, makeSeed: { generation in snapshot.makeCacheAuditSeed(observerGeneration: generation, observationEpoch: data.epoch) },
            finish: { seed, probe in snapshot.finishCacheAudit(seed: seed, probe: probe) })
        feed.start(frontmost: .init(pid: 111, name: "Fixture"))
    }
    func request() -> Bool { feed.requestCacheAudit(reason: "fixture_explicit") }
    func finish() { feed.stop(); snapshot.stop() }
}

/// Actual provider/feed/utility coordinator. All Window/Space/display backends are local fixtures.
func runCacheIntegrityAuditScenarios(test: inout SelfTest) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/cache_audit/validation.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data) else { test.check(false, "cache-audit/fixture-load"); return }
    test.check(fixture.at(path: "managed_count")?.intValue == 20 && fixture.at(path: "scenarios")?.arrayValue?.count == 10
        && fixture.at(path: "deadline_milliseconds")?.intValue == Int64(ProjectionCacheIntegrityAudit.deadlineMilliseconds), "cache-audit/nonvacuous-twenty-window-ten-scenario-one-shot-fixture")
    let clean = CacheAuditRig(), tokens = clean.snapshot.windowGenerations, begins = clean.data.observerBegins, inventories = clean.data.inventories
    clean.data.blocked = true
    let requested = clean.request(); _ = clean.data.waitEntered()
    test.check(requested && !clean.request(), "cache-audit/duplicate-valid-seed-coalesces-with-one-active-request")
    clean.data.release()
    _ = clean.data.drainOne()
    test.check(clean.data.auditReadIds.count == 20 && !clean.data.auditReadIds.contains(1020) && clean.data.auditInventories == 1
        && clean.data.observerBegins == begins && clean.snapshot.windowGenerations == tokens && clean.data.inventories == inventories
        && clean.data.deltas.last?["cache_integrity"]?.at(path: "status")?.stringValue == "clean"
        && clean.data.deltas.last?["cache_audit_requires_recovery"] == .bool(false)
        && clean.data.deltas.last?["model_state"] == nil && clean.data.deltas.last?["windows"] == nil && clean.data.deltas.last?["focus"] == nil,
        "cache-audit/clean-twenty-window-probe-preserves-source-tokens-and-never-reads-dead-ignored-dialog")
    let auditTotal = clean.snapshot.capture(.init(reason: "telemetry", application: nil, observerGeneration: clean.feed.currentGeneration, accessibilityEvent: nil))
    test.check(auditTotal.observation["full_enumeration_count"]?.intValue == Int64(inventories + 1)
        && auditTotal.observation["cache_audit_enumeration_count"]?.intValue == 1 && auditTotal.observation["cache_audit_targeted_read_count"]?.intValue == 20,
        "cache-audit/actual-audit-cost-is-counted-in-total-and-separate-enumeration-read-counters")
    clean.finish()
    for mode in ["missing", "extra", "changed_id", "alias", "duplicate", "read_failure", "space_changed", "topology_changed"] {
        let rig = CacheAuditRig(); rig.data.mode = mode
        _ = rig.request(); _ = rig.data.drainOne()
        test.check(rig.data.deltas.contains { $0["cache_integrity"]?.at(path: "status")?.stringValue == "failed" }
            && rig.data.captures.filter { $0 == "explicit_recovery" }.count == 1
            && rig.data.deltas.last?["cache_audit_recovery"] == .bool(true), "cache-audit/\(mode)-cannot-certify-clean-and-enters-one-explicit-recovery")
        rig.feed.applicationActivated(.init(pid: 111, name: "Fixture"))
        test.check(rig.data.deltas.last?["cache_audit_recovery"] == .bool(false) && rig.data.deltas.last?["cache_audit_requires_recovery"] == .bool(false),
            "cache-audit/\(mode)-recovery-marker-does-not-leak-into-next-external-lifecycle")
        rig.finish()
    }
    let foreground = CacheAuditRig(); foreground.data.blocked = true
    _ = foreground.request(); let entered = foreground.data.waitEntered()
    let priorCaptures = foreground.data.captures.count
    foreground.feed.applicationActivated(.init(pid: 111, name: "Fixture"))
    test.check(entered && foreground.data.captures.count == priorCaptures + 1 && foreground.data.auditReadIds.isEmpty,
        "cache-audit/blocked-utility-census-does-not-block-foreground-generation-and-capture")
    foreground.data.release(); _ = foreground.data.drainOne()
    test.check(foreground.data.auditReadIds.isEmpty && foreground.data.deltas.last?["cache_integrity"]?.at(path: "status")?.stringValue == "superseded",
        "cache-audit/foreground-receipt-cancels-before-next-external-call-and-old-result-cannot-publish-clean")
    foreground.finish()
    for token in ["session", "epoch", "cache_revision"] {
        let rig = CacheAuditRig(); rig.data.blocked = true; _ = rig.request(); _ = rig.data.waitEntered()
        if token == "session" { rig.data.session += 1 }
        else if token == "epoch" { rig.data.epoch += 1 }
        else { _ = rig.snapshot.readWindow(windowId: 1000, observerGeneration: rig.feed.currentGeneration, expectedWindowGeneration: rig.snapshot.windowGenerations["1000"]) }
        rig.data.release(); _ = rig.data.drainOne()
        test.check(rig.data.auditReadIds.isEmpty && rig.data.deltas.last?["cache_integrity"]?.at(path: "status")?.stringValue == "superseded",
            "cache-audit/\(token)-change-refuses-old-probe-with-zero-following-target-reads")
        rig.finish()
    }
    let resumed = CacheAuditRig(); resumed.feed.stop(); resumed.feed.start(frontmost: .init(pid: 111, name: "Fixture"))
    test.check(resumed.request(), "cache-audit/explicit-start-resumes-coordinator-after-stop")
    _ = resumed.data.drainOne(); resumed.feed.stop(); resumed.feed.wake(frontmost: .init(pid: 111, name: "Fixture"))
    test.check(resumed.request(), "cache-audit/wake-resumes-coordinator-after-stop")
    _ = resumed.data.drainOne(); resumed.finish()
    let deadline = CacheAuditRig(); deadline.data.blocked = true
    _ = deadline.request(); _ = deadline.data.waitEntered(); deadline.data.fireDeadline(); _ = deadline.data.drainOne()
    test.check(deadline.audit.snapshot.at(path: "active") == .bool(true)
        && deadline.data.captures.filter { $0 == "explicit_recovery" }.count == 1,
        "cache-audit/deadline-fails-once-with-blocked-worker-slot-retained-and-no-retry-loop")
    let pending = deadline.request(), duplicatePending = deadline.request()
    test.check(pending && !duplicatePending && deadline.audit.snapshot.at(path: "pending_count") == .int(1),
        "cache-audit/new-valid-seed-coalesces-one-pending-probe-behind-blocked-worker")
    deadline.data.release(); _ = deadline.data.drainOne()
    test.check(deadline.data.captures.filter { $0 == "explicit_recovery" }.count == 1,
        "cache-audit/old-worker-return-cannot-repeat-deadline-recovery")
    deadline.finish()
    let refused = CacheAuditRig(); refused.snapshot.stop()
    test.check(!refused.request() && refused.data.deltas.last?["cache_integrity"]?.at(path: "session_generation") == .int(1)
        && refused.data.deltas.last?["cache_integrity"]?.at(path: "observation_epoch") == .int(1),
        "cache-audit/typed-refusal-retains-publication-session-and-global-epoch-tokens")
    refused.finish()
    runCacheAuditCanonicalWrapperRegression(test: &test)
}

private func runCacheAuditCanonicalWrapperRegression(test: inout SelfTest) {
    let data = CacheAuditFixture(), world = CacheAuditWorldFixture(data)
    let snapshot = TargetedProjectionSnapshot(trusted: { true }, reader: data, spaces: data, worldObserver: world,
        identityIsCurrent: { _ in true }, elementsMatch: { CFEqual($0, $1) },
        displayTopologyReader: { _, guardCall in if let failure = guardCall() { return .failure(failure) }; return .success(data.topology) })
    _ = snapshot.capture(.init(reason: "world_seed", application: .init(pid: 111, name: "Fixture"), observerGeneration: 1, accessibilityEvent: nil))
    let original = data.handles[1000]!, token = snapshot.windowGenerations["1000"]!
    let fresh = ProjectionWindowHandle(element: AXUIElementCreateApplication(111), pid: 111, windowId: 1000)
    data.fresh = fresh
    let refreshed = snapshot.refreshEffectWindow(windowId: 1000, observerGeneration: 1, expectedWindowGeneration: token)
    _ = snapshot.capture(.init(reason: "ax_window_moved", application: nil, observerGeneration: 1,
        accessibilityEvent: .init(kind: .focusedWindowMoved, pid: 111, generation: 1, element: original.element,
                                  windowId: 1000, isWorldObservation: true, sourceObserverGeneration: 1)))
    let resolved = snapshot.resolveWindow(windowId: 1000, observerGeneration: 1, expectedWindowGeneration: token)
    test.check({ if case .success = refreshed, case .success(let handle) = resolved {
        return ObjectIdentifier(handle.element) == ObjectIdentifier(fresh.element) && snapshot.windowGenerations["1000"] == token
    }; return false }(), "cache-audit/equivalent-immutable-notification-capsule-does-not-overwrite-refreshed-canonical-setter-wrapper")
    snapshot.stop()
}
