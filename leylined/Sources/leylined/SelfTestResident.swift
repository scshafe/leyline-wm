// Hermetic resident controls/input suites. No NSApplication, live AX call,
// CGEventTap installation, launchctl, or second keyboard owner is created.
import CoreGraphics
import Darwin
import Foundation
import LeylineModel

private final class ResidentTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [ResidentInputAction] = []
    private var modes: [(String, UInt64)] = []
    func action(_ action: ResidentInputAction) { lock.lock(); actions.append(action); lock.unlock() }
    func mode(_ name: String, _ generation: UInt64) { lock.lock(); modes.append((name, generation)); lock.unlock() }
    func snapshot() -> (actions: [ResidentInputAction], modes: [(String, UInt64)]) {
        lock.lock(); defer { lock.unlock() }; return (actions, modes)
    }
}

private final class ResidentProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [ResidentInputAction] = []
    private var completions: [UInt64: @Sendable (Int) -> Void] = [:]
    func dispatch(_ action: ResidentInputAction, completion: @escaping @Sendable (Int) -> Void) {
        lock.lock(); actions.append(action); completions[action.receiptUptimeNs] = completion; lock.unlock()
    }
    func complete(_ receipt: UInt64, rc: Int = 0) {
        lock.lock(); let completion = completions.removeValue(forKey: receipt); lock.unlock()
        completion?(rc)
    }
    func receipt(_ stamp: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return actions.first { $0.receiptUptimeNs == stamp }?.receiptUptimeNs
    }
}

private final class ResidentSettingsTestRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshots: [ResidentSettingsSnapshot] = []
    func record(_ snapshot: ResidentSettingsSnapshot) {
        condition.lock(); snapshots.append(snapshot); condition.broadcast(); condition.unlock()
    }
    func wait(_ predicate: (ResidentSettingsSnapshot) -> Bool) -> ResidentSettingsSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !snapshots.contains(where: predicate) {
            if !condition.wait(until: deadline) { return nil }
        }
        return snapshots.last(where: predicate)
    }
    var latest: ResidentSettingsSnapshot? {
        condition.lock(); defer { condition.unlock() }; return snapshots.last
    }
}

private func residentTestHome(_ args: [String]) -> String {
    if let index = args.firstIndex(of: "--home"), index + 1 < args.count { return args[index + 1] }
    return ProcessInfo.processInfo.environment["LEYLINE_HOME"]
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
}

func runResidentSelfTest(_ args: [String]) -> Int32 {
    var test = SelfTest()
    let home = residentTestHome(args)
    runResidentInputChecks(home: home, test: &test)
    runResidentControlsChecks(home: home, test: &test)
    runResidentSettingsChecks(test: &test)
    return test.finish("resident")
}

func runResidentInputSelfTest(_ args: [String]) -> Int32 {
    var test = SelfTest()
    runResidentInputChecks(home: residentTestHome(args), test: &test)
    return test.finish("input")
}

func runResidentShellSelfTest(_ args: [String]) -> Int32 {
    var test = SelfTest()
    runResidentControlsChecks(home: residentTestHome(args), test: &test)
    runResidentSettingsChecks(test: &test)
    return test.finish("shell")
}

