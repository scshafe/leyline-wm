import Foundation
import LeylineModel

private final class EffectorTestJournal: ResidentEffectorJournal, @unchecked Sendable {
    let condition = NSCondition()
    var records: [JSONValue] = []
    var fail = false
    var failOnType: String?
    var blocked = false
    var blockedOnType: String?
    var entered = false
    var enteredTypes: Set<String> = []
    var released = false
    func append(_ record: JSONValue) throws {
        condition.lock(); defer { condition.unlock() }
        entered = true
        let type = record.at(path: "type")?.stringValue ?? ""
        enteredTypes.insert(type); condition.broadcast()
        while blocked && (blockedOnType == nil || blockedOnType == type) && !released { condition.wait() }
        if fail || record.at(path: "type")?.stringValue == failOnType {
            throw ResidentEffectorJournalError.corrupt(path: "injected", line: 1)
        }
        records.append(record); condition.broadcast()
    }
    func snapshot() -> [JSONValue] { condition.lock(); defer { condition.unlock() }; return records }
    func waitForEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !entered { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func waitForType(_ type: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !enteredTypes.contains(type) { if !condition.wait(until: deadline) { return false } }
        return true
    }
}

private final class EffectorTestPort: ResidentEffectorPort, @unchecked Sendable {
    let condition = NSCondition()
    let journal: EffectorTestJournal
    var issues: [(ResidentEffectRequest, Frame)] = []
    var callbacks: [String: @Sendable (String?) -> Void] = [:]
    var journalFirst = true
    init(journal: EffectorTestJournal) { self.journal = journal }
    func issue(request: ResidentEffectRequest, frame: Frame,
               completion: @escaping @Sendable (String?) -> Void) {
        condition.lock()
        journalFirst = journalFirst && journal.snapshot().contains { $0.at(path: "request_id")?.stringValue == request.requestID }
        issues.append((request, frame)); callbacks[request.requestID] = completion
        condition.broadcast(); condition.unlock()
    }
    func cancel(requestID: String) {}
    func acknowledge(_ id: String, error: String? = nil, repeatCount: Int = 1) {
        condition.lock(); let callback = callbacks.removeValue(forKey: id); condition.unlock()
        for _ in 0..<repeatCount { callback?(error) }
    }
    func waitForIssues(_ count: Int, timeout: Double = 2) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while issues.count < count { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func snapshot() -> [(ResidentEffectRequest, Frame)] { condition.lock(); defer { condition.unlock() }; return issues }
}

private final class EffectorOutcomes: @unchecked Sendable {
    let condition = NSCondition()
    var values: [ResidentEffectOutcome] = []
    func append(_ value: ResidentEffectOutcome) { condition.lock(); values.append(value); condition.broadcast(); condition.unlock() }
    func waitFor(_ id: String) -> ResidentEffectOutcome? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !values.contains(where: { $0.requestID == id }) { if !condition.wait(until: deadline) { return nil } }
        return values.last(where: { $0.requestID == id })
    }
    func snapshot() -> [ResidentEffectOutcome] { condition.lock(); defer { condition.unlock() }; return values }
}

private final class EffectorReference: @unchecked Sendable {
    weak var value: ResidentEffector?
}

private final class EffectorFaults: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [String] = []
    func append(_ value: String) { condition.lock(); values.append(value); condition.broadcast(); condition.unlock() }
    func waitFor(_ value: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !values.contains(value) { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func snapshot() -> [String] { condition.lock(); defer { condition.unlock() }; return values }
}

private final class EffectorProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: UInt64 = 100
    private var stamps: [UInt64] = []
    func setTime(_ value: UInt64) { lock.lock(); clock = value; lock.unlock() }
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return clock }
    func record(_ value: UInt64) { lock.lock(); stamps.append(value); lock.unlock() }
    func snapshot() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return stamps }
}

