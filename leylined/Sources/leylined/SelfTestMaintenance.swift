import Foundation
import LeylineModel

private final class MaintenanceTestRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var callbacks: [String: [Result<JSONValue, MaintenanceFailure>]] = [:]
    private var resets: [String] = []
    private var destructivePhases: [String] = []
    private var activations = 0
    private var stopped = true
    func record(_ name: String, _ result: Result<JSONValue, MaintenanceFailure>) {
        condition.lock(); callbacks[name, default: []].append(result)
        if case .success = result { activations += 1; stopped = false }
        condition.broadcast(); condition.unlock()
    }
    func reset(_ name: String) { condition.lock(); resets.append(name); condition.broadcast(); condition.unlock() }
    func destructive(_ name: String) { condition.lock(); destructivePhases.append(name); condition.broadcast(); condition.unlock() }
    func wait(_ name: String, count: Int = 1) -> Result<JSONValue, MaintenanceFailure>? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while (callbacks[name]?.count ?? 0) < count {
            if !condition.wait(until: deadline) { return nil }
        }
        return callbacks[name]?.last
    }
    func waitForReset(_ name: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !resets.contains(name) { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func resetCount(_ name: String) -> Int { condition.lock(); defer { condition.unlock() }; return resets.filter { $0 == name }.count }
    func outcomeCount(_ name: String) -> Int { condition.lock(); defer { condition.unlock() }; return callbacks[name]?.count ?? 0 }
    var snapshot: (activations: Int, stopped: Bool, destructiveCount: Int) {
        condition.lock(); defer { condition.unlock() }; return (activations, stopped, destructivePhases.count)
    }
}
private final class MaintenanceTestStops: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls: [String] = []
    private var acknowledgements: [String: @Sendable () -> Void] = [:]
    func participant(_ name: String) -> ResidentMaintenance.StopParticipant {
        { [self] acknowledgement in
            condition.lock(); calls.append(name); acknowledgements[name] = acknowledgement
            condition.broadcast(); condition.unlock()
        }
    }
    func waitForCalls(_ count: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }; let deadline = Date().addingTimeInterval(2)
        while calls.count < count { if !condition.wait(until: deadline) { return false } }; return true
    }
    func acknowledge(_ name: String) {
        condition.lock(); let acknowledgement = acknowledgements[name]; condition.unlock(); acknowledgement?()
    }
}
private final class MaintenanceTestBlockedReset: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var returned = false
    func block() {
        condition.lock(); defer { condition.unlock() }
        while !released { condition.wait() }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func finish() { condition.lock(); returned = true; condition.broadcast(); condition.unlock() }
    func waitForReturn() -> Bool {
        condition.lock(); defer { condition.unlock() }; let deadline = Date().addingTimeInterval(2)
        while !returned { if !condition.wait(until: deadline) { return false } }; return true
    }
}
private enum MaintenanceFixtureIOFailure: Error { case renameFailed }
private func maintenanceFailureCode(_ result: Result<JSONValue, MaintenanceFailure>?) -> String? {
    if case .failure(let failure) = result { return failure.code }; return nil
}
private func maintenanceSucceeded(_ result: Result<JSONValue, MaintenanceFailure>?) -> Bool {
    if case .success(let value) = result { return value.at(path: "checkpoint_reset_verified")?.boolValue == true }; return false
}

/// Fixture-only maintenance barrier and epoch tests. No live files, AX, event tap or AppKit.
func runMaintenanceSelfTest() -> Int32 {
    var test = SelfTest()
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/maintenance/exclusive_reset.json"
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data),
          let milliseconds = fixture.at(path: "test_deadline_milliseconds")?.intValue,
          let resetResult = fixture.at(path: "reset_result"),
          let names = fixture.at(path: "participants")?.arrayValue?.compactMap(\.stringValue), names.count == 5 else {
        test.check(false, "maintenance/fixture-load"); return test.finish("maintenance")
    }
    let scenarios = fixture.at(path: "scenarios")?.arrayValue?.compactMap(\.stringValue) ?? []
    test.check(scenarios.count == 14 && Set(scenarios).count == 14
        && fixture.at(path: "production_deadline_milliseconds")?.intValue == Int64(ResidentMaintenance.deadlineMilliseconds),
        "maintenance/nonempty-fourteen-scenario-fixture-and-fixed-production-two-second-deadline")
    runMaintenanceBarrierScenarios(names: names, resetResult: resetResult, test: &test)
    runMaintenanceTimeoutScenarios(names: names, resetResult: resetResult, milliseconds: UInt64(milliseconds), test: &test)
    runMaintenanceBlockedResetScenarios(resetResult: resetResult, milliseconds: UInt64(milliseconds), test: &test)
    runMaintenanceBoundedScenarios(resetResult: resetResult, test: &test)
    runJournalQuarantineScenarios(test: &test)
    return test.finish("maintenance")
}

