import Foundation
import LeylineModel

private final class ResidentFaultTestRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [ResidentInputFaultRelease] = []
    func record(_ event: ResidentInputFaultRelease) {
        condition.lock(); events.append(event); condition.broadcast(); condition.unlock()
    }
    func waitForCount(_ count: Int) -> [ResidentInputFaultRelease] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while events.count < count {
            if !condition.wait(until: deadline) { break }
        }
        return events
    }
}

@MainActor
private final class ResidentFaultTestSurface: ResidentInputFaultNoticeSurface {
    var messages: [String] = []
    var hides = 0
    func show(message: String) { messages.append(message) }
    func hide() { hides += 1 }
}

/// Drives the actual routing release/watchdog handler and the same presenter
/// used by controls. It installs no tap, AppKit window, timer or live actor.
func runResidentInputFaultFeedbackChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: SelfTestFixtures.path("resident/input-fault-feedback.json", root: home)),
          let fixture = try? JSONValue.parse(data) else {
        test.check(false, "resident/fault-feedback-fixture-load"); return
    }

    let actionEntered = DispatchSemaphore(value: 0)
    let actionUnblock = DispatchSemaphore(value: 0)
    let recorder = ResidentFaultTestRecorder()
    let blockedAction = fixture.requiredString("blocked_action")
    guard let input = try? ResidentInput.load(home: home, dispatchAction: { action, complete in
        if action.actionId == blockedAction {
            actionEntered.signal(); _ = actionUnblock.wait(timeout: .now() + .seconds(3))
        }
        complete(0)
    }, onModeChanged: { _, _, _ in return true }, onFaultRelease: { recorder.record($0) }) else {
        test.check(false, "resident/fault-feedback-production-input-load"); return
    }
    _ = input.inject(chord: fixture.requiredString("entry_chord")); input.routing.flushForSelfTest()
    _ = input.inject(chord: fixture.requiredString("blocked_chord"))
    test.check(actionEntered.wait(timeout: .now() + .seconds(1)) == .success,
        "resident/fault-feedback-action-dispatch-really-stalled")
    let originalGeneration = input.routing.generation
    let beforeRelease = DispatchTime.now().uptimeNanoseconds
    input.driveWatchdogDecisionForSelfTest(ResidentInputWatchdogDecision(shouldRelease: true, reason: ResidentInputReleaseReason(rawValue: fixture.requiredString("fault_reason"))))
    let afterRelease = DispatchTime.now().uptimeNanoseconds
    let released = recorder.waitForCount(1)
    test.check(input.routing.mode == "default" && !input.routing.isAccepting && afterRelease - beforeRelease < 250_000_000,
        "resident/fault-feedback-production-release-does-not-wait-for-action")
    test.check(released.count == 1 && released[0].inputEpoch == input.inputEpoch
        && released[0].reason.rawValue == fixture.requiredString("fault_reason") && released[0].originalGeneration == originalGeneration
        && released[0].releasedGeneration == originalGeneration + 1 && released[0].receiptUptimeNs >= beforeRelease
        && released[0].receiptUptimeNs <= afterRelease,
        "resident/fault-feedback-captures-actual-reason-epoch-generation-and-release-receipt")
    actionUnblock.signal(); input.routing.flushForSelfTest()
    test.check(input.routing.mode == "default" && input.routing.oldestPendingActionUptimeNs == 0,
        "resident/fault-feedback-late-action-ack-does-not-undo-release")

    // Notice delivery itself is hostile. One executing callback blocks while
    // real releases continue to coalesce into the separate single pending slot.
    let deliveryEntered = DispatchSemaphore(value: 0)
    let deliveryUnblock = DispatchSemaphore(value: 0)
    let deliveryRecorder = ResidentFaultTestRecorder()
    let clock = ResidentAtomic<UInt64>(fixture.requiredUInt64("receipt_uptime_ns"))
    let deliveries = ResidentAtomic<Int>(0)
    let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { _, _, _ in return true }, onFaultRelease: { event in
            deliveryRecorder.record(event)
            if deliveries.wrappingAdd(1, ordering: .acquiringAndReleasing) == 0 {
                deliveryEntered.signal(); _ = deliveryUnblock.wait(timeout: .now() + .seconds(3))
            }
        }, uptimeProvider: { clock.load(ordering: .acquiring) })
    _ = routing.admit(chord: fixture.requiredString("entry_chord")); routing.flushForSelfTest()
    routing.release(reason: .actionDeadline)
    test.check(deliveryEntered.wait(timeout: .now() + .seconds(1)) == .success,
        "resident/fault-feedback-notice-recipient-really-stalled")
    let burstBegin = DispatchTime.now().uptimeNanoseconds
    for index in 1...Int(fixture.requiredUInt64("burst_count")) {
        clock.store(fixture.requiredUInt64("receipt_uptime_ns") + UInt64(index), ordering: .releasing)
        routing.release(reason: .mailboxOverflow)
    }
    let latestGeneration = routing.generation
    let burstElapsed = DispatchTime.now().uptimeNanoseconds - burstBegin
    test.check(routing.mode == "default" && burstElapsed < 250_000_000,
        "resident/fault-feedback-stalled-recipient-cannot-block-local-release")
    test.check(routing.health()["fault_delivery"]?.at(path: "pending_events")?.intValue == 1
        && routing.health()["fault_delivery"]?.at(path: "pending_capacity")?.intValue == 1,
        "resident/fault-feedback-burst-has-one-pending-event")
    routing.setAccepting(true)
    _ = routing.admit(chord: fixture.requiredString("entry_chord"))
    test.check(routing.isAccepting && routing.mode == "resize",
        "resident/fault-feedback-stalled-recipient-cannot-block-local-rearm")
    deliveryUnblock.signal()
    let delivered = deliveryRecorder.waitForCount(2)
    test.check(delivered.count == 2 && delivered.last?.releasedGeneration == latestGeneration
        && delivered.last?.receiptUptimeNs == fixture.requiredUInt64("receipt_uptime_ns") + fixture.requiredUInt64("burst_count"),
        "resident/fault-feedback-delivers-latest-immutable-event-without-retagging-to-rearm")
    routing.flushForSelfTest()

    // Normal exits have no event: the next genuine release fences the sequence.
    let normalRecorder = ResidentFaultTestRecorder()
    let normal = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { _, _, _ in return true }, onFaultRelease: { normalRecorder.record($0) })
    normal.release(reason: .callbackDeadline)
    _ = normalRecorder.waitForCount(1)
    _ = normal.admit(chord: fixture.requiredString("entry_chord")); normal.flushForSelfTest()
    _ = normal.admit(chord: "0x35"); normal.flushForSelfTest()
    normal.release(reason: .globalStop)
    normal.release(reason: .externalContextInvalidated)
    normal.release(reason: .worldOrFocusedSpaceUnavailable)
    normal.release(reason: .tapRunLoopDeadline)
    let normalEvents = normalRecorder.waitForCount(2)
    test.check(normalEvents.count == 2 && normalEvents.map(\.reason) == [.callbackDeadline, .tapRunLoopDeadline],
        "resident/fault-feedback-normal-exit-stop-and-context-change-never-inherit-sticky-fault")

    let offEvents = ResidentFaultTestRecorder()
    let offActorCalls = ResidentAtomic<Int>(0)
    let offInput = ResidentInput(configuration: configuration, dispatchAction: { _, complete in
        offActorCalls.wrappingAdd(1, ordering: .relaxed); complete(0)
    }, onModeChanged: { _, _, _ in return true }, onFaultRelease: { offEvents.record($0) })
    offInput.stop()
    offInput.routing.release(reason: .mailboxOverflow)
    let offReleased = offEvents.waitForCount(1)
    let offGeneration = offInput.routing.generation
    let offPresentationAccepted = MainActor.assumeIsolated { () -> Bool in
        guard let event = offReleased.first else { return false }
        let presenter = ResidentInputFaultNoticePresenter(makeSurface: { ResidentFaultTestSurface() }, schedule: { _, _ in })
        let accepted = presenter.receive(event, currentInputEpoch: offInput.inputEpoch, currentInputGeneration: offGeneration)
        presenter.stop()
        return accepted
    }
    test.check(offPresentationAccepted && !offInput.routing.isAccepting && offInput.routing.mode == "default"
        && offInput.routing.generation == offGeneration && offInput.inject(chord: fixture.requiredString("entry_chord")) == .passedThrough
        && offActorCalls.load(ordering: .acquiring) == 0,
        "resident/fault-feedback-production-off-claims-and-actor-remain-untouched-by-notice")

    runResidentFaultMailboxChecks(fixture: fixture, test: &test)
    runResidentFaultNoticeProjectionChecks(fixture: fixture, test: &test)
    let presentationChecks = MainActor.assumeIsolated { residentFaultNoticePresentationChecks(fixture: fixture) }
    for (condition, label) in presentationChecks { test.check(condition, label) }
}