func runEffectorSelfTest() -> Int32 {
    var tests = SelfTest()
    let base = Frame(x: 0, y: 0, w: 100, h: 80)
    let context = ResidentEffectContext(revision: 3, observerGeneration: 8, activeSpaceKey: "display:1/space:A",
        topologyRevision: 4, trusted: true, complete: true, spaceEnabled: true)
    func request(_ id: String, revision: UInt64 = 3, generation: UInt64 = 8,
                 space: String = "display:1/space:A", width: Double = 100) -> ResidentEffectRequest {
        ResidentEffectRequest(requestID: id, actionID: "resize.adjust.east", windowID: "11",
            expectedRevision: revision, observerGeneration: generation, activeSpaceKey: space,
            topologyRevision: 4, receiptNanos: 10, frame: Frame(x: base.x, y: base.y, w: width, h: base.h))
    }
    let journal = EffectorTestJournal(), outcomes = EffectorOutcomes()
    let port = EffectorTestPort(journal: journal)
    let mainClock = EffectorProgressProbe()
    let effector = ResidentEffector(context: context, journal: journal, port: port,
        now: { mainClock.now() }, onOutcome: { outcomes.append($0) })
    tests.check(effector.submit(request("bad-revision", revision: 2)).reason == "expected_revision_mismatch",
                "effector/stale-revision-refuses-before-journal-effect")
    tests.check(effector.submit(request("bad-space", space: "display:1/space:B")).reason == "active_space_mismatch",
                "effector/wrong-space-refuses-before-journal-effect")
    tests.check(effector.submit(request("bad-generation", generation: 7)).reason == "observer_generation_mismatch",
                "effector/stale-observer-generation-refuses")
    let burstPath = SelfTestFixtures.path("effector/resize_burst.json")
    let burst = FileManager.default.contents(atPath: burstPath).flatMap { try? JSONValue.parse($0) }
    let widths = (burst?.at(path: "requested_widths")?.arrayValue ?? []).compactMap(\.numberValue)
    guard widths.count == 4 else { tests.check(false, "effector/resize-burst-fixture-required"); return tests.finish("effector") }
    let first = effector.submit(request("first", width: widths[0]))
    tests.check(first.status == .accepted && port.waitForIssues(1) && port.journalFirst,
                "effector/durable-journal-before-first-effect")
    tests.check(effector.submit(request("first", width: widths[0])).requestID == first.requestID && port.snapshot().count == 1,
                "effector/same-epoch-idempotent-replay-no-second-effect")
    tests.check(effector.submit(request("first", width: widths[1])).reason == "request_id_conflict",
                "effector/replay-different-payload-refuses")
    // The flight minted revision 4; pending commands validate against current authority.
    _ = effector.submit(request("second", revision: 4, width: widths[1]))
    _ = effector.submit(request("third", revision: 4, width: widths[2]))
    _ = effector.submit(request("final", revision: 4, width: widths[3]))
    tests.check(effector.snapshot().at(path: "pending_count")?.intValue == 1
        && effector.snapshot().at(path: "coalesced_intents")?.intValue == burst?.at(path: "expected_coalesced")?.intValue
        && port.snapshot().first?.1 == Frame.from(burst?.at(path: "expected_first")) && port.snapshot().count == 1,
        "effector/one-in-flight-latest-pending-no-superseded-actuation")
    effector.keyUp(eventID: "key-up", receiptNanos: 120)
    port.acknowledge("first")
    tests.check(effector.snapshot().at(path: "in_flight")?.stringValue == "first",
                "effector/setter-ack-alone-does-not-land")
    mainClock.setTime(130)
    let observed = effector.observe(requestID: "first", windowID: "11", frame: Frame(x: 0, y: 0, w: 110, h: 80),
        generation: 8, timestampNanos: 130)
    tests.check(observed && port.waitForIssues(2), "effector/targeted-matching-evidence-drains-latest-immediately")
    let actualFinal = port.snapshot().last?.1
    tests.check(actualFinal == Frame.from(burst?.at(path: "expected_final"))
        && Int64(port.snapshot().count) == burst?.at(path: "expected_issues")?.intValue,
                "effector/resize-burst-issues-first-and-latest-target-after-key-up")
    mainClock.setTime(140)
    _ = effector.observe(requestID: "final", windowID: "11", frame: actualFinal!, generation: 8, timestampNanos: 140)
    port.acknowledge("final")
    let landed = outcomes.waitFor("final")
    tests.check(landed?.status == .accepted && landed?.firstMatchingObservationNanos == 140
        && landed?.json.at(path: "visible_evidence")?.boolValue == false,
        "effector/per-window-observation-is-honest-not-physical-visible-certification")

    let failureJournal = EffectorTestJournal(); failureJournal.fail = true
    let failurePort = EffectorTestPort(journal: failureJournal), failureOutcomes = EffectorOutcomes()
    let failureFaults = EffectorFaults()
    let failure = ResidentEffector(context: context, journal: failureJournal, port: failurePort,
        onPersistenceFault: { failureFaults.append($0) },
        onOutcome: { failureOutcomes.append($0) })
    _ = failure.submit(request("journal-fail"))
    tests.check(failureOutcomes.waitFor("journal-fail")?.reason == "journal_append_failed" && failurePort.snapshot().isEmpty
        && failureFaults.waitFor("journal_append_failed"),
                "effector/persistence-failure-causes-zero-actuation")
    let markerJournal = EffectorTestJournal(); markerJournal.failOnType = "effect_commit"
    let markerPort = EffectorTestPort(journal: markerJournal), markerOutcomes = EffectorOutcomes()
    let marker = ResidentEffector(context: context, journal: markerJournal, port: markerPort,
        onOutcome: { markerOutcomes.append($0) })
    _ = marker.submit(request("marker-fail"))
    let markerFailure = markerOutcomes.waitFor("marker-fail")
    tests.check(markerFailure?.status == .failed && markerFailure?.reason == "journal_commit_failed"
        && markerFailure?.desiredStateCommittedRevision == 4 && markerFailure?.effectIssuedNanos == nil && markerPort.snapshot().isEmpty,
                "effector/commit-marker-failure-prevents-every-AX-effect-and-reports-already-committed-model")
    let abortJournal = EffectorTestJournal(), abortPort = EffectorTestPort(journal: abortJournal), abortOutcomes = EffectorOutcomes()
    let abort = ResidentEffector(context: context, journal: abortJournal, port: abortPort,
        commitJournaledPlan: { _, _, _ in nil }, onOutcome: { abortOutcomes.append($0) })
    _ = abort.submit(request("commit-refused"))
    tests.check(abortOutcomes.waitFor("commit-refused")?.status == .refused && abortPort.snapshot().isEmpty
        && abortJournal.snapshot().last?.at(path: "type")?.stringValue == "effect_abort",
        "effector/authority-compare-refusal-durably-aborts-intention")
    let abortFailureJournal = EffectorTestJournal(); abortFailureJournal.failOnType = "effect_abort"
    let abortFailurePort = EffectorTestPort(journal: abortFailureJournal), abortFailureOutcomes = EffectorOutcomes()
    let abortFailureFaults = EffectorFaults()
    let abortFailure = ResidentEffector(context: context, journal: abortFailureJournal, port: abortFailurePort,
        commitJournaledPlan: { _, _, _ in nil }, onPersistenceFault: { abortFailureFaults.append($0) },
        onOutcome: { abortFailureOutcomes.append($0) })
    _ = abortFailure.submit(request("abort-fail"))
    tests.check(abortFailureOutcomes.waitFor("abort-fail")?.reason == "journal_abort_failed"
        && abortFailureFaults.waitFor("journal_abort_failed") && abortFailurePort.snapshot().isEmpty,
        "effector/refused-commit-with-failed-abort-signals-storage-fault-and-zero-AX")
    let blockedJournal = EffectorTestJournal(); blockedJournal.blocked = true
    let blockedPort = EffectorTestPort(journal: blockedJournal)
    let blocked = ResidentEffector(context: context, journal: blockedJournal, port: blockedPort, now: { 100 })
    _ = blocked.submit(request("blocked-first")); _ = blockedJournal.waitForEntered()
    for index in 1...100 {
        var nextContext = context; nextContext.observerGeneration = UInt64(index + 8)
        blocked.updateContext(nextContext, cause: "cancel", eventID: "cancel-\(index)", receiptNanos: 20)
        _ = blocked.submit(request("latest-\(index)", generation: UInt64(index + 8)))
    }
    tests.check(blocked.snapshot().at(path: "journal_worker_pending")?.intValue == 1 && blockedPort.snapshot().isEmpty,
        "effector/blocked-storage-cancel-restart-has-single-pending-worker-slot")
    blockedJournal.release()
    tests.check(blockedPort.waitForIssues(1) && blockedPort.snapshot().count == 1
        && blockedPort.snapshot().first?.0.requestID == "latest-100",
        "effector/blocked-storage-release-never-issues-obsolete-worker-backlog")
    let replanJournal = EffectorTestJournal(); replanJournal.blocked = true
    let replanPort = EffectorTestPort(journal: replanJournal)
    let replan = ResidentEffector(context: context, journal: replanJournal, port: replanPort, now: { 100 })
    _ = replan.submit(request("replan-own-completion")); _ = replanJournal.waitForEntered()
    var updatedContext = context; updatedContext.revision = 4
    replan.updateContext(updatedContext, cause: "action_result", eventID: "landed", receiptNanos: 110)
    replanJournal.release()
    tests.check(replanPort.waitForIssues(1) && replan.snapshot().at(path: "replans")?.intValue == 1
        && replanJournal.snapshot().contains(where: { $0.at(path: "type")?.stringValue == "effect_abort" }),
        "effector/own-completion-revision-race-replans-once-with-cause-and-preserved-intent")

    let cancelJournal = EffectorTestJournal(), cancelPort = EffectorTestPort(journal: cancelJournal)
    let cancelOutcomes = EffectorOutcomes(), cancelReference = EffectorReference()
    let cancelClock = EffectorProgressProbe()
    let cancel = ResidentEffector(context: context, journal: cancelJournal, port: cancelPort, now: { cancelClock.now() },
        onOutcome: { value in _ = cancelReference.value?.snapshot(); cancelOutcomes.append(value) })
    cancelReference.value = cancel
    _ = cancel.submit(request("obsolete", width: 110)); _ = cancelPort.waitForIssues(1)
    let partial = Frame(x: 0, y: 0, w: 105, h: 80)
    cancelClock.setTime(105)
    _ = cancel.observe(requestID: "obsolete", windowID: "11", frame: partial, generation: 8, timestampNanos: 105)
    _ = cancel.submit(request("pending-obsolete", revision: 4, width: 130))
    var invalid = context; invalid.observerGeneration = 9; invalid.trusted = false
    cancel.updateContext(invalid, cause: "trust-loss", eventID: "trust-event", receiptNanos: 110)
    cancelPort.acknowledge("obsolete")
    tests.check(cancel.snapshot().at(path: "in_flight") == .null
        && cancel.snapshot().at(path: "pending_count")?.intValue == 0
        && !cancel.observe(requestID: "obsolete", windowID: "11", frame: base, generation: 8, timestampNanos: 120),
        "effector/trust-invalidation-precedes-pending-and-rejects-late-result")
    let issuedCancellation = cancelOutcomes.waitFor("obsolete"), pendingCancellation = cancelOutcomes.waitFor("pending-obsolete")
    tests.check(issuedCancellation?.status == .failed && issuedCancellation?.effectIssuedNanos == 100
        && issuedCancellation?.desiredStateCommittedRevision == 4 && issuedCancellation?.requestedFrame?.w == 110
        && issuedCancellation?.landedFrame == partial && issuedCancellation?.landedFrames == ["11": partial]
        && issuedCancellation?.verifiedNanos == nil && cancelOutcomes.snapshot().filter { $0.requestID == "obsolete" }.count == 1,
        "effector/issued-cancellation-fails-once-preserving-partial-landing-and-requested-frame")
    tests.check(pendingCancellation?.status == .refused && pendingCancellation?.effectIssuedNanos == nil
        && pendingCancellation?.desiredStateCommittedRevision == nil && pendingCancellation?.requestedFrame?.w == 130
        && pendingCancellation?.landedFrames.isEmpty == true,
        "effector/untouched-pending-cancellation-refuses-with-full-requested-intent")

    let committedJournal = EffectorTestJournal(); committedJournal.blocked = true; committedJournal.blockedOnType = "effect_commit"
    let committedPort = EffectorTestPort(journal: committedJournal), committedOutcomes = EffectorOutcomes()
    let committed = ResidentEffector(context: context, journal: committedJournal, port: committedPort,
        now: { 100 }, onOutcome: { committedOutcomes.append($0) })
    _ = committed.submit(request("committed-cancel", width: 110)); let commitEntered = committedJournal.waitForType("effect_commit")
    committed.updateContext(invalid, cause: "trust-loss", eventID: "commit-cancel", receiptNanos: 110)
    let committedCancellation = committedOutcomes.waitFor("committed-cancel")
    tests.check(commitEntered && committedCancellation?.status == .failed
        && committedCancellation?.desiredStateCommittedRevision == 4 && committedCancellation?.effectIssuedNanos == nil
        && committedCancellation?.requestedFrame?.w == 110 && committedCancellation?.landedFrames.isEmpty == true
        && committedPort.snapshot().isEmpty,
        "effector/committed-before-marker-cancellation-fails-without-claiming-unchanged-state")
    committedJournal.release()

    for blockedType in ["effect_intent", "effect_commit"] {
        let stoppedJournal = EffectorTestJournal(); stoppedJournal.blocked = true; stoppedJournal.blockedOnType = blockedType
        let stoppedPort = EffectorTestPort(journal: stoppedJournal), stoppedOutcomes = EffectorOutcomes()
        let stopped = ResidentEffector(context: context, journal: stoppedJournal, port: stoppedPort,
            now: { 100 }, onOutcome: { stoppedOutcomes.append($0) })
        var stoppedRequest = request("post-journal-refusal"); stoppedRequest.windowGenerations = ["11": 1]
        _ = stopped.submit(stoppedRequest); let entered = stoppedJournal.waitForType(blockedType)
        var unknownFocus = context; unknownFocus.observerGeneration = 9; unknownFocus.activeSpaceKey = nil
        if blockedType == "effect_commit" { unknownFocus.revision = 4 }
        stopped.updateContext(unknownFocus, cause: "app_activated", eventID: "unknown-global-focus",
            receiptNanos: 110, preservingFrameRequests: [stoppedRequest.requestID])
        stoppedJournal.release()
        let result = stoppedOutcomes.waitFor(stoppedRequest.requestID)
        let committed = blockedType == "effect_commit"
        tests.check(entered && result?.status == (committed ? .failed : .refused)
            && result?.reason == "active_space_unknown" && result?.desiredStateCommittedRevision == (committed ? 4 : nil)
            && result?.effectIssuedNanos == nil && stoppedPort.snapshot().isEmpty
            && stopped.snapshot().at(path: "in_flight") == .null && stoppedOutcomes.snapshot().count == 1,
            "effector/still-active-refusal-after-\(blockedType)-always-completes-with-honest-commit-state")
    }

    let advancedJournal = EffectorTestJournal(); advancedJournal.blocked = true; advancedJournal.blockedOnType = "effect_commit"
    let advancedPort = EffectorTestPort(journal: advancedJournal), advancedOutcomes = EffectorOutcomes()
    let advancedClock = EffectorProgressProbe()
    let advanced = ResidentEffector(context: context, journal: advancedJournal, port: advancedPort,
        now: { advancedClock.now() }, onOutcome: { advancedOutcomes.append($0) })
    _ = advanced.submit(request("advanced-revision")); let advancedEntered = advancedJournal.waitForType("effect_commit")
    var newer = context; newer.revision = 6
    advanced.updateContext(newer, cause: "action_result", eventID: "newer-observation", receiptNanos: 110)
    advancedJournal.release(); let advancedIssued = advancedPort.waitForIssues(1)
    advancedPort.acknowledge("advanced-revision")
    advancedClock.setTime(120)
    _ = advanced.observe(requestID: "advanced-revision", windowID: "11", frame: base, generation: 8, timestampNanos: 120)
    tests.check(advancedEntered && advancedIssued && advancedOutcomes.waitFor("advanced-revision")?.revision == 6,
        "effector/commit-marker-return-cannot-rewind-newer-authoritative-revision")

    for didCommit in [false, true] {
        let callbackJournal = EffectorTestJournal(), callbackPort = EffectorTestPort(journal: callbackJournal)
        let callbackOutcomes = EffectorOutcomes(), callbackReference = EffectorReference()
        let callback = ResidentEffector(context: context, journal: callbackJournal, port: callbackPort,
            now: { 100 }, commitJournaledPlan: { _, _, revision in
                callbackReference.value?.updateContext(context, cause: "cancel",
                    eventID: "callback-cancel", receiptNanos: 110)
                return didCommit ? revision + 1 : nil
            }, onOutcome: { value in _ = callbackReference.value?.snapshot(); callbackOutcomes.append(value) })
        callbackReference.value = callback
        _ = callback.submit(request("callback-cancel", width: 110))
        let result = callbackOutcomes.waitFor("callback-cancel")
        tests.check(result?.status == (didCommit ? .failed : .refused)
            && result?.desiredStateCommittedRevision == (didCommit ? 4 : nil)
            && result?.effectIssuedNanos == nil && result?.requestedFrame?.w == 110 && callbackPort.snapshot().isEmpty
            && callbackOutcomes.snapshot().count == 1,
            "effector/cancellation-inside-commit-callback-\(didCommit ? "committed" : "untouched")-resolves-once-without-reentrancy-deadlock")
    }
    let lateFaultJournal = EffectorTestJournal(); lateFaultJournal.failOnType = "effect_commit"
    let lateFaultPort = EffectorTestPort(journal: lateFaultJournal), lateFaultOutcomes = EffectorOutcomes()
    let lateFaults = EffectorFaults(), lateFaultReference = EffectorReference()
    let lateFault = ResidentEffector(context: context, journal: lateFaultJournal, port: lateFaultPort,
        now: { 100 }, commitJournaledPlan: { _, _, revision in
            lateFaultReference.value?.updateContext(context, cause: "cancel",
                eventID: "late-fault-cancel", receiptNanos: 110)
            return revision + 1
        }, onPersistenceFault: { reason in
            _ = lateFaultReference.value?.snapshot(); lateFaults.append(reason)
        }, onOutcome: { lateFaultOutcomes.append($0) })
    lateFaultReference.value = lateFault
    _ = lateFault.submit(request("late-fault"))
    let lateFaultCancellation = lateFaultOutcomes.waitFor("late-fault")
    tests.check(lateFaultCancellation?.status == .failed && lateFaultCancellation?.reason == "invalidated_cancel"
        && lateFaultCancellation?.desiredStateCommittedRevision == 4 && lateFaults.waitFor("journal_commit_failed")
        && lateFaultOutcomes.snapshot().count == 1 && lateFaults.snapshot() == ["journal_commit_failed"]
        && lateFaultPort.snapshot().isEmpty,
        "effector/canceled-committed-request-still-signals-late-journal-fault-once-without-second-terminal-or-lock-reentrancy")

    var scheduler = CommandScheduling(generation: 1, maximumOrderedPending: 2, maximumCauseCount: 2)
    let nav = CommandScheduling.Intent(requestID: "nav", lane: "focus", generation: 1, receiptNanos: 1, desiredFrame: nil, ordered: true)
    let commit = CommandScheduling.Intent(requestID: "commit", lane: "move", generation: 1, receiptNanos: 2, desiredFrame: base, ordered: true)
    _ = scheduler.admit(nav); _ = scheduler.admit(commit)
    tests.check(scheduler.admit(nav).reason == "command_queue_full" && scheduler.beginNext()?.requestID == "nav",
                "effector/noncommutative-order-and-overflow-typed-refusal")
    _ = scheduler.finish(requestID: "nav", generation: 1)
    tests.check(scheduler.beginNext()?.requestID == "commit", "effector/commit-cannot-overtake-navigation")
    for i in 1...3 { scheduler.recordCause(cause: "external-event", eventID: String(i), receiptNanos: UInt64(i)) }
    tests.check(scheduler.causes.count == 2 && scheduler.causes.first?.eventID == "2", "effector/generation-cause-ring-bounded")

    let batchJournal = EffectorTestJournal(), batchPort = EffectorTestPort(journal: batchJournal)
    let batchOutcomes = EffectorOutcomes()
    let batchClock = EffectorProgressProbe()
    let batch = ResidentEffector(context: context, journal: batchJournal, port: batchPort,
        now: { batchClock.now() }, onOutcome: { batchOutcomes.append($0) })
    var batchRequest = request("batch")
    batchRequest.proposedState = .object(["arrangement": .object(["checkpoint": .int(1)])])
    batchRequest.frameTargets = ["11": base, "12": Frame(x: 100, y: 0, w: 100, h: 80)]
    _ = batch.submit(batchRequest); _ = batchPort.waitForIssues(1); batchPort.acknowledge("batch")
    batchClock.setTime(110)
    _ = batch.observe(requestID: "batch", windowID: "11", frame: base, generation: 8, timestampNanos: 110)
    tests.check(batch.snapshot().at(path: "in_flight")?.stringValue == "batch",
        "effector/batch-first-window-evidence-does-not-complete-whole-plan")
    batchClock.setTime(120)
    _ = batch.observe(requestID: "batch", windowID: "12", frame: batchRequest.frameTargets["12"]!, generation: 8, timestampNanos: 120)
    tests.check(batchOutcomes.waitFor("batch")?.landedFrames.count == 2
        && batchJournal.snapshot().first?.at(path: "state.arrangement.checkpoint")?.intValue == 1,
        "effector/batch-desired-state-journal-and-all-window-landing")
    let partialJournal = EffectorTestJournal(), partialPort = EffectorTestPort(journal: partialJournal)
    let partialOutcomes = EffectorOutcomes()
    let partialClock = EffectorProgressProbe()
    let partialBatch = ResidentEffector(context: context, journal: partialJournal, port: partialPort,
        now: { partialClock.now() }, onOutcome: { partialOutcomes.append($0) })
    var partialRequest = request("partial-batch"); partialRequest.frameTargets = batchRequest.frameTargets
    _ = partialBatch.submit(partialRequest); _ = partialPort.waitForIssues(1); partialPort.acknowledge("partial-batch")
    partialClock.setTime(110)
    _ = partialBatch.observe(requestID: "partial-batch", windowID: "11", frame: base, generation: 8, timestampNanos: 110)
    partialBatch.updateContext(invalid, cause: "trust-loss", eventID: "partial-cancel", receiptNanos: 115)
    let partialResult = partialOutcomes.waitFor("partial-batch")
    tests.check(partialResult?.status == .failed && partialResult?.requestedFrames.count == 2
        && partialResult?.landedFrames == ["11": base] && partialResult?.verifiedNanos == nil
        && partialResult?.json.at(path: "visible_evidence")?.boolValue == false,
        "effector/partial-batch-cancellation-retains-only-observed-window-without-certifying-whole-plan")
    let focusJournal = EffectorTestJournal(), focusPort = EffectorTestPort(journal: focusJournal)
    let focusOutcomes = EffectorOutcomes()
    let focusClock = EffectorProgressProbe()
    let focusEffector = ResidentEffector(context: context, journal: focusJournal, port: focusPort,
        now: { focusClock.now() }, onOutcome: { focusOutcomes.append($0) })
    var focusRequest = request("focus"); focusRequest.effectKind = .focus; focusRequest.ordered = true
    _ = focusEffector.submit(focusRequest); _ = focusPort.waitForIssues(1); focusPort.acknowledge("focus")
    focusClock.setTime(110)
    tests.check(focusEffector.observeFocus(requestID: "focus", windowID: "11", generation: 8, timestampNanos: 110)
        && focusOutcomes.waitFor("focus")?.focusConfirmed == true,
        "effector/navigation-confirms-targeted-focus-not-raise-ack")
    let unissuedJournal = EffectorTestJournal(); unissuedJournal.blocked = true
    let unissuedPort = EffectorTestPort(journal: unissuedJournal), unissuedOutcomes = EffectorOutcomes()
    let unissued = ResidentEffector(context: context, journal: unissuedJournal, port: unissuedPort,
        now: { 100 }, onOutcome: { unissuedOutcomes.append($0) })
    var unissuedRequest = request("unissued-focus"); unissuedRequest.effectKind = .focus; unissuedRequest.windowGenerations = ["11": 1]
    _ = unissued.submit(unissuedRequest); let unissuedEntered = unissuedJournal.waitForEntered()
    var freshFocus = context; freshFocus.observerGeneration = 9
    let fabricated = unissued.confirmFocusedGoal(requestID: unissuedRequest.requestID, windowID: "11", windowGeneration: 1,
        observedContext: freshFocus, timestampNanos: 110)
    unissued.updateContext(freshFocus, cause: "app_activated", eventID: "preissue-focus", receiptNanos: 110,
        preservingFocusRequests: [unissuedRequest.requestID])
    let unissuedResult = unissuedOutcomes.waitFor(unissuedRequest.requestID)
    unissuedJournal.release()
    tests.check(unissuedEntered && !fabricated && unissued.issuedTimestamp(for: unissuedRequest.requestID) == nil
        && unissuedResult?.status == .refused && unissuedResult?.focusConfirmed == false
        && unissuedResult?.verifiedNanos == nil && unissuedPort.snapshot().isEmpty,
        "effector/pre-issue-focus-evidence-cannot-preserve-or-confirm-journal-only-navigation")

    runResidentPlannerScenarios(tests: &tests)
    runEnhancedInterfaceScenarios(tests: &tests)
    runEffectorProgressScenarios(tests: &tests, context: context, base: base)
    runEffectorVerificationOrderingScenarios(tests: &tests, context: context, base: base)
    runMinimumLearningScenarios(test: &tests)
    runPrivateFilesScenarios(test: &tests)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ResidentEffectorFileJournal(path: directory.appendingPathComponent("journal.jsonl").path)
        try file.append(.object(["type": .string("effect_intent"), "request_id": .string("persisted"),
            "revision": .int(900), "frame": base.json, "state": .object(["committed": .bool(true)])]))
        let recovered = try file.recover()
        tests.check(recovered.highWaterRevision == 900 && recovered.records.count == 1,
                    "effector/journal-recovery-monotonic-high-water")
        try file.append(.object(["type": .string("effect_commit"), "request_id": .string("persisted"),
            "revision": .int(900), "state": .object(["committed": .bool(true)])]))
        try file.append(.object(["type": .string("effect_intent"), "request_id": .string("abandoned"),
            "revision": .int(901), "frame": base.json, "state": .object(["stale": .bool(true)])]))
        let checkpoint = try file.recoverCheckpoint()
        tests.check(checkpoint.highWaterRevision == 901 && checkpoint.state?.at(path: "committed")?.boolValue == true
            && checkpoint.state?.at(path: "stale") == nil,
            "effector/recovery-reserves-highwater-but-never-promotes-abandoned-intent")
        let oldState: JSONValue = .object(["checkpoint": .string("old-effect")])
        let modelState: JSONValue = .object(["checkpoint": .string("new-model-only")])
        try file.append(.object(["type": .string("effect_intent"), "request_id": .string("late-marker"),
            "revision": .int(902), "frame": base.json, "state": oldState]))
        try file.append(.object(["type": .string("model_state_intent"), "request_id": .string("model-only"),
            "revision": .int(904), "state": modelState]))
        try file.append(.object(["type": .string("model_state_commit"), "request_id": .string("model-only"),
            "revision": .int(904), "state": modelState]))
        try file.append(.object(["type": .string("effect_commit"), "request_id": .string("late-marker"),
            "revision": .int(902), "state": oldState]))
        let orderedCheckpoint = try file.recoverCheckpoint()
        tests.check(orderedCheckpoint.highWaterRevision == 904 && orderedCheckpoint.state == modelState,
            "effector/state-only-checkpoint-authority-beats-late-older-effect-marker-append-order")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        do { _ = try file.recover(); tests.check(false, "effector/corrupt-journal-refuses-no-fabricated-empty-state") }
        catch { tests.check(true, "effector/corrupt-journal-refuses-no-fabricated-empty-state") }
    } catch { tests.check(false, "effector/durable-journal-fixture: \(error)") }
    return tests.finish("effector")
}