private func runMaintenanceBarrierScenarios(names: [String], resetResult: JSONValue, test: inout SelfTest) {
    let coordinator = ResidentMaintenance(), recorder = MaintenanceTestRecorder(), stops = MaintenanceTestStops()
    let admitted = coordinator.begin(requestID: "all-ACK", stopParticipants: names.map(stops.participant), reset: { permit in
        try permit.check(); recorder.reset("all-ACK"); recorder.destructive("all-ACK"); return resetResult
    }, onOutcome: { recorder.record("all-ACK", $0) })
    let stopCalls = stops.waitForCalls(names.count)
    for name in names.dropLast() { stops.acknowledge(name) }
    test.check(admitted && stopCalls && coordinator.isExclusive && recorder.snapshot.stopped
        && recorder.resetCount("all-ACK") == 0 && coordinator.snapshot().at(path: "acknowledged_count")?.intValue == 4,
        "maintenance/Root-stopped-state-and-all-five-quiescence-ACKs-precede-reset")
    let duplicate = coordinator.begin(requestID: "all-ACK", stopParticipants: [], reset: { resetResult }, onOutcome: { recorder.record("duplicate", $0) })
    let overlap = coordinator.begin(requestID: "overlap", stopParticipants: [], reset: { resetResult }, onOutcome: { recorder.record("overlap", $0) })
    test.check(!duplicate && maintenanceFailureCode(recorder.wait("duplicate")) == "MAINTENANCE.DUPLICATE_REQUEST"
        && !overlap && maintenanceFailureCode(recorder.wait("overlap")) == "MAINTENANCE.ALREADY_ACTIVE",
        "maintenance/duplicate-and-overlap-reject-with-explicit-bounded-admission")
    stops.acknowledge(names.last!)
    let result = recorder.wait("all-ACK")
    test.check(maintenanceSucceeded(result) && recorder.resetCount("all-ACK") == 1 && recorder.snapshot.activations == 1
        && !coordinator.isExclusive, "maintenance/all-ACKs-run-exclusive-reset-and-deliver-one-verified-activation-callback")
    for name in names { stops.acknowledge(name); stops.acknowledge(name) }
    test.check(recorder.outcomeCount("all-ACK") == 1 && recorder.resetCount("all-ACK") == 1,
        "maintenance/late-duplicate-ACKs-cannot-reset-or-complete-success-twice")
    if case .success(let value) = result, let epoch = value.at(path: "maintenance_epoch")?.intValue {
        test.check(value.at(path: "maintenance_request_id")?.stringValue == "all-ACK" && coordinator.isCurrentEpoch(UInt64(epoch)),
            "maintenance/success-carries-request-and-epoch-for-Root-activation-fence")
    } else { test.check(false, "maintenance/success-carries-request-and-epoch-for-Root-activation-fence") }
    let failure = ResidentMaintenance(), failed = MaintenanceTestRecorder()
    _ = failure.begin(requestID: "IO-failure", stopParticipants: [{ $0() }], reset: { permit in
        try permit.check(); failed.reset("IO-failure"); throw MaintenanceFixtureIOFailure.renameFailed
    }, onOutcome: { failed.record("IO-failure", $0) })
    test.check(maintenanceFailureCode(failed.wait("IO-failure")) == "MAINTENANCE.RESET_FAILED"
        && failed.snapshot.stopped && failed.snapshot.activations == 0 && !failure.isExclusive,
        "maintenance/reset-IO-failure-is-explicit-and-never-auto-activates")
}