private func residentFaultEvent(_ fixture: JSONValue, generation: String = "first_generation",
                               receipt: String = "receipt_uptime_ns", epoch: String = "epoch",
                               reason: ResidentInputFaultReason = .actionDeadline) -> ResidentInputFaultRelease {
    let sequence = UInt64(fixture.at(path: generation)!.intValue!)
    return ResidentInputFaultRelease(inputEpoch: fixture.at(path: epoch)!.stringValue!, reason: reason,
        originalGeneration: sequence - 1, releasedGeneration: sequence,
        receiptUptimeNs: UInt64(fixture.at(path: receipt)!.intValue!))
}

private func runResidentFaultMailboxChecks(fixture: JSONValue, test: inout SelfTest) {
    let executor = ManualExecutor()
    let recorder = ResidentFaultTestRecorder()
    let first = residentFaultEvent(fixture)
    let latest = residentFaultEvent(fixture, generation: "later_generation", receipt: "later_receipt_uptime_ns")
    let mailbox = ResidentInputFaultMailbox(inputEpoch: first.inputEpoch, execute: { executor.enqueue($0) }, deliver: { recorder.record($0) })
    mailbox.submit(latest); mailbox.submit(first); mailbox.submit(latest)
    mailbox.submit(residentFaultEvent(fixture, epoch: "other_epoch"))
    test.check(executor.pending == 1 && mailbox.health["pending_events"]?.intValue == 1,
        "resident/fault-feedback-presentation-stall-does-not-enqueue-unbounded-main-jobs")
    executor.runOne()
    test.check(recorder.waitForCount(1) == [latest] && mailbox.health["rejected_events"]?.intValue == 1,
        "resident/fault-feedback-late-producer-cannot-overwrite-newer-release-or-cross-epoch")
    let concurrentRecorder = ResidentFaultTestRecorder()
    let concurrentMailbox = ResidentInputFaultMailbox(inputEpoch: first.inputEpoch,
        execute: { executor.enqueue($0) }, deliver: { concurrentRecorder.record($0) })
    let count = fixture.requiredInt("burst_count")
    DispatchQueue.concurrentPerform(iterations: count) { index in
        let generation = first.releasedGeneration + UInt64(index)
        concurrentMailbox.submit(ResidentInputFaultRelease(inputEpoch: first.inputEpoch, reason: .mailboxOverflow,
            originalGeneration: generation - 1, releasedGeneration: generation,
            receiptUptimeNs: first.receiptUptimeNs + UInt64(index)))
    }
    test.check(executor.pending == 1 && concurrentMailbox.health["pending_events"]?.intValue == 1,
        "resident/fault-feedback-concurrent-producers-preserve-single-pending-main-job")
    executor.runOne()
    let concurrentEvents = concurrentRecorder.waitForCount(1)
    test.check(concurrentEvents.count == 1 && concurrentEvents[0].releasedGeneration == first.releasedGeneration + UInt64(count - 1)
        && concurrentEvents[0].receiptUptimeNs == first.receiptUptimeNs + UInt64(count - 1),
        "resident/fault-feedback-concurrent-producers-deliver-highest-generation-with-own-receipt")
}

