import Foundation
import LeylineModel

private final class RecoveryFixtureOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [(UInt64, @Sendable () -> Void)] = []
    private var work: [@Sendable () -> Void] = []
    func schedule(_ delay: UInt64, _ operation: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock(); timers.append((delay, operation)); lock.unlock()
        // Deliberately keep cancelled callbacks: token gates must reject already queued delivery.
        return {}
    }
    func enqueue(_ operation: @escaping @Sendable () -> Void) { lock.lock(); work.append(operation); lock.unlock() }
    func fireTimer() { lock.lock(); let item = timers.isEmpty ? nil : timers.removeFirst(); lock.unlock(); item?.1() }
    func runOne() { lock.lock(); let item = work.isEmpty ? nil : work.removeFirst(); lock.unlock(); item?() }
    var timerCount: Int { lock.lock(); defer { lock.unlock() }; return timers.count }
    var workCount: Int { lock.lock(); defer { lock.unlock() }; return work.count }
}
private final class RecoveryFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = true
    private var session: UInt64 = 3
    private var epoch: UInt64 = 7
    private var captures: [String] = []
    private var deltas: [JSONObject] = []
    var isFailing: Bool { get { lock.lock(); defer { lock.unlock() }; return failure } set { lock.lock(); failure = newValue; lock.unlock() } }
    var sessionGeneration: UInt64 { get { lock.lock(); defer { lock.unlock() }; return session } set { lock.lock(); session = newValue; lock.unlock() } }
    var observationEpoch: UInt64 { get { lock.lock(); defer { lock.unlock() }; return epoch } set { lock.lock(); epoch = newValue; lock.unlock() } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return captures.count }
    var latest: JSONObject? { lock.lock(); defer { lock.unlock() }; return deltas.last }
    func capture(_ request: ProjectionSnapshotRequest) -> ProjectionWorldSnapshot {
        lock.lock(); captures.append(request.reason); let failing = failure; lock.unlock()
        return ProjectionWorldSnapshot(windowsOnscreen: 1, focus: failing ? .null : .object(["window_id": .int(11), "eligible": .bool(true)]),
            observation: ["world_complete": .bool(!failing), "failure_code": failing ? .string("ax_window_identity_read_failed:-25204") : .null,
                          "world_failure_code": failing ? .string("ax_window_identity_read_failed:-25204") : .null])
    }
    func deliver(_ delta: JSONObject) { lock.lock(); deltas.append(delta); lock.unlock() }
}
private final class RecoveryFixtureObserver: AccessibilityFocusObserving, @unchecked Sendable {
    var onEvent: ((AccessibilityFocusEvent) -> Void)?
    var onHealthChanged: ((AccessibilityObserverHealth) -> Void)?
    var attached = 0
    func attach(to pid: pid_t, generation: UInt64) -> AccessibilityObserverHealth {
        attached += 1
        return .init(ready: true, pid: pid, generation: generation, windowNotificationsReady: true, degradedReason: nil)
    }
    func detach(generation: UInt64) {}
}