private func runMaintenanceTimeoutScenarios(names: [String], resetResult: JSONValue, milliseconds: UInt64, test: inout SelfTest) {
    for partial in [false, true] {
        let coordinator = ResidentMaintenance(deadlineMilliseconds: milliseconds), recorder = MaintenanceTestRecorder(), stops = MaintenanceTestStops()
        let name = partial ? "partial-ACK" : "no-ACK"
        _ = coordinator.begin(requestID: name, stopParticipants: names.map(stops.participant), reset: {
            recorder.reset(name); return resetResult
        }, onOutcome: { recorder.record(name, $0) })
        _ = stops.waitForCalls(names.count)
        if partial { for name in names.dropLast() { stops.acknowledge(name) } }
        let expired = recorder.wait(name)
        test.check(maintenanceFailureCode(expired) == "MAINTENANCE.PARTICIPANTS_TIMEOUT" && recorder.resetCount(name) == 0
            && recorder.snapshot.stopped && recorder.snapshot.activations == 0 && !coordinator.isExclusive,
            "maintenance/\(name)-deadline-never-resets-and-leaves-Root-stopped")
        for participant in names { stops.acknowledge(participant) }
        test.check(recorder.resetCount(name) == 0 && recorder.outcomeCount(name) == 1,
            "maintenance/\(name)-late-ACKs-cannot-author-reset")
        let newStops = MaintenanceTestStops()
        _ = coordinator.begin(requestID: name + "-new", stopParticipants: [newStops.participant("new-stop")], reset: { resetResult },
                              onOutcome: { recorder.record(name + "-new", $0) })
        _ = newStops.waitForCalls(1)
        for participant in names { stops.acknowledge(participant) }
        test.check(coordinator.snapshot().at(path: "request_id")?.stringValue == name + "-new"
            && coordinator.snapshot().at(path: "acknowledged_count")?.intValue == 0 && recorder.outcomeCount(name + "-new") == 0,
            "maintenance/\(name)-old-ACK-or-deadline-cannot-certify-new-epoch")
        newStops.acknowledge("new-stop")
        test.check(maintenanceSucceeded(recorder.wait(name + "-new")) && !coordinator.isCurrentEpoch(1),
            "maintenance/\(name)-fresh-epoch-has-own-barrier-and-invalidates-old-activation-fence")
    }
}

private func runMaintenanceBlockedResetScenarios(resetResult: JSONValue, milliseconds: UInt64, test: inout SelfTest) {
    let coordinator = ResidentMaintenance(deadlineMilliseconds: milliseconds), recorder = MaintenanceTestRecorder(), gate = MaintenanceTestBlockedReset()
    _ = coordinator.begin(requestID: "blocked-reset", stopParticipants: [{ $0() }], reset: { permit in
        recorder.reset("blocked-reset"); gate.block(); defer { gate.finish() }
        try permit.check(); recorder.destructive("blocked-reset"); throw MaintenanceFixtureIOFailure.renameFailed
    }, onOutcome: { recorder.record("blocked-reset", $0) })
    let started = recorder.waitForReset("blocked-reset"), timeout = recorder.wait("blocked-reset")
    test.check(started && maintenanceFailureCode(timeout) == "MAINTENANCE.RESET_TIMEOUT" && coordinator.isExclusive
        && recorder.snapshot.stopped && recorder.snapshot.activations == 0,
        "maintenance/blocked-reset-deadline-reports-failure-with-exclusive-epoch-retained")
    let blocked = coordinator.begin(requestID: "cannot-overlap", stopParticipants: [], reset: { resetResult },
                                    onOutcome: { recorder.record("cannot-overlap", $0) })
    test.check(!blocked && maintenanceFailureCode(recorder.wait("cannot-overlap")) == "MAINTENANCE.ALREADY_ACTIVE",
        "maintenance/timed-out-running-IO-never-admits-second-destructive-reset")
    gate.release(); _ = gate.waitForReturn()
    let drained = DispatchSemaphore(value: 0)
    _ = coordinator.whenIdle { drained.signal() }
    let didDrain = drained.wait(timeout: .now() + 2) == .success
    let after = MaintenanceTestStops()
    let admitted = coordinator.begin(requestID: "after-blocked", stopParticipants: [after.participant("after-stop")], reset: { resetResult },
                                      onOutcome: { recorder.record("after-blocked", $0) })
    _ = after.waitForCalls(1)
    test.check(didDrain && admitted && recorder.snapshot.destructiveCount == 0 && recorder.snapshot.activations == 0 && recorder.outcomeCount("blocked-reset") == 1
        && coordinator.snapshot().at(path: "request_id")?.stringValue == "after-blocked",
        "maintenance/expired-permit-prevents-rename-and-late-reset-failure-cannot-complete-new-epoch")
    _ = coordinator.cancel(requestID: "after-blocked")
    let cancel = ResidentMaintenance(), cancelled = MaintenanceTestRecorder(), cancelGate = MaintenanceTestBlockedReset()
    _ = cancel.begin(requestID: "cancel-reset", stopParticipants: [{ $0() }], reset: { permit in
        cancelled.reset("cancel-reset"); cancelGate.block(); defer { cancelGate.finish() }; try permit.check()
        cancelled.destructive("cancel-reset"); return resetResult
    }, onOutcome: { cancelled.record("cancel-reset", $0) })
    _ = cancelled.waitForReset("cancel-reset")
    let acceptedCancel = cancel.cancel(requestID: "cancel-reset")
    test.check(acceptedCancel && maintenanceFailureCode(cancelled.wait("cancel-reset")) == "MAINTENANCE.CANCELLED" && cancel.isExclusive,
        "maintenance/cancellation-invalidates-running-reset-without-releasing-exclusive-IO")
    cancelGate.release(); _ = cancelGate.waitForReturn()
    test.check(cancelled.snapshot.destructiveCount == 0 && cancelled.snapshot.activations == 0 && cancelled.outcomeCount("cancel-reset") == 1,
        "maintenance/cancelled-reset-cannot-rename-or-activate-through-late-success")
}