private func runResidentFaultNoticeProjectionChecks(fixture: JSONValue, test: inout SelfTest) {
    let first = residentFaultEvent(fixture)
    let later = residentFaultEvent(fixture, generation: "later_generation", receipt: "later_receipt_uptime_ns")
    let now = fixture.requiredUInt64("presentation_uptime_ns")
    var state = ResidentInputFaultNoticeState()
    func admit(_ event: ResidentInputFaultRelease, epoch: String? = nil, generation: UInt64? = nil, stamp: UInt64? = nil) -> Bool {
        state.receive(event, currentInputEpoch: epoch ?? first.inputEpoch, currentInputGeneration: generation ?? first.releasedGeneration, now: stamp ?? now)
    }
    test.check(!admit(first, epoch: later.inputEpoch + "-wrong") && state.visibleEvent == nil,
        "resident/fault-notice-rejects-old-input-epoch")
    test.check(!admit(first, generation: first.releasedGeneration + 1), "resident/fault-notice-rejects-rearmed-or-normal-exit-generation")
    test.check(!admit(residentFaultEvent(fixture, receipt: "future_receipt_uptime_ns")), "resident/fault-notice-rejects-future-release-evidence")
    let invalid = ResidentInputFaultRelease(inputEpoch: first.inputEpoch, reason: first.reason,
        originalGeneration: first.originalGeneration, releasedGeneration: first.releasedGeneration + 1, receiptUptimeNs: first.receiptUptimeNs)
    test.check(!admit(invalid, generation: invalid.releasedGeneration), "resident/fault-notice-rejects-unproven-release-generation")
    test.check(admit(first) && state.visibleEvent == first, "resident/fault-notice-accepts-current-real-release")
    let deadline = state.dismissalUptimeNs
    test.check(!admit(first) && state.dismissalUptimeNs == deadline, "resident/fault-notice-duplicate-cannot-extend-dismissal")
    test.check(admit(later, generation: later.releasedGeneration, stamp: later.receiptUptimeNs + 1)
        && !state.dismiss(first, now: deadline), "resident/fault-notice-old-dismissal-cannot-hide-latest-event")
    let laterDeadline = state.dismissalUptimeNs
    test.check(!state.dismiss(later, now: laterDeadline - 1) && state.dismiss(later, now: laterDeadline),
        "resident/fault-notice-one-explicit-deadline-dismisses-current-event")
    test.check(!admit(later, generation: later.releasedGeneration, stamp: laterDeadline),
        "resident/fault-notice-expired-event-cannot-replay-from-sticky-health")
    let replacement = residentFaultEvent(fixture, epoch: "other_epoch")
    test.check(admit(replacement, epoch: replacement.inputEpoch)
        && !admit(later, epoch: replacement.inputEpoch, generation: later.releasedGeneration),
        "resident/fault-notice-new-input-epoch-retires-old-events")
    test.check(ResidentInputFaultReason.mailboxOverflow.humanMessage == fixture.at(path: "busy_message")?.stringValue
        && ResidentInputFaultReason.actionDeadline.humanMessage == fixture.at(path: "deadline_message")?.stringValue,
        "resident/fault-notice-human-messages-do-not-expose-internal-codes")
}

