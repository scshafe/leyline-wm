import Foundation
import LeylineModel

/// Real control socket/client route and bounded request records; all lifecycle
/// work is injected. No AppKit, tap, AX, deployed journal, reset or launchctl.
func runResidentControlsClientScenarios(home: String, test: inout SelfTest) {
    let path = home + "/leylined/Fixtures/resident/control-requests.json"
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data) else {
        test.check(false, "control/fixture-load"); return
    }
    let revision = UInt64(fixture.at(path: "revision")!.intValue!)
    let completedRevision = UInt64(fixture.at(path: "completed_revision")!.intValue!)
    let requests = ResidentControlRequests()
    let soft = fixture.at(path: "soft")!.objectValue!
    let first = requests.admit(soft, revision: revision)
    test.check(first.intent?.hard == false && first.intent?.resume == nil
        && first.result.at(path: "phase")?.stringValue == "queued"
        && !ResidentCommandClient.isTerminal(first.result), "control/soft-reset-admission-never-claims-completed-readiness")
    let duplicate = requests.admit(soft, revision: completedRevision)
    test.check(duplicate.intent == nil && duplicate.result == first.result, "control/queued-duplicate-reuses-original-request-and-revision")
    var allocations = 0
    let started = requests.begin(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence) { allocations += 1; return 9 }
    test.check(started == 9 && requests.begin(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, allocateGeneration: { allocations += 1; return 10 }) == nil
        && allocations == 1, "control/queued-work-allocates-one-lifecycle-fence-only-once")
    test.check(requests.admit(fixture.at(path: "conflict")!.objectValue!, revision: revision).result.at(path: "reason")?.stringValue == "control_request_id_conflict",
        "control/different-reset-payload-cannot-reuse-request-identity")
    test.check(requests.admit(fixture.at(path: "hard")!.objectValue!, revision: revision).result.at(path: "reason")?.stringValue == "resident_control_busy",
        "control/another-reset-cannot-overlap-active-lifecycle")
    let terminal = requests.complete(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, status: .accepted, revision: completedRevision,
        reason: nil, details: fixture.at(path: "completed")!.objectValue!)!
    test.check(requests.admit(soft, revision: completedRevision).result == terminal
        && requests.complete(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, status: .failed, revision: completedRevision, reason: "late") == nil,
        "control/completed-replay-is-idempotent-and-late-completion-cannot-overwrite")
    let stale = requests.admit(fixture.at(path: "stale")!.objectValue!, revision: revision)
    test.check(stale.intent == nil && stale.result.at(path: "reason")?.stringValue == "expected_revision_mismatch"
        && requests.result(requestID: fixture.at(path: "stale.request_id")!.stringValue!, revision: completedRevision) == stale.result,
        "control/stale-revision-refusal-is-terminal-and-cached")
    for key in ["bad_mode", "bad_resume", "bad_revision"] {
        test.check(requests.admit(fixture.at(path: key)!.objectValue!, revision: revision).intent == nil,
            "control/malformed-" + key + "-never-acquires-lifecycle")
    }
    let off = requests.admit(fixture.at(path: "off")!.objectValue!, revision: revision)
    test.check(off.intent?.hard == false && off.intent?.resume == false, "control/no-restart-is-an-explicit-off-capability-state")
    let stop = requests.admit(fixture.at(path: "stop")!.objectValue!, revision: revision)
    let superseded = requests.supersede(except: stop.intent!.requestID, revision: completedRevision)
    test.check(superseded.count == 1 && superseded[0].at(path: "request_id")?.stringValue == off.intent!.requestID
        && superseded[0].at(path: "reason")?.stringValue == "resident_control_superseded"
        && requests.complete(requestID: off.intent!.requestID, expectedAdmissionSequence: off.intent!.admissionSequence, status: .accepted, revision: completedRevision, reason: nil) == nil,
        "control/stop-terminalizes-obsolete-reset-and-fences-late-ready-ack")
    test.check(requests.begin(requestID: off.intent!.requestID, expectedAdmissionSequence: off.intent!.admissionSequence, allocateGeneration: { allocations += 1; return 11 }) == nil
        && allocations == 1, "control/terminalized-queued-work-cannot-acquire-a-late-lifecycle-fence")
    let timeoutRequests = ResidentControlRequests()
    let timed = timeoutRequests.admit(fixture.at(path: "off")!.objectValue!, revision: revision)
    _ = timeoutRequests.complete(requestID: timed.intent!.requestID, expectedAdmissionSequence: timed.intent!.admissionSequence, status: .failed, revision: revision, reason: "resident_control_timeout")
    test.check(timeoutRequests.begin(requestID: timed.intent!.requestID, expectedAdmissionSequence: timed.intent!.admissionSequence, allocateGeneration: { allocations += 1; return 12 }) == nil
        && allocations == 1, "control/expired-admission-cannot-start-after-a-stalled-lifecycle-queue")
    let bounded = ResidentControlRequests()
    for index in 0..<65 {
        let entry: JSONObject = ["request_id": .string("bounded-\(index)"), "action_id": .string("stop")]
        let admitted = bounded.admit(entry, revision: revision)
        if let intent = admitted.intent { _ = bounded.complete(requestID: intent.requestID, expectedAdmissionSequence: intent.admissionSequence, status: .accepted, revision: revision, reason: nil) }
    }
    test.check(bounded.result(requestID: "bounded-0", revision: revision).at(path: "reason")?.stringValue == "control_request_unknown"
        && bounded.result(requestID: "bounded-64", revision: revision).at(path: "status")?.stringValue == "accepted",
        "control/result-cache-retires-oldest-terminal-at-fixed-64-record-bound")
    runResidentControlTimeoutScenarios(home: home, test: &test)
    let maintenance = ResidentMaintenance()
    let firstOutcome = DispatchSemaphore(value: 0), duplicateOutcome = DispatchSemaphore(value: 0)
    let outcomeProof = ResidentAtomic<UInt64>(0)
    let reusedID = fixture.at(path: "hard.request_id")!.stringValue!
    _ = maintenance.begin(requestID: reusedID, stopParticipants: [{ $0() }], reset: { fixture.at(path: "hard_completed")! }, onOutcome: { outcome in
        if CoreRuntimeServices.maintenanceOutcomeIsCurrent(outcome, requestID: reusedID, generation: 9, currentGeneration: 9,
            epochIsCurrent: maintenance.isCurrentEpoch) { outcomeProof.wrappingAdd(32, ordering: .acquiringAndReleasing) }
        firstOutcome.signal()
    })
    let initialObserved = firstOutcome.wait(timeout: .now() + .seconds(2)) == .success
    _ = maintenance.begin(requestID: reusedID, stopParticipants: [{ $0() }], reset: { fixture.at(path: "hard_completed")! }, onOutcome: { outcome in
        if case .failure(let failure) = outcome, failure.code == "MAINTENANCE.DUPLICATE_REQUEST", failure.epoch == nil {
            outcomeProof.wrappingAdd(1, ordering: .acquiringAndReleasing)
        }
        if CoreRuntimeServices.maintenanceOutcomeIsCurrent(outcome, requestID: reusedID, generation: 9, currentGeneration: 9,
            epochIsCurrent: maintenance.isCurrentEpoch) { outcomeProof.wrappingAdd(2, ordering: .acquiringAndReleasing) }
        if !CoreRuntimeServices.maintenanceOutcomeIsCurrent(outcome, requestID: reusedID, generation: 9, currentGeneration: 10,
            epochIsCurrent: maintenance.isCurrentEpoch) { outcomeProof.wrappingAdd(4, ordering: .acquiringAndReleasing) }
        if !CoreRuntimeServices.maintenanceOutcomeIsCurrent(outcome, requestID: "another-control", generation: 9, currentGeneration: 9,
            epochIsCurrent: maintenance.isCurrentEpoch) { outcomeProof.wrappingAdd(8, ordering: .acquiringAndReleasing) }
        let stale = MaintenanceFailure(code: "MAINTENANCE.RESET_TIMEOUT", message: "fixture", requestID: reusedID, epoch: 1)
        if !CoreRuntimeServices.maintenanceOutcomeIsCurrent(.failure(stale), requestID: reusedID, generation: 9, currentGeneration: 9,
            epochIsCurrent: { _ in false }) { outcomeProof.wrappingAdd(16, ordering: .acquiringAndReleasing) }
        duplicateOutcome.signal()
    })
    test.check(initialObserved && duplicateOutcome.wait(timeout: .now() + .seconds(2)) == .success
        && outcomeProof.load(ordering: .acquiring) == 63,
        "control/actual-nil-epoch-maintenance-refusal-completes-current-request-without-admitting-stale-outcomes")

    // Darwin's per-user temp prefix plus a UUID exceeds sockaddr_un.sun_path.
    let directory = URL(fileURLWithPath: "/tmp/ley-control-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = CoreServer(socketPath: directory.appendingPathComponent("core.sock").path)
        let native = ResidentControlRequests()
        server.configureResidentControls { [weak server] request in
            guard let server else { return .object(["ok": .bool(false), "reason": .string("fixture_stopped")]) }
            let id = request["request_id"]?.stringValue ?? ""
            if request["op"]?.stringValue == "control-result" {
                let current = native.result(requestID: id, revision: server.currentRevision)
                if current.at(path: "phase")?.stringValue == "queued",
                   let done = native.complete(requestID: id, expectedAdmissionSequence: UInt64(current.at(path: "control_admission_sequence")!.intValue!), status: .accepted, revision: server.currentRevision,
                        reason: nil, details: fixture.at(path: "hard_completed")!.objectValue!) {
                    _ = server.applyWorldDelta(["event": .string("resident_control_result"), "control_last_result": done])
                }
                return current
            }
            return native.admit(request, revision: server.currentRevision).result
        }
        guard server.start() else { test.check(false, "control/temp-socket-start"); return }
        defer { server.stop() }
        let id = fixture.at(path: "hard.request_id")!.stringValue!
        let args = fixture.at(path: "hard.args")!.canonical()
        let result = ResidentCommandClient.execute(operation: "control", arguments: ["reset", "--socket", server.socketPath,
            "--request-id", id, "--args-json", args, "--timeout-seconds", "2"])
        test.check(result.exitCode == 0 && result.value.at(path: "meta.completed")?.boolValue == true
            && result.value.at(path: "data.request_id")?.stringValue == id
            && result.value.at(path: "data.journal_reset")?.boolValue == true
            && result.value.at(path: "data.readiness_verified")?.boolValue == false,
            "control/real-socket-completion-preserves-reset-proof-and-separate-off-readiness")
        let noControls = CoreServer(socketPath: directory.appendingPathComponent("no-controls.sock").path)
        guard noControls.start() else { test.check(false, "control/no-controls-socket-start"); return }
        defer { noControls.stop() }
        let refused = ResidentCommandClient.execute(operation: "control", arguments: ["reset", "--socket", noControls.socketPath,
            "--request-id", fixture.at(path: "off.request_id")!.stringValue!, "--no-wait"])
        test.check(refused.value.at(path: "error.code")?.stringValue == "resident_control_unavailable"
            && refused.value.at(path: "meta.mutation_fallback")?.boolValue == false,
            "control/unavailable-controls-refuse-without-fallback")
    } catch { test.check(false, "control/temp-fixture-error: \(error)") }
}