private func runResidentInputChecks(home: String, test: inout SelfTest) {
    let recorder = ResidentTestRecorder()
    let completionRc = ResidentAtomic<Int>(0)
    guard let input = try? ResidentInput.load(home: home, dispatchAction: { action, complete in
        recorder.action(action); complete(completionRc.load(ordering: .acquiring))
    }, onModeChanged: { mode, generation, _ in recorder.mode(mode, generation) ; return true }) else {
        test.check(false, "resident/input-shipped-manifest-load"); return
    }
    test.check(input.health()["tap_installed"]?.boolValue == false, "resident/self-test-does-not-install-tap")
    runResidentModeReleaseChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentModeReleaseAcknowledgementChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentActionProgressChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentQueuedKeyUpChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentEntryKeyUpChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentInputFaultFeedbackChecks(configuration: input.routing.configuration, home: home, test: &test)
    runResidentSpaceShortcutChecks(configuration: input.routing.configuration, home: home, test: &test)
    let mouseMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
    test.check(ResidentInput.keyboardEventMask & UInt64(mouseMask) == 0, "resident/tap-mask-keyboard-only")
    test.check(input.routing.configuration.decode.chord(keyCode: 0x37, flags: [.cmd]) == nil,
               "resident/pure-modifier-never-claimable")
    test.check(input.inject(chord: "cmd + ctrl + alt + shift - 0x31") == .passedThrough,
               "resident/retired-text-capture-is-not-claimed")
    test.check(input.inject(chord: "fn - f1") == .passedThrough,
               "resident/retired-provider-shortcut-is-not-claimed")
    test.check(input.inject(chord: "cmd + ctrl + alt + shift - m") == .claimed,
               "resident/mode-entry-is-optimistic-and-process-local")
    input.routing.flushForSelfTest()
    test.check(input.routing.mode == "move", "resident/entry-rc0-retains-mode")
    let beforeCancel = input.routing.generation
    completionRc.store(3, ordering: .releasing)
    _ = input.inject(chord: "0x35")
    input.routing.flushForSelfTest()
    test.check(input.routing.mode == "move" && input.routing.generation > beforeCancel + 1,
               "resident/partial-cancel-restores-mode-with-fresh-generation")
    completionRc.store(4, ordering: .releasing)
    _ = input.inject(chord: "h")
    input.routing.flushForSelfTest()
    test.check(input.routing.mode == "default", "resident/stale-rc4-force-exits-frozen-fsm")
    completionRc.store(0, ordering: .releasing)
    _ = input.inject(chord: "cmd + ctrl + alt + shift - r")
    input.routing.flushForSelfTest()
    _ = input.inject(chord: "h")
    _ = input.inject(chord: "h", keyUp: true)
    input.routing.flushForSelfTest()
    test.check(recorder.snapshot().actions.contains { $0.phase == .keyUp && $0.actionId == "resize.adjust.west" },
               "resident/key-up-delivered-to-direct-resize-scheduler")
    _ = input.inject(chord: "0x35")
    test.check(input.routing.mode == "default", "resident/escape-releases-before-authority-ack")
    input.routing.flushForSelfTest()
    test.check(recorder.snapshot().modes.contains { $0.0 == "default" }, "resident/mode-release-publishes-exit-notification")

    let now: UInt64 = 1_000_000_000
    let old = now - 201_000_000
    for (label, callback, runLoop, authority, modal) in [
        ("callback", old, now, now, false), ("run-loop", UInt64(0), old, now, false),
        ("authority", UInt64(0), now, old, true),
    ] {
        let decision = ResidentInputWatchdogDecision.evaluate(now: now, callbackStarted: callback,
            runLoopProgress: runLoop, authorityProgress: authority, modal: modal, started: true)
        test.check(decision.shouldRelease, "resident/watchdog-independent-\(label)-release")
    }
    test.check(!ResidentInputWatchdogDecision.evaluate(now: now, callbackStarted: 0,
        runLoopProgress: now, authorityProgress: old, modal: false, started: true).shouldRelease,
               "resident/watchdog-does-not-reap-default-mode-idle")
    test.check(ResidentInputWatchdogDecision.evaluate(now: now, callbackStarted: 0,
        runLoopProgress: now, authorityProgress: now, modal: true, started: true,
        pendingActionStarted: old).reason == "action_deadline",
               "resident/watchdog-releases-blocked-action-with-responsive-authority")
    test.check(ResidentInputConstants.releaseBudgetMilliseconds + ResidentInputConstants.watchdogCadenceMilliseconds
        <= ResidentInputConstants.releaseCeilingMilliseconds, "resident/watchdog-detection-plus-release-within-250ms")

    // Deliberately hostile dispatch blocks the delivery worker. The callback
    // admission lane still bounds its queue and releases mode independently.
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    guard let blocked = try? ResidentInput.load(home: home, dispatchAction: { action, complete in
        if action.actionId == "resize.adjust.west" { entered.signal(); _ = release.wait(timeout: .now() + .seconds(3)) }
        complete(0)
    }, onModeChanged: { _, _, _ in return true }) else {
        test.check(false, "resident/blocked-dispatch-fixture"); return
    }
    _ = blocked.inject(chord: "cmd + ctrl + alt + shift - r")
    blocked.routing.flushForSelfTest()
    _ = blocked.inject(chord: "h")
    test.check(entered.wait(timeout: .now() + .seconds(1)) == .success, "resident/hostile-dispatch-observation-boundary")
    test.check(blocked.routing.oldestPendingActionUptimeNs > 0,
               "resident/pending-action-deadline-uses-real-input-receipt")
    let begin = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<100 { _ = blocked.inject(chord: "h") }
    let elapsed = DispatchTime.now().uptimeNanoseconds - begin
    test.check((blocked.health()["peak_queued_events"]?.intValue ?? 999) <= Int64(ResidentInputConstants.maximumQueuedEvents),
               "resident/blocked-dispatch-queue-is-bounded")
    test.check(blocked.routing.mode == "default" && elapsed < 250_000_000,
               "resident/overflow-releases-without-timeline-or-render-wait")
    test.check(blocked.routing.oldestPendingActionUptimeNs == 0,
               "resident/generation-invalidation-clears-old-modal-action-deadline")
    blocked.driveWatchdogDecisionForSelfTest(ResidentInputWatchdogDecision(
        shouldRelease: true, reason: "authority_deadline"))
    test.check(!blocked.routing.isAccepting && blocked.routing.mode == "default"
        && blocked.health()["watchdog_release_count"]?.intValue == 1,
               "resident/real-watchdog-handler-claims-nothing-while-dispatch-stalled")
    release.signal()
    blocked.routing.flushForSelfTest()
    test.check(blocked.routing.mode == "default", "resident/late-action-ack-never-reenters-released-generation")
    test.check(blocked.health()["normal_path_subprocesses"]?.intValue == 0,
               "resident/dispatch-has-no-shell-or-jq-fallback")
    let stopAcknowledged = DispatchSemaphore(value: 0)
    blocked.stop { stopAcknowledged.signal() }
    test.check(stopAcknowledged.wait(timeout: .now() + .milliseconds(250)) == .success
        && !blocked.routing.isAccepting,
               "resident/no-tap-stop-acknowledges-claim-release-without-process-exit")
    input.setClaimsAllowed(false, reason: "world_unavailable")
    test.check(input.inject(chord: "cmd + ctrl + alt + shift - h") == .passedThrough
        && input.health()["claims_allowed"]?.boolValue == false,
               "resident/unknown-or-off-world-positive-claim-gate-passes-through")
    let unavailableGeneration = input.routing.generation
    input.setClaimsAllowed(false, reason: "world_unavailable")
    test.check(input.routing.generation == unavailableGeneration,
               "resident/repeated-unavailable-snapshots-do-not-feedback-mode-transitions")
}