/// Actual feed + actual recovery coordinator; fake scheduling/AX capture supplies deterministic faults.
func runProjectionTransientRecoveryScenarios(test: inout SelfTest) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/feed/transient-recovery.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let codes = fixture.at(path: "transient_codes")?.arrayValue?.compactMap(\.stringValue) else {
        test.check(false, "transient-recovery/fixture-load"); return
    }
    test.check(fixture.at(path: "scenarios")?.arrayValue?.count == 8 && codes.count == 5
        && codes.allSatisfy(ProjectionTransientRecovery.isTransient)
        && !ProjectionTransientRecovery.isTransient(fixture.at(path: "nontransient_code")!.stringValue!)
        && fixture.at(path: "delay_milliseconds")?.intValue == Int64(ProjectionTransientRecovery.delayMilliseconds),
        "transient-recovery/nonempty-eight-scenario-fixture-with-explicit-cannotComplete-and-one-hundred-ms-budget")
    let operations = RecoveryFixtureOperations(), state = RecoveryFixtureState(), observer = RecoveryFixtureObserver()
    let recovery = ProjectionTransientRecovery(execute: { operations.enqueue($0) }, schedule: { operations.schedule($0, $1) })
    let feed = ProjectionInputFeed(observer: observer, captureTargeted: { state.capture($0) }, executeOnMain: { operations.enqueue($0) },
        transientRecovery: recovery, recoverySessionGeneration: { state.sessionGeneration }, recoveryObservationEpoch: { state.observationEpoch },
        deliver: { state.deliver($0) })
    let app = ProjectionApplication(pid: 12157, name: "Fixture")
    feed.start(frontmost: app)
    observer.onHealthChanged?(.degraded(pid: app.pid, generation: feed.currentGeneration, reason: codes[1])); operations.runOne()
    test.check(operations.timerCount == 1 && recovery.snapshot.at(path: "scheduled_count")?.intValue == 1
        && state.latest?["focus"] == .null, "transient-recovery/duplicate-world-and-focus-faults-coalesce-and-stay-unavailable")
    state.isFailing = false
    operations.fireTimer(); operations.runOne()
    test.check(observer.attached == 2 && state.latest?["event"] == .string("explicit_recovery")
        && state.latest?["observation"]?.at(path: "world_recovered")?.boolValue == true
        && state.latest?["transient_recovery_first_failure"]?.stringValue == codes[2]
        && recovery.snapshot.at(path: "attempt_count")?.intValue == 1,
        "transient-recovery/one-fresh-baseline-and-attach-publishes-verified-recovery-with-first-cause")
    state.isFailing = true
    observer.onHealthChanged?(.degraded(pid: app.pid, generation: feed.currentGeneration, reason: codes[1])); operations.runOne()
    test.check(operations.timerCount == 0 && recovery.snapshot.at(path: "attempt_count")?.intValue == 1,
        "transient-recovery/failure-after-attempt-cannot-self-rearm-or-create-infinite-loop")
    feed.applicationActivated(app)
    operations.fireTimer(); operations.runOne()
    test.check(recovery.snapshot.at(path: "attempt_count")?.intValue == 2 && operations.timerCount == 0
        && state.latest?["observation"]?.at(path: "world_recovered")?.boolValue == false && state.latest?["focus"] == .null,
        "transient-recovery/distinct-external-activation-rearms-once-and-failed-attempt-stays-unavailable")
    feed.applicationActivated(app); let before = state.count
    operations.fireTimer()
    feed.applicationActivated(app)
    operations.runOne()
    test.check(state.count == before + 1 && recovery.snapshot.at(path: "attempt_count")?.intValue == 2,
        "transient-recovery/stale-queued-observer-generation-performs-no-capture-or-attach")
    operations.fireTimer(); state.sessionGeneration += 1; operations.runOne()
    test.check(recovery.snapshot.at(path: "attempt_count")?.intValue == 2,
        "transient-recovery/session-change-invalidates-queued-recovery-before-external-read")
    feed.applicationActivated(app); operations.fireTimer(); state.observationEpoch += 1; operations.runOne()
    test.check(recovery.snapshot.at(path: "attempt_count")?.intValue == 2,
        "transient-recovery/global-observation-epoch-change-invalidates-queued-recovery")
    feed.applicationActivated(app); let stopCount = state.count
    feed.stop(); operations.fireTimer(); operations.runOne()
    test.check(state.count == stopCount && recovery.snapshot.at(path: "phase")?.stringValue == "inactive",
        "transient-recovery/stop-cancels-even-an-already-delivered-backoff-callback")
    let isolated = RecoveryFixtureOperations()
    let barrier = ProjectionTransientRecovery(execute: { isolated.enqueue($0) }, schedule: { isolated.schedule($0, $1) })
    let context = ProjectionTransientRecovery.Context(observerGeneration: 1, sessionGeneration: 2, observationEpoch: 3)
    barrier.rearm(context)
    let seen = RecoveryFixtureState()
    _ = barrier.observeFailure(codes[0], context: context, isCurrent: { _ in true }, operation: { _, _ in
        barrier.invalidate()
        seen.observationEpoch = barrier.requiredObservationEpoch ?? 0
    })
    isolated.fireTimer(); isolated.runOne()
    test.check(seen.observationEpoch == 3 && barrier.requiredObservationEpoch == nil,
        "transient-recovery/blocked-capture-retains-original-publication-epoch-through-invalidation")
}

/// Boundary scenarios verify the whole-message reserve independently of AX IO.
func runProjectionAXReadBudgetScenarios(test: inout SelfTest) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/feed/ax-read-budget.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 5 else {
        test.check(false, "ax-read-budget/nonempty-fixture-load"); return
    }
    for row in scenarios {
        let started = UInt64(row.at(path: "started")!.intValue!), now = UInt64(row.at(path: "now")!.intValue!)
        let allowed = projectionAXReadBudgetAllowsCall(started: started, now: now)
        test.check(allowed == row.at(path: "allowed")!.boolValue!
            && (!allowed || now - started + TargetedProjectionSnapshot.axMessageBudgetNs <= TargetedProjectionSnapshot.axTotalReadBudgetNs),
            "ax-read-budget/" + row.at(path: "name")!.stringValue!)
    }
}