private func runEffectorVerificationOrderingScenarios(tests: inout SelfTest, context: ResidentEffectContext, base: Frame) {
    let path = SelfTestFixtures.path("effector/verification_ordering.json")
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data) else {
        tests.check(false, "effector/verification-order-fixture-load"); return
    }
    for scenario in ["normal", "continuous-frame", "ack-last"] {
        let journal = EffectorTestJournal(), port = EffectorTestPort(journal: journal)
        let clock = EffectorProgressProbe(), outcomes = EffectorOutcomes()
        let effector = ResidentEffector(context: context, journal: journal, port: port,
            now: { clock.now() }, onOutcome: { outcomes.append($0) })
        var request = ResidentEffectRequest(requestID: "ordering-" + scenario, actionID: "resize.adjust.east", windowID: "11",
            expectedRevision: context.revision, observerGeneration: context.observerGeneration,
            activeSpaceKey: context.activeSpaceKey!, topologyRevision: context.topologyRevision,
            receiptNanos: fixture.requiredUInt64("receipt"), frame: base)
        request.windowGenerations = ["11": 1, "12": 2]
        request.frameTargets = ["11": base, "12": Frame(x: 100, y: 0, w: 100, h: 80)]
        clock.setTime(fixture.requiredUInt64("issued")); _ = effector.submit(request); _ = port.waitForIssues(1)
        if scenario != "ack-last" { port.acknowledge(request.requestID) }
        if scenario == "normal" {
            tests.check(!effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8,
                windowGeneration: 1, timestampNanos: fixture.requiredUInt64("future_source")) && outcomes.snapshot().isEmpty,
                "effector/verification-future-frame-source-cannot-match-or-complete")
        }
        clock.setTime(fixture.requiredUInt64("first_delivery"))
        _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8,
            windowGeneration: 1, timestampNanos: fixture.requiredUInt64("first_source"))
        var generation: UInt64 = 8
        if scenario == "continuous-frame" {
            var replacement = context; replacement.revision = 4; replacement.observerGeneration = 9
            effector.updateContext(replacement, cause: "app_activated", eventID: "continuous-order",
                receiptNanos: fixture.requiredUInt64("first_delivery"), preservingFrameRequests: [request.requestID])
            generation = 9
        }
        clock.setTime(fixture.requiredUInt64("verification"))
        let matched = effector.observe(requestID: request.requestID, windowID: "12", frame: request.frameTargets["12"]!,
            generation: generation, windowGeneration: 2, timestampNanos: fixture.requiredUInt64("second_source"))
        let verification = scenario == "ack-last" ? fixture.requiredUInt64("ack_verification") : fixture.requiredUInt64("verification")
        if scenario == "ack-last" { clock.setTime(verification); port.acknowledge(request.requestID) }
        let result = outcomes.waitFor(request.requestID)
        tests.check(matched && result?.status == .accepted && result?.verifiedNanos == verification
            && (result?.verifiedNanos ?? 0) >= fixture.requiredUInt64("first_source") && (result?.verifiedNanos ?? 0) >= fixture.requiredUInt64("second_source")
            && (result?.verifiedNanos ?? 0) >= fixture.requiredUInt64("issued") && (result?.verifiedNanos ?? 0) >= fixture.requiredUInt64("receipt"),
            "effector/verification-actual-completion-orders-out-of-order-source-" + scenario)
        tests.check(result?.firstMatchingObservationNanos == fixture.requiredUInt64("first_source")
            && result?.receiptNanos == fixture.requiredUInt64("receipt") && result?.effectIssuedNanos == fixture.requiredUInt64("issued")
            && result?.requestedGeneration == 8 && result?.observedGeneration == generation
            && result?.landedFrames == request.frameTargets && result?.json.at(path: "visible_evidence")?.boolValue == false,
            "effector/verification-preserves-source-and-request-evidence-" + scenario)
    }
    let journal = EffectorTestJournal(), port = EffectorTestPort(journal: journal)
    let clock = EffectorProgressProbe(), outcomes = EffectorOutcomes()
    let effector = ResidentEffector(context: context, journal: journal, port: port,
        now: { clock.now() }, onOutcome: { outcomes.append($0) })
    var focus = ResidentEffectRequest(requestID: "ordering-focus", actionID: "nav.focus.east", windowID: "11",
        expectedRevision: context.revision, observerGeneration: context.observerGeneration,
        activeSpaceKey: context.activeSpaceKey!, topologyRevision: context.topologyRevision,
        receiptNanos: fixture.requiredUInt64("receipt"), frame: base)
    focus.effectKind = .focus; focus.windowGenerations = ["11": 1]
    _ = effector.submit(focus); _ = port.waitForIssues(1); port.acknowledge(focus.requestID)
    clock.setTime(fixture.requiredUInt64("verification"))
    var observed = context; observed.observerGeneration = 9
    let ordinaryFuture = effector.observeFocus(requestID: focus.requestID, windowID: "11", generation: 8,
        windowGeneration: 1, timestampNanos: fixture.requiredUInt64("future_source"))
    let ownFuture = effector.confirmFocusedGoal(requestID: focus.requestID, windowID: "11", windowGeneration: 1,
        observedContext: observed, timestampNanos: fixture.requiredUInt64("future_source"))
    tests.check(!ordinaryFuture && !ownFuture && outcomes.snapshot().isEmpty,
        "effector/verification-future-focus-source-cannot-confirm-or-retire-flight")
    let ownMatch = effector.confirmFocusedGoal(requestID: focus.requestID, windowID: "11", windowGeneration: 1,
        observedContext: observed, timestampNanos: fixture.requiredUInt64("second_source"))
    let result = outcomes.waitFor(focus.requestID)
    tests.check(ownMatch && result?.verifiedNanos == fixture.requiredUInt64("verification")
        && result?.firstMatchingObservationNanos == fixture.requiredUInt64("second_source") && result?.requestedGeneration == 8
        && result?.observedGeneration == 9 && result?.json.at(path: "visible_evidence")?.boolValue == false,
        "effector/verification-own-focus-completion-preserves-earlier-read-stamp-and-generations")
}