/// Paired release edges must not execute an inverse modal binding or repeat a global service action.
private func runResidentEntryKeyUpChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: home + "/leylined/Fixtures/resident/entry-keyup.json"),
          let fixture = try? JSONValue.parse(data), let modes = fixture.at(path: "modes")?.arrayValue, modes.count == 2 else {
        test.check(false, "resident/entry-keyup-fixture-load"); return
    }
    for mode in modes {
        let recorder = ResidentTestRecorder()
        let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in recorder.action(action); complete(0) },
            onModeChanged: { mode, generation, _ in recorder.mode(mode, generation) ; return true })
        let chord = mode.at(path: "entry_chord")!.stringValue!, name = mode.at(path: "mode")!.stringValue!
        let down = routing.admit(chord: chord); routing.flushForSelfTest()
        let generation = routing.generation
        let up = routing.admit(chord: chord, phase: .keyUp); routing.flushForSelfTest()
        let entryActions = recorder.snapshot().actions
        test.check(down == .claimed && up == .claimed && routing.mode == name && routing.generation == generation
            && entryActions.count == 1 && entryActions[0].actionId == mode.at(path: "entry_action")?.stringValue
            && entryActions[0].phase == .keyDown && !entryActions.contains { $0.actionId == mode.at(path: "inverse_action")?.stringValue },
            "resident/entry-keyup-\(name)-release-does-not-execute-inverse-or-exit-mode")
        if name == "resize" {
            let resizeChord = fixture.at(path: "resize_chord")!.stringValue!, actionId = fixture.at(path: "resize_action")!.stringValue!
            _ = routing.admit(chord: resizeChord); _ = routing.admit(chord: resizeChord, phase: .keyUp); routing.flushForSelfTest()
            test.check(recorder.snapshot().actions.filter { $0.actionId == actionId && $0.phase == .keyDown }.count == 1
                && recorder.snapshot().actions.filter { $0.actionId == actionId && $0.phase == .keyUp }.count == 1 && routing.mode == "resize",
                "resident/entry-keyup-released-Hyper-R-followed-by-plain-L-tap-delivers-one-adjustment")
        }
        let escape = fixture.at(path: "cancel_chord")!.stringValue!
        _ = routing.admit(chord: escape); routing.flushForSelfTest()
        let afterEscape = routing.generation, actionCount = recorder.snapshot().actions.count
        _ = routing.admit(chord: escape, phase: .keyUp); routing.flushForSelfTest()
        test.check(routing.mode == "default" && routing.generation == afterEscape && recorder.snapshot().actions.count == actionCount,
            "resident/entry-keyup-\(name)-Escape-release-cannot-reenter-or-dispatch-again")
    }
    let recorder = ResidentTestRecorder()
    let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in recorder.action(action); complete(0) }, onModeChanged: { _, _, _ in return true })
    let serviceChord = fixture.at(path: "service_chord")!.stringValue!, serviceAction = fixture.at(path: "service_action")!.stringValue!
    let down = routing.admit(chord: serviceChord); let up = routing.admit(chord: serviceChord, phase: .keyUp); routing.flushForSelfTest()
    test.check(down == .claimed && up == .claimed && recorder.snapshot().actions.filter { $0.actionId == serviceAction }.count == 1
        && recorder.snapshot().actions.first?.phase == .keyDown, "resident/entry-keyup-service-restart-pair-dispatches-exactly-once")
    let modifier = fixture.at(path: "modifier_chord")!.stringValue!
    test.check(routing.admit(chord: modifier) == .passedThrough && routing.admit(chord: modifier, phase: .keyUp) == .passedThrough
        && configuration.decode.chord(keyCode: 0x37, flags: [.cmd]) == nil,
        "resident/entry-keyup-pure-modifier-still-passes-through-with-no-claim")
}