private func runMaintenanceBoundedScenarios(resetResult: JSONValue, test: inout SelfTest) {
    let coordinator = ResidentMaintenance(), recorder = MaintenanceTestRecorder()
    for index in 0..<70 {
        let name = "bounded-\(index)"
        _ = coordinator.begin(requestID: name, stopParticipants: [{ $0() }], reset: { resetResult }, onOutcome: { recorder.record(name, $0) })
        _ = recorder.wait(name)
    }
    test.check(coordinator.snapshot().at(path: "recent_request_count")?.intValue == 64,
        "maintenance/recent-request-registry-is-bounded-at-sixty-four")
    let duplicate = coordinator.begin(requestID: "bounded-69", stopParticipants: [], reset: { resetResult }, onOutcome: { recorder.record("recent-duplicate", $0) })
    test.check(!duplicate && maintenanceFailureCode(recorder.wait("recent-duplicate")) == "MAINTENANCE.DUPLICATE_REQUEST",
        "maintenance/completed-recent-request-cannot-repeat-destructive-reset")
    let empty = coordinator.begin(requestID: "empty-barrier", stopParticipants: [], reset: {
        recorder.reset("empty-barrier"); return resetResult
    }, onOutcome: { recorder.record("empty-barrier", $0) })
    test.check(!empty && maintenanceFailureCode(recorder.wait("empty-barrier")) == "MAINTENANCE.PARTICIPANTS_MISSING"
        && recorder.resetCount("empty-barrier") == 0, "maintenance/empty-proof-barrier-refuses-without-reset")
}

private func runJournalQuarantineScenarios(test: inout SelfTest) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ley-quarantine-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixturePath = responsivenessRepositoryRoot() + "/leylined/Fixtures/maintenance/exclusive_reset.json"
        let fixture = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let source = Data(fixture.at(path: "quarantine_source")!.stringValue!.utf8)
        let path = directory.appendingPathComponent("journal.jsonl").path
        try source.write(to: URL(fileURLWithPath: path))
        guard chmod(path, mode_t(0o600)) == 0 else { throw MaintenanceFixtureIOFailure.renameFailed }
        let journal = ResidentEffectorFileJournal(path: path)
        let backup = try journal.quarantineAndReset(check: {})
        let archived = try backup.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let recovered = try journal.recover()
        test.check(archived == source && recovered.highWaterRevision == 0 && recovered.records.isEmpty,
            "maintenance/real-journal-quarantine-preserves-corrupt-source-and-creates-durable-empty-file")
        try source.write(to: URL(fileURLWithPath: path))
        guard chmod(path, mode_t(0o600)) == 0 else { throw MaintenanceFixtureIOFailure.renameFailed }
        do {
            _ = try journal.quarantineAndReset(check: { throw MaintenanceFailure(code: "MAINTENANCE.PERMIT_INVALID", message: "expired fixture", requestID: "fixture") })
            test.check(false, "maintenance/expired-real-journal-permit-cannot-rename-or-clear")
        } catch {
            let retainedSource = try Data(contentsOf: URL(fileURLWithPath: path))
            test.check(retainedSource == source,
                "maintenance/expired-real-journal-permit-cannot-rename-or-clear")
        }
    } catch { test.check(false, "maintenance/journal-quarantine-fixture-failed: \(error)") }
}