@MainActor
private func residentFaultNoticePresentationChecks(fixture: JSONValue) -> [(Bool, String)] {
    let first = residentFaultEvent(fixture)
    let later = residentFaultEvent(fixture, generation: "later_generation", receipt: "later_receipt_uptime_ns")
    let clock = ResidentAtomic<UInt64>(fixture.requiredUInt64("presentation_uptime_ns"))
    let surface = ResidentFaultTestSurface()
    var mounts = 0
    var deadlines: [(UInt64, DispatchWorkItem)] = []
    let presenter = ResidentInputFaultNoticePresenter(makeSurface: { mounts += 1; return surface },
        uptimeProvider: { clock.load(ordering: .acquiring) }, schedule: { deadlines.append(($0, $1)) })
    var checks: [(Bool, String)] = []
    _ = presenter.receive(first, currentInputEpoch: first.inputEpoch, currentInputGeneration: first.releasedGeneration)
    _ = presenter.receive(first, currentInputEpoch: first.inputEpoch, currentInputGeneration: first.releasedGeneration)
    checks.append((mounts == 1 && surface.messages.count == 1 && deadlines.count == 1,
        "resident/fault-notice-live-presenter-deduplicates-panel-and-deadline"))
    clock.store(fixture.requiredUInt64("later_presentation_uptime_ns"), ordering: .releasing)
    _ = presenter.receive(later, currentInputEpoch: later.inputEpoch, currentInputGeneration: later.releasedGeneration)
    checks.append((mounts == 1 && surface.messages.count == 2 && deadlines.count == 2 && deadlines[0].1.isCancelled
        && presenter.health["surface_count"]?.intValue == 1 && presenter.health["dismissal_jobs"]?.intValue == 1,
        "resident/fault-notice-live-presenter-reuses-one-panel-and-replaces-one-deadline"))
    clock.store(deadlines[0].0, ordering: .releasing); deadlines[0].1.perform()
    checks.append((surface.hides == 0 && presenter.health["visible"]?.boolValue == true,
        "resident/fault-notice-cancelled-older-job-cannot-hide-current-panel"))
    clock.store(deadlines[1].0, ordering: .releasing); deadlines[1].1.perform()
    checks.append((surface.hides == 1 && presenter.health["visible"]?.boolValue == false
        && presenter.health["dismissal_jobs"]?.intValue == 0,
        "resident/fault-notice-live-presenter-dismisses-once-without-a-poll"))
    var controls = ResidentControlsState()
    controls.receive(revision: 1, world: .object(["resident_running": .bool(false), "resident_status": .string("Stopped")]))
    let offRevision = controls.revision
    let fresh = ResidentInputFaultRelease(inputEpoch: later.inputEpoch, reason: .mailboxOverflow,
        originalGeneration: later.releasedGeneration, releasedGeneration: later.releasedGeneration + 1,
        receiptUptimeNs: clock.load(ordering: .acquiring))
    _ = presenter.receive(fresh, currentInputEpoch: fresh.inputEpoch, currentInputGeneration: fresh.releasedGeneration)
    checks.append((!controls.globallyRunning && controls.status == "Stopped" && controls.revision == offRevision
        && controls.toggleTarget == nil && mounts == 1,
        "resident/fault-notice-off-controls-stay-off-with-no-actor-or-claim-mutation"))
    presenter.stop()
    checks.append((presenter.health["dismissal_jobs"]?.intValue == 0 && presenter.health["visible"]?.boolValue == false
        && deadlines.last?.1.isCancelled == true,
        "resident/fault-notice-process-shutdown-cancels-only-presentation-deadline"))
    return checks
}