/// Hold the real mode callback so the actual production mailbox contains press/release pairs.
private func runResidentQueuedKeyUpChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: home + "/leylined/Fixtures/resident/keyup-fifo.json"),
          let fixture = try? JSONValue.parse(data), let scenarios = fixture.at(path: "scenarios")?.arrayValue,
          let entryChord = fixture.at(path: "entry_chord")?.stringValue,
          let entryAction = fixture.at(path: "entry_action")?.stringValue,
          let upChord = fixture.at(path: "up_chord")?.stringValue, let upAction = fixture.at(path: "up_action")?.stringValue,
          let cancelChord = fixture.at(path: "cancel_chord")?.stringValue, let step = fixture.at(path: "step")?.intValue else {
        test.check(false, "resident/keyup-fifo-fixture-load"); return
    }
    test.check(scenarios.count == 3 && fixture.at(path: "queue_capacity")?.intValue == Int64(ResidentInputConstants.maximumQueuedEvents),
        "resident/keyup-fifo-nonempty-three-scenario-fixture-and-unchanged-bounded-queue")
    for scenario in scenarios {
        let name = scenario.at(path: "name")!.stringValue!, chords = scenario.at(path: "down_chords")!.arrayValue!.compactMap(\.stringValue)
        let expected = scenario.at(path: "down_actions")!.arrayValue!.compactMap(\.stringValue)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), recorder = ResidentTestRecorder()
        let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in
            recorder.action(action); complete(0)
        }, onModeChanged: { mode, generation, _ in
            recorder.mode(mode, generation)
            if mode == "resize" { entered.signal(); _ = release.wait(timeout: .now() + 2) }
        return true })
        let entry = routing.admit(chord: entryChord), held = entered.wait(timeout: .now() + 1) == .success
        let admissions = chords.map { routing.admit(chord: $0) }
        let up = routing.admit(chord: upChord, phase: .keyUp)
        release.signal(); routing.flushForSelfTest()
        let actions = recorder.snapshot().actions
        test.check(held && entry == .claimed && admissions.allSatisfy { $0 == .claimed } && up == .claimed
            && actions.map(\.actionId) == [entryAction] + expected + [upAction]
            && actions.first?.phase == .keyDown && actions.last?.phase == .keyUp
            && actions.dropFirst().dropLast().allSatisfy { $0.phase == .keyDown },
            "resident/keyup-fifo-\(name)-entry-every-admitted-keydown-then-keyup")
        let displacement = actions.filter { $0.phase == .keyDown }.reduce(Int64(0)) { result, action in
            result + (action.actionId == "resize.adjust.east" ? step : action.actionId == "resize.adjust.west" ? -step : 0)
        }
        test.check(displacement == scenario.at(path: "expected_displacement")?.intValue
            && routing.mode == "resize" && routing.health()["release_count"]?.intValue == 0,
            "resident/keyup-fifo-\(name)-preserves-cumulative-relative-displacement-without-mode-release")
    }
    let cancelEntered = DispatchSemaphore(value: 0), cancelRelease = DispatchSemaphore(value: 0), cancelled = ResidentTestRecorder()
    let cancelling = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in cancelled.action(action); complete(0) },
        onModeChanged: { mode, _, _ in if mode == "resize" { cancelEntered.signal(); _ = cancelRelease.wait(timeout: .now() + 2) } ; return true })
    _ = cancelling.admit(chord: entryChord); _ = cancelEntered.wait(timeout: .now() + 1)
    _ = cancelling.admit(chord: upChord); _ = cancelling.admit(chord: upChord)
    let cancel = cancelling.admit(chord: cancelChord)
    let immediateDefault = cancelling.mode == "default"
    cancelRelease.signal(); cancelling.flushForSelfTest()
    test.check(cancel == .claimed && immediateDefault && cancelling.mode == "default"
        && !cancelled.snapshot().actions.contains { $0.phase == .keyDown && $0.actionId.hasPrefix("resize.adjust.") },
        "resident/keyup-fifo-Escape-still-dominates-obsolete-displacement-and-releases-immediately")
    let fullEntered = DispatchSemaphore(value: 0), fullRelease = DispatchSemaphore(value: 0), overflowed = ResidentTestRecorder()
    let bounded = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in overflowed.action(action); complete(0) },
        onModeChanged: { mode, _, _ in if mode == "resize" { fullEntered.signal(); _ = fullRelease.wait(timeout: .now() + 2) } ; return true })
    _ = bounded.admit(chord: entryChord); _ = fullEntered.wait(timeout: .now() + 1)
    let burst = (0..<ResidentInputConstants.maximumQueuedEvents + 2).map { _ in bounded.admit(chord: upChord) }
    fullRelease.signal(); bounded.flushForSelfTest()
    test.check(burst.contains(.queueFull) && bounded.mode == "default"
        && (bounded.health()["peak_queued_events"]?.intValue ?? 999) <= Int64(ResidentInputConstants.maximumQueuedEvents)
        && bounded.health()["last_release_reason"]?.stringValue == "mailbox_overflow",
        "resident/keyup-fifo-preservation-keeps-overflow-an-explicit-bounded-safety-release")
}