private func runEffectorProgressScenarios(tests: inout SelfTest, context: ResidentEffectContext, base: Frame) {
    let journal = EffectorTestJournal(), port = EffectorTestPort(journal: journal)
    let probe = EffectorProgressProbe(), outcomes = EffectorOutcomes(), reference = EffectorReference()
    let effector = ResidentEffector(context: context, journal: journal, port: port,
        now: { probe.now() }, onProgress: { _, stamp in _ = reference.value?.snapshot(); probe.record(stamp) },
        onOutcome: { outcomes.append($0) })
    reference.value = effector
    var request = ResidentEffectRequest(requestID: "progress", actionID: "resize.adjust.east", windowID: "11",
        expectedRevision: context.revision, observerGeneration: context.observerGeneration,
        activeSpaceKey: context.activeSpaceKey!, topologyRevision: context.topologyRevision, receiptNanos: 10, frame: base)
    request.windowGenerations = ["11": 1, "12": 2]
    request.frameTargets = ["11": base, "12": Frame(x: 100, y: 0, w: 100, h: 80)]
    _ = effector.submit(request); _ = port.waitForIssues(1)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 99)
    _ = effector.observe(requestID: request.requestID, windowID: "999", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 110)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 7, windowGeneration: 1, timestampNanos: 110)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 2, timestampNanos: 110)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: Frame(x: 0, y: 0, w: 90, h: 80), generation: 8, windowGeneration: 1, timestampNanos: 110)
    tests.check(probe.snapshot().isEmpty, "effector/progress-rejects-preissue-wrong-target-generation-lifetime-and-nonmatching-frame")
    probe.setTime(110)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 110)
    probe.setTime(140)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 140)
    probe.setTime(150)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: Frame(x: 0, y: 0, w: 90, h: 80), generation: 8, windowGeneration: 1, timestampNanos: 150)
    probe.setTime(160)
    _ = effector.observe(requestID: request.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 160)
    probe.setTime(180); port.acknowledge(request.requestID, repeatCount: 2)
    tests.check(probe.snapshot() == [110, 180] && effector.snapshot().at(path: "in_flight")?.stringValue == request.requestID,
        "effector/progress-first-ACK-and-first-target-only-no-duplicate-or-mismatch-rematch-heartbeat")
    probe.setTime(220)
    _ = effector.observe(requestID: request.requestID, windowID: "12", frame: request.frameTargets["12"]!, generation: 8, windowGeneration: 2, timestampNanos: 220)
    _ = effector.observe(requestID: request.requestID, windowID: "12", frame: request.frameTargets["12"]!, generation: 8, windowGeneration: 2, timestampNanos: 260)
    tests.check(probe.snapshot() == [110, 180, 220] && outcomes.waitFor(request.requestID)?.status == .accepted,
        "effector/distinct-last-target-progress-precedes-final-completion-and-late-replays-do-not-renew")

    let stalledJournal = EffectorTestJournal(), stalledPort = EffectorTestPort(journal: stalledJournal)
    let stalledProbe = EffectorProgressProbe(), stalledOutcomes = EffectorOutcomes()
    let stalled = ResidentEffector(context: context, journal: stalledJournal, port: stalledPort,
        now: { stalledProbe.now() }, onProgress: { _, stamp in stalledProbe.record(stamp) }, onOutcome: { stalledOutcomes.append($0) })
    let stalledRequest = ResidentEffectRequest(requestID: "stalled-participant", actionID: request.actionID,
        windowID: request.windowID, expectedRevision: request.expectedRevision, observerGeneration: request.observerGeneration,
        activeSpaceKey: request.activeSpaceKey, topologyRevision: request.topologyRevision, receiptNanos: request.receiptNanos,
        frame: request.frame, frameTargets: request.frameTargets, windowGenerations: request.windowGenerations)
    _ = stalled.submit(stalledRequest); _ = stalledPort.waitForIssues(1)
    stalledProbe.setTime(110); stalledPort.acknowledge(stalledRequest.requestID)
    stalledProbe.setTime(120)
    _ = stalled.observe(requestID: stalledRequest.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 120)
    _ = stalled.observe(requestID: stalledRequest.requestID, windowID: "11", frame: base, generation: 8, windowGeneration: 1, timestampNanos: 999_999_900)
    stalled.expireEvidence(at: 1_000_000_100)
    tests.check(stalledProbe.snapshot() == [110, 120] && stalledOutcomes.waitFor(stalledRequest.requestID)?.reason == "targeted_evidence_timeout",
        "effector/one-stalled-participant-and-repeated-unchanged-samples-cannot-extend-whole-effect-evidence-deadline")
}