/// The actual pending-action lane uses a controlled monotonic clock. Deferred
/// completions return immediately, so no tap, delay, or blocked worker is needed.
private func runResidentActionProgressChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: home + "/leylined/Fixtures/resident/action-progress.json"),
          let fixture = try? JSONValue.parse(data) else {
        test.check(false, "resident/progress-fixture-load"); return
    }
    func stamp(_ key: String) -> UInt64 { UInt64(fixture.at(path: key)!.intValue!) }
    let clock = ResidentAtomic<UInt64>(stamp("initial_now"))
    let recorder = ResidentProgressRecorder()
    let entryAction = fixture.at(path: "entry_action")!.stringValue!
    let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in
        if action.actionId == entryAction { complete(0) } else { recorder.dispatch(action, completion: complete) }
    }, onModeChanged: { _, _, _ in return true }, uptimeProvider: { clock.load(ordering: .acquiring) })
    _ = routing.admit(chord: fixture.at(path: "entry_chord")!.stringValue!, receiptUptimeNs: stamp("entry_receipt"))
    routing.flushForSelfTest()
    let generation = routing.generation
    _ = routing.admit(chord: fixture.at(path: "oldest_chord")!.stringValue!, receiptUptimeNs: stamp("oldest_receipt"))
    _ = routing.admit(chord: fixture.at(path: "younger_chord")!.stringValue!, receiptUptimeNs: stamp("younger_receipt"))
    routing.flushForSelfTest()
    func progress(_ receipt: String, _ update: String, generation value: UInt64? = nil) -> Bool {
        routing.noteActionProgress(receiptUptimeNs: stamp(receipt), generation: value ?? generation, progressUptimeNs: stamp(update))
    }
    test.check(routing.mode == "resize" && routing.health()["pending_action_count"]?.intValue == 2
        && routing.oldestPendingActionUptimeNs == stamp("oldest_receipt"), "resident/progress-pending-actions-start-at-original-receipts")
    test.check(!progress("unknown_receipt", "first_progress") && routing.oldestPendingActionUptimeNs == stamp("oldest_receipt"),
        "resident/progress-wrong-receipt-cannot-refresh-deadline")
    test.check(!progress("oldest_receipt", "first_progress", generation: generation + 1)
        && routing.oldestPendingActionUptimeNs == stamp("oldest_receipt"), "resident/progress-wrong-generation-cannot-refresh-deadline")
    test.check(!progress("oldest_receipt", "before_receipt") && !progress("oldest_receipt", "oldest_receipt")
        && routing.oldestPendingActionUptimeNs == stamp("oldest_receipt"), "resident/progress-requires-a-postreceipt-timestamp")
    test.check(!progress("oldest_receipt", "future_progress") && routing.oldestPendingActionUptimeNs == stamp("oldest_receipt"),
        "resident/progress-future-timestamp-cannot-refresh-deadline")
    test.check(progress("oldest_receipt", "first_progress") && routing.oldestPendingActionUptimeNs == stamp("first_progress")
        && recorder.receipt(stamp("oldest_receipt")) == stamp("oldest_receipt"), "resident/progress-genuine-update-preserves-original-input-receipt")
    test.check(!progress("oldest_receipt", "first_progress") && !progress("oldest_receipt", "regressed_progress")
        && routing.oldestPendingActionUptimeNs == stamp("first_progress"), "resident/progress-duplicate-and-regressed-samples-cannot-reset-deadline")
    test.check(progress("younger_receipt", "younger_progress") && routing.oldestPendingActionUptimeNs == stamp("first_progress"),
        "resident/progress-younger-action-does-not-blanket-refresh-oldest-action")
    test.check(progress("oldest_receipt", "second_progress") && routing.oldestPendingActionUptimeNs == stamp("second_progress"),
        "resident/progress-oldest-action-selects-its-own-progress-not-minimum-progress-of-other-actions")
    clock.store(stamp("still_active_now"), ordering: .releasing)
    let activeNow = stamp("still_active_now")
    test.check(!ResidentInputWatchdogDecision.evaluate(now: activeNow, callbackStarted: 0, runLoopProgress: activeNow,
        authorityProgress: activeNow, modal: true, started: true, pendingActionStarted: routing.oldestPendingActionUptimeNs).shouldRelease,
        "resident/progress-real-work-keeps-originally-old-action-live")
    clock.store(stamp("release_now"), ordering: .releasing)
    let releaseNow = stamp("release_now")
    test.check(ResidentInputWatchdogDecision.evaluate(now: releaseNow, callbackStarted: 0, runLoopProgress: releaseNow,
        authorityProgress: releaseNow, modal: true, started: true, pendingActionStarted: routing.oldestPendingActionUptimeNs).reason == "action_deadline",
        "resident/progress-responsive-authority-heartbeat-does-not-hide-stalled-action")
    recorder.complete(stamp("oldest_receipt"))
    test.check(routing.oldestPendingActionUptimeNs == stamp("younger_progress") && routing.health()["pending_action_count"]?.intValue == 1,
        "resident/progress-finishing-oldest-selects-next-unfinished-actions-own-progress")
    test.check(!progress("oldest_receipt", "second_progress") && routing.oldestPendingActionUptimeNs == stamp("younger_progress"),
        "resident/progress-completed-action-cannot-refresh-another-action")
    routing.release(reason: "action_deadline")
    test.check(!progress("younger_receipt", "second_progress") && routing.oldestPendingActionUptimeNs == 0,
        "resident/progress-retired-generation-cannot-restore-modal-deadline")
    recorder.complete(stamp("younger_receipt")); routing.flushForSelfTest()
    test.check(routing.mode == "default" && routing.oldestPendingActionUptimeNs == 0,
        "resident/progress-late-completion-keeps-safety-release-final")
}

private func runResidentSpaceShortcutChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: home + "/leylined/Fixtures/resident/space-shortcut.json"),
          let fixture = try? JSONValue.parse(data), let chord = fixture.at(path: "chord")?.stringValue,
          let base = fixture.at(path: "world")?.objectValue,
          let cases = fixture.at(path: "policy_cases")?.arrayValue, cases.count == 13 else {
        test.check(false, "space-shortcut/fixture-load"); return
    }
    for row in cases {
        let world = JSONValue.object(base.merging(row.at(path: "delta")!.objectValue!))
        let normal = CoreRuntimeServices.inputCanClaim(world, trusted: row.at(path: "trusted")!.boolValue!)
        let control = CoreRuntimeServices.inputCanControlSpace(world, trusted: row.at(path: "trusted")!.boolValue!)
        let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) }, onModeChanged: { _, _, _ in return true })
        routing.setClaimEligibility(management: normal, spaceControl: control)
        routing.setAccepting(normal || control)
        test.check(normal == row.at(path: "normal")!.boolValue! && control == row.at(path: "control")!.boolValue!
            && (routing.route(for: chord) != nil) == control,
            "space-shortcut/" + row.at(path: "name")!.stringValue!)
    }
    let recorder = ResidentTestRecorder()
    let routing = ResidentInputRouting(configuration: configuration,
        dispatchAction: { action, complete in recorder.action(action); complete(0) }, onModeChanged: { _, _, _ in return true })
    routing.setClaimEligibility(management: false, spaceControl: true)
    let blocked = fixture.at(path: "blocked_chords")!.arrayValue!.compactMap(\.stringValue)
    test.check(blocked.allSatisfy { routing.admit(chord: $0) == .passedThrough }
        && routing.health()["active_action_ids"]?.arrayValue == [.string(ResidentInputConstants.spaceToggleActionID)],
        "space-shortcut/off-space-only-toggle-is-claimable")
    _ = routing.admit(chord: chord); _ = routing.admit(chord: chord, isRepeat: true)
    _ = routing.admit(chord: chord, phase: .keyUp); routing.flushForSelfTest()
    test.check(recorder.snapshot().actions.count == 1 && recorder.snapshot().actions.first?.actionId == ResidentInputConstants.spaceToggleActionID,
        "space-shortcut/repeat-and-keyup-toggle-only-once")
    let generation = routing.spaceContextGeneration
    routing.release(reason: "external_context_invalidated")
    let world = JSONValue.object(base)
    test.check(CoreRuntimeServices.spaceShortcutTarget(spaceContextGeneration: generation, currentSpaceContextGeneration: routing.spaceContextGeneration,
        world: world, trusted: true) == nil
        && CoreRuntimeServices.spaceShortcutTarget(spaceContextGeneration: routing.spaceContextGeneration, currentSpaceContextGeneration: routing.spaceContextGeneration,
            world: world, trusted: true)?.spaceKey == "space-A",
        "space-shortcut/changed-context-refuses-old-generation-without-retargeting")
    let clock = fixture.at(path: "stalled_action_clock")!
    let receipt = UInt64(clock.at(path: "receipt_ns")!.intValue!)
    let now = UInt64(clock.at(path: "now_ns")!.intValue!)
    let progress = UInt64(clock.at(path: "progress_ns")!.intValue!)
    let stalled = ResidentProgressRecorder()
    let pending = ResidentInputRouting(configuration: configuration,
        dispatchAction: { action, complete in stalled.dispatch(action, completion: complete) }, onModeChanged: { _, _, _ in return true },
        uptimeProvider: { now })
    _ = pending.admit(chord: chord, receiptUptimeNs: receipt); pending.flushForSelfTest()
    let release = ResidentInputWatchdogDecision.evaluate(now: now, callbackStarted: 0,
        runLoopProgress: progress, authorityProgress: progress,
        modal: pending.hasPendingSpaceControl, started: true, pendingActionStarted: pending.oldestPendingInputUptimeNs)
    test.check(pending.mode == "default" && pending.hasPendingSpaceControl && release.shouldRelease && release.reason == "action_deadline",
        "space-shortcut/stalled-default-mode-toggle-uses-existing-release-deadline")
    let controlGeneration = pending.spaceContextGeneration
    pending.release(reason: "world_unavailable", preserveSpaceControls: true); pending.flushForSelfTest()
    _ = pending.admit(chord: chord, receiptUptimeNs: receipt + 1); pending.flushForSelfTest()
    test.check(stalled.receipt(receipt) != nil && stalled.receipt(receipt + 1) != nil
        && pending.hasPendingSpaceControl && pending.spaceContextGeneration == controlGeneration
        && CoreRuntimeServices.spaceShortcutTarget(spaceContextGeneration: controlGeneration,
            currentSpaceContextGeneration: pending.spaceContextGeneration, world: world, trusted: true) != nil,
        "space-shortcut/modal-claim-release-preserves-distinct-same-space-toggles")
    _ = pending.admit(chord: fixture.at(path: "mode_entry_chord")!.stringValue!, receiptUptimeNs: receipt + 2)
    pending.flushForSelfTest(); stalled.complete(receipt + 2, rc: 4); pending.flushForSelfTest()
    test.check(pending.mode == "default" && pending.hasPendingSpaceControl
        && pending.spaceContextGeneration == controlGeneration,
        "space-shortcut/modal-completion-cannot-clear-an-unfinished-control-deadline")
    pending.release(reason: "action_deadline")
    test.check(!pending.hasPendingSpaceControl, "space-shortcut/context-release-clears-control-deadline")
    routing.setAccepting(false)
    test.check(routing.admit(chord: chord) == .passedThrough && routing.health()["active_action_ids"]?.arrayValue == [],
        "space-shortcut/safety-release-claims-nothing")
}

private func runResidentControlsChecks(home: String, test: inout SelfTest) {
    let path = home + "/leylined/Fixtures/resident/controls-worlds.json"
    guard let data = FileManager.default.contents(atPath: path),
          let worlds = (try? JSONValue.parse(data))?.objectValue else {
        test.check(false, "resident/controls-fixtures-load"); return
    }
    var state = ResidentControlsState()
    state.receive(revision: 1, world: worlds["space_a_on"]!)
    test.check(state.managementEnabled == true && state.currentTarget?.spaceKey == "space-A", "resident/space-a-management-on")
    state.menuWillOpen()
    state.receive(revision: 2, world: worlds["space_b_off"]!)
    test.check(state.currentTarget?.spaceKey == "space-B" && state.managementEnabled == false,
               "resident/space-b-off-independent-of-a-on")
    test.check(state.toggleTarget?.spaceKey == "space-A" && state.toggleManagementEnabled == true,
               "resident/open-menu-freezes-original-space-target-and-setting")
    state.menuDidClose()
    test.check(state.toggleTarget?.spaceKey == "space-B", "resident/menu-close-adopts-latest-revision-target")
    state.receive(revision: 1, world: worlds["space_a_on"]!)
    test.check(state.currentTarget?.spaceKey == "space-B", "resident/control-projection-rejects-stale-revision")
    state.receive(revision: 3, world: worlds["empty_space_a"]!)
    test.check(state.currentTarget?.spaceKey == "space-A", "resident/empty-space-uses-explicit-stable-context")
    state.receive(revision: 4, world: worlds["unknown_space"]!)
    test.check(state.toggleTarget == nil && state.managementEnabled == nil, "resident/unknown-space-refuses-toggle-and-default-on")
    state.receive(revision: 5, world: worlds["counter_identity"]!)
    test.check(state.toggleTarget == nil, "resident/runtime-counters-never-relabeled-stable-identities")
    state.receive(revision: 6, world: worlds["stopped"]!)
    test.check(!state.globallyRunning && state.status == "Stopped", "resident/global-stop-is-state-not-process-exit")
    state.receive(revision: 7, world: worlds["space_a_off_preference"]!)
    test.check(state.managementEnabled == false,
               "resident/authoritative-space-activation-overrides-stale-context-setting")
    var untrusted = ResidentControlsState()
    untrusted.receive(revision: 1, world: .object(["resident_status": .string("Starting"),
        "observation": .object(["world_complete": .bool(false), "world_failure_code": .string("ax_untrusted")])]))
    test.check(untrusted.unavailableReason == "ax_untrusted" && untrusted.currentTarget == nil,
        "resident/initial-untrusted-startup-projects-permission-failure-before-space-reason")
    var members = ResidentControlsState()
    members.receive(revision: 10, world: worlds["space_a_windows"]!)
    test.check(Set(members.windowEntries.map(\.windowID)) == Set([11, 12, 13])
        && members.windowEntries.first(where: { $0.windowID == 12 })?.obscured == true,
        "resident/windows-menu-includes-every-eligible-nested-and-obscured-managed-member")
    members.menuWillOpen()
    members.receive(revision: 11, world: worlds["focus_b_while_menu_a"]!)
    let chosen = members.selectionAction(windowID: 12)
    test.check(chosen?.actionID == "window.select" && chosen?.arguments.at(path: "window_id") == .int(12)
        && chosen?.target.spaceKey == "space-A" && chosen?.expectedRevision == 10
        && members.regutterAction()?.target.spaceKey == "space-A",
        "resident/open-menu-selects-exact-obscured-member-and-regutters-original-space")
    test.check(Set(members.windowEntries.map(\.windowID)) == Set([11, 12, 13]) && members.currentWindows.isEmpty,
        "resident/focus-change-does-not-replace-open-windows-submenu")
    members.receive(revision: 12, world: worlds["space_a_disabled_while_menu"]!)
    test.check(members.selectionAction(windowID: 12) == nil && members.regutterAction() == nil,
        "resident/disabled-original-menu-target-refuses-selection-and-regutter")
    members.receive(revision: 13, world: worlds["buried_reused_while_menu"]!)
    test.check(members.selectionAction(windowID: 12) == nil && members.selectionAction(windowID: 11) != nil,
        "resident/reused-obscured-window-id-refuses-only-its-stale-menu-entry")
    members.receive(revision: 14, world: worlds["unknown_while_menu"]!)
    test.check(members.selectionAction(windowID: 11) == nil && members.regutterAction() == nil,
        "resident/unknown-menu-context-never-infers-a-target")
    members.menuDidClose()
    test.check(members.windowEntries.isEmpty && members.toggleTarget == nil,
        "resident/menu-close-releases-frozen-window-and-space-context")
}