/// The AX port suspends AXEnhancedUserInterface only when it is on, and always turns it back on.
private func runEnhancedInterfaceScenarios(tests: inout SelfTest) {
    final class Calls: @unchecked Sendable { var writes: [Bool] = [] }
    func probe(_ value: Bool?, accepts: Bool = true) -> (ResidentEnhancedInterface, Calls) {
        let calls = Calls()
        return (ResidentEnhancedInterface(read: { _ in value }, write: { _, enabled in calls.writes.append(enabled); return accepts }), calls)
    }
    let (on, onCalls) = probe(true)
    let suspended = on.suspend(42)
    on.restore(42)
    tests.check(suspended && onCalls.writes == [false, true], "effector/enhanced-interface-is-suspended-for-writes-and-restored")
    let (off, offCalls) = probe(false), (unreadable, unreadableCalls) = probe(nil)
    tests.check(!off.suspend(42) && offCalls.writes.isEmpty && !unreadable.suspend(42) && unreadableCalls.writes.isEmpty,
        "effector/enhanced-interface-off-or-unreadable-is-never-written")
    let (refused, refusedCalls) = probe(true, accepts: false)
    tests.check(!refused.suspend(42) && refusedCalls.writes == [false], "effector/refused-suspension-requires-no-restore")
}