private func runResidentSettingsChecks(test: inout SelfTest) {
    let directory = NSTemporaryDirectory() + "/leyline-resident-settings-" + UUID().uuidString
    let path = directory + "/config/leylined-settings.json"
    let recorder = ResidentSettingsTestRecorder()
    do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    catch { test.check(false, "resident/settings-test-directory-create"); return }
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let events = SettingsEvents(path: path) { recorder.record($0) }
    events.start()
    defer { events.stop() }
    test.check(recorder.latest?.present == false && recorder.latest?.errorCode == nil,
               "resident/settings-absent-baseline-is-explicit")
    test.check(recorder.latest?.desiredRunning == true && recorder.latest?.globalGutterWidth == nil,
        "resident/absent-preferences-default-on-and-use-configured-global-gutter")
    do {
        try ResidentSettingsStore.write(path: path, spacesEnabled: ["space-A": true, "space-B": false], desiredRunning: true)
        let created = recorder.wait { $0.present && $0.spacesEnabled["space-B"] == false }
        test.check(created != nil, "resident/settings-directory-source-sees-first-creation")
        try ResidentSettingsStore.write(path: path, spacesEnabled: ["space-A": false, "space-B": true], desiredRunning: true)
        let replaced = recorder.wait { $0.present && $0.spacesEnabled["space-A"] == false && $0.spacesEnabled["space-B"] == true }
        test.check(replaced != nil, "resident/settings-directory-source-sees-atomic-replacement")
        events.stop()
        try ResidentSettingsStore.write(path: path, spacesEnabled: ["space-A": true], desiredRunning: false)
        events.start()
        test.check(recorder.latest?.desiredRunning == false && recorder.latest?.spacesEnabled["space-A"] == true,
                   "resident/settings-reconnect-rebaselines-missed-writes")
        try ResidentSettingsStore.write(path: path, spacesEnabled: ["space-A": false], desiredRunning: false,
                                        globalGutterWidth: 12)
        test.check(recorder.wait { $0.globalGutterWidth == 12 && !$0.desiredRunning } != nil,
            "resident/global-gutter-override-event-roundtrips-with-desired-off")
        try ResidentSettingsStore.write(path: path, spacesEnabled: ["space-A": true], desiredRunning: true)
        let preserved = ResidentSettingsStore.read(path: path)
        test.check(preserved.globalGutterWidth == 12 && preserved.desiredRunning && preserved.enabled(spaceKey: "space-A"),
            "resident/management-update-preserves-global-gutter-and-roundtrips-desired-on")
        try ResidentSettingsStore.write(path: path, spacesEnabled: preserved.spacesEnabled, desiredRunning: true,
                                        globalGutterWidth: nil)
        test.check(ResidentSettingsStore.read(path: path).globalGutterWidth == nil,
            "resident/explicit-gutter-reset-removes-override-without-space-geometry-preference")
        try Data("invalid".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        test.check(recorder.wait { $0.errorCode == "SETTINGS.INVALID" } != nil,
                   "resident/settings-invalid-write-is-explicit-failure")
        var refusedInvalidUpdate = false
        do { try ResidentSettingsStore.write(path: path, spacesEnabled: [:], desiredRunning: true) }
        catch { refusedInvalidUpdate = true }
        test.check(refusedInvalidUpdate && ResidentSettingsStore.read(path: path).errorCode == "SETTINGS.INVALID",
            "resident/management-update-cannot-overwrite-unreadable-existing-gutter-preferences")
        test.check(events.health()["recurring_poll_count"]?.intValue == 0, "resident/settings-has-no-recurring-state-poll")

        let configurationPath = directory + "/geometry/borders.json"
        let configurationRecorder = ResidentSettingsTestRecorder()
        let configurationEvents = SettingsEvents(path: configurationPath, readSnapshot: { file, generation in
            guard let data = FileManager.default.contents(atPath: file) else {
                return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                    present: false, errorCode: nil, generation: generation)
            }
            guard let value = try? JSONValue.parse(data),
                  let gap = value.at(path: "gap")?.intValue, gap >= 0 else {
                return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                    present: true, errorCode: "GEOMETRY.INVALID", generation: generation)
            }
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                present: true, errorCode: nil, generation: generation, configuration: value)
        }, onSnapshot: { configurationRecorder.record($0) })
        configurationEvents.start()
        defer { configurationEvents.stop() }
        try FileManager.default.createDirectory(atPath: (configurationPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(JSONValue.object(["gap": .int(8)]).canonical().utf8).write(
            to: URL(fileURLWithPath: configurationPath), options: .atomic)
        test.check(configurationRecorder.wait { $0.configuration?.at(path: "gap")?.intValue == 8 } != nil,
                   "resident/shared-directory-engine-delivers-custom-geometry-payload")
        try Data(JSONValue.object(["gap": .int(12)]).canonical().utf8).write(
            to: URL(fileURLWithPath: configurationPath), options: .atomic)
        test.check(configurationRecorder.wait { $0.configuration?.at(path: "gap")?.intValue == 12 } != nil,
                   "resident/custom-geometry-payload-change-is-not-dropped-as-duplicate")
        try Data("invalid".utf8).write(to: URL(fileURLWithPath: configurationPath), options: .atomic)
        test.check(configurationRecorder.wait { $0.errorCode == "GEOMETRY.INVALID" && $0.configuration == nil } != nil,
                   "resident/malformed-custom-config-is-explicit-without-default-on-error")
    } catch { test.check(false, "resident/settings-write-\(error)") }
}