private func runResidentPlannerScenarios(tests: inout SelfTest) {
    runResidentPlannerCompletionScenarios(tests: &tests)
    let topology: JSONValue = .object(["displays": .array([.object(["id": .int(1),
        "frame": Frame(x: 0, y: 0, w: 1200, h: 800).json])]), "gap": .int(8)])
    let windows: [JSONValue] = (1...6).map { id in .object(["window_id": .int(Int64(id)),
        "role": .string("AXWindow"), "subrole": .string("AXStandardWindow"), "resizable": .bool(true),
        "frame": Frame(x: 10, y: 10, w: 100, h: 100).json]) }
    let world = plannerSpaceWorld(.object(["complete": .bool(true), "trusted": .bool(true), "space_enabled": .bool(true),
        "active_space_key": .string("display:1/space:A"), "observer_generation": .int(8),
        "topology_revision": .int(4), "topology": topology, "windows": .array(windows), "focused_window_id": .int(1)]))
    let seed = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world)
    tests.check(seed.status == .accepted && seed.targets.objectValue?.count == 6,
        "effector/planner-largest-first-six-window-seed-conserves-managed-set")
    // Live shape 2026-10-16: the iOS Simulator's device window refused every tile shape.
    var simulatorWindow = windows[5].objectValue ?? [:]; simulatorWindow["app"] = .string("Device Hub")
    var simulatorWindows = windows; simulatorWindows[5] = .object(simulatorWindow)
    var simulatorRaw = world.objectValue ?? [:]; simulatorRaw["windows"] = .array(simulatorWindows)
    let simulatorWorld = plannerSpaceWorld(.object(simulatorRaw))
    let untiled = ResidentPlanner.plan(actionID: "world.reconcile",
        state: .object(["fixed_aspect_apps": .array([.string("Device Hub")])]), world: simulatorWorld)
    tests.check(untiled.status == .accepted && untiled.targets.objectValue?.count == 5 && untiled.targets.at(path: "6") == nil
        && !Arrangement.memberWindows(untiled.state.at(path: "arrangement") ?? .object([:])).contains { $0.at(path: "window_id")?.intValue == 6 },
        "effector/planner-leaves-learned-fixed-aspect-app-windows-untiled")
    // The reconcile proof re-admits partitions with the same filter; a private copy
    // without the fixed-aspect set parked a restart "space_partitions_require_reconcile".
    let simulatorTopology = simulatorWorld.at(path: "topology") ?? .object([:])
    let proofObserved = ResidentPlanner.eligibleWindows(simulatorWorld.at(path: "windows")?.arrayValue ?? [], state: untiled.state)
    let unfiltered = (simulatorWorld.at(path: "windows")?.arrayValue ?? []).filter(Autotile.tileable)
    var proofAdmits = false, unfilteredRefuses = false
    if let proofObserved, case .success = ResidentSpacePartitions.prepare(state: untiled.state, world: simulatorWorld,
        topology: simulatorTopology, observed: proofObserved, reconcile: false) { proofAdmits = true }
    if case .failure = ResidentSpacePartitions.prepare(state: untiled.state, world: simulatorWorld,
        topology: simulatorTopology, observed: unfiltered, reconcile: false) { unfilteredRefuses = true }
    tests.check(proofObserved?.count == 5 && proofAdmits && unfilteredRefuses,
        "effector/reconcile-proof-admits-the-untiled-layout-through-the-shared-eligibility-filter")
    tests.check(ResidentPlanner.plan(actionID: "world.reconcile", state: .object(["fixed_aspect_apps": .array([.int(1)])]),
            world: simulatorWorld).reason == "fixed_aspect_store_invalid"
        && !ResidentPlanner.validFixedAspectStore(.object([:])) && !ResidentPlanner.validFixedAspectStore(.array([.string("")]))
        && ResidentPlanner.validFixedAspectStore(.array([])),
        "effector/malformed-fixed-aspect-store-refuses-instead-of-tiling-everything")
    guard seed.status == .accepted else { return }
    let nav = ResidentPlanner.plan(actionID: "nav.focus.east", state: seed.state, world: world)
    tests.check(nav.status == .accepted && nav.focusTarget != nil && nav.focusTarget != 1,
        "effector/planner-native-spatial-navigation")
    let resizeStart = ResidentPlanner.plan(actionID: "resize.start", state: seed.state, world: world)
    let resize = ResidentPlanner.plan(actionID: "resize.adjust.east", state: resizeStart.state, world: world)
    let originalFrame = Frame.from(seed.targets.at(path: "1.frame"))
    let resizedFrame = Frame.from(resize.targets.at(path: "1.frame"))
    tests.check(resize.status == .accepted && originalFrame != nil && resizedFrame != nil
        && abs(resizedFrame!.w - originalFrame!.w - 40) <= 1,
        "effector/planner-resize-uses-ratified-forty-point-divider-step")
    let start = ResidentPlanner.plan(actionID: "move.start", state: seed.state, world: world)
    let cursor = ResidentPlanner.plan(actionID: "move.cursor.east", state: start.state, world: world)
    let swap = ResidentPlanner.plan(actionID: "move.execute.swap", state: cursor.state, world: world)
    tests.check(swap.status == .accepted && swap.state.at(path: "interaction") == nil
        && swap.targets.objectValue?.count == 6 && swap.targets.at(path: "1.frame") != seed.targets.at(path: "1.frame"),
        "effector/planner-move-cursor-swap-conserves-then-exits")
    let stage = ResidentPlanner.plan(actionID: "move.drop", state: cursor.state, world: world)
    let cancel = ResidentPlanner.plan(actionID: "move.cancel", state: stage.state, world: world)
    tests.check(stage.status == .accepted && stage.targets.objectValue?.isEmpty == true
        && stage.state.at(path: "arrangement") == cursor.state.at(path: "arrangement")
        && Arrangement.arrangementTargetsRec(bridge: stage.state.at(path: "arrangement")!, topo: topology)
            == Arrangement.arrangementTargetsRec(bridge: seed.state.at(path: "arrangement")!, topo: topology)
        && cancel.state.at(path: "interaction.staged_edge") == .null,
        "effector/planner-staging-never-authors-layout-cancel-clears-only-stage")
    let inserted = ResidentPlanner.plan(actionID: "move.execute.auto", state: stage.state, world: world)
    tests.check(inserted.status == .accepted && inserted.targets.objectValue?.count == 6
        && inserted.state.at(path: "interaction") == nil, "effector/planner-single-edge-insert-conserves-and-exits")
    var stressWorld = world.objectValue!
    stressWorld["windows"] = .array((1...20).map { id in .object(["window_id": .int(Int64(id)),
        "role": .string("AXWindow"), "subrole": .string("AXStandardWindow"), "resizable": .bool(true),
        "frame": Frame(x: 10, y: 10, w: 100, h: 100).json]) })
    let stress = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: plannerSpaceWorld(.object(stressWorld)))
    tests.check(stress.status == .accepted && stress.targets.objectValue?.count == 20,
        "effector/planner-twenty-window-stress-conserves-every-managed-identity")
    var closedWorld = world.objectValue!
    closedWorld["windows"] = .array(Array(world.at(path: "windows")!.arrayValue!.dropLast()))
    let reclaimed = ResidentPlanner.plan(actionID: "window.destroyed", state: seed.state, world: .object(closedWorld))
    tests.check(reclaimed.status == .accepted && reclaimed.targets.objectValue?.count == 5
        && reclaimed.targets.at(path: "6") == nil, "effector/planner-close-reclaims-with-exact-survivor-conservation")
    closedWorld["complete"] = .bool(false)
    let incomplete = ResidentPlanner.plan(actionID: "world.reconcile", state: seed.state, world: .object(closedWorld))
    tests.check(incomplete.status == .refused && incomplete.state == seed.state,
        "effector/planner-incomplete-world-never-interpreted-as-empty")
}
