// Dedicated keyboard-only CGEventTap for the single resident process. Nothing
// in the callback accesses AppKit, AX, layout APIs, filesystem, or subprocesses.
import ApplicationServices
import CoreGraphics
import Foundation
import LeylineModel

struct ResidentInputWatchdogDecision: Equatable, Sendable {
    let shouldRelease: Bool
    let reason: ResidentInputReleaseReason?

    static func evaluate(now: UInt64, callbackStarted: UInt64,
                         runLoopProgress: UInt64, authorityProgress: UInt64,
                         modal: Bool, started: Bool, pendingActionStarted: UInt64 = 0) -> Self {
        let budget = UInt64(ResidentInputConstants.releaseBudgetMilliseconds) * 1_000_000
        func stale(_ timestamp: UInt64) -> Bool { timestamp > 0 && now >= timestamp && now - timestamp >= budget }
        if stale(callbackStarted) { return Self(shouldRelease: true, reason: .callbackDeadline) }
        if started && stale(runLoopProgress) { return Self(shouldRelease: true, reason: .tapRunLoopDeadline) }
        if modal && stale(authorityProgress) { return Self(shouldRelease: true, reason: .authorityDeadline) }
        if modal && stale(pendingActionStarted) { return Self(shouldRelease: true, reason: .actionDeadline) }
        return Self(shouldRelease: false, reason: nil)
    }
}

/// @canonical resident_input -- one keyboard owner. start() installs exactly one
/// tap on a dedicated run loop. stop()/watchdog release it locally and leave the
/// resident process and its mouse-reachable recovery menu alive.
final class ResidentInput: @unchecked Sendable {
    static let retainedActionIds: Set<String> = [
        "nav.focus.west", "nav.focus.south", "nav.focus.north", "nav.focus.east",
        "move.start", "move.off", "move.cancel", "move.execute.auto", "move.execute.swap",
        "move.cursor.west", "move.cursor.south", "move.cursor.north", "move.cursor.east",
        "move.drop", "move.rotate", "move.level.up", "move.level.down",
        "resize.start", "resize.off", "resize.adjust.west", "resize.adjust.south",
        "resize.adjust.north", "resize.adjust.east", "service.restart", ResidentInputConstants.spaceToggleActionID,
    ]

    let routing: ResidentInputRouting
    var inputEpoch: String { routing.inputEpoch }
    private let desiredRunning = ResidentAtomic<Bool>(false)
    private let claimsAllowed = ResidentAtomic<Bool>(false)
    private let spaceControlAllowed = ResidentAtomic<Bool>(false)
    private let workerActive = ResidentAtomic<Bool>(false)
    private let lifecycleGeneration = ResidentAtomic<UInt64>(0)
    private let tapInstalled = ResidentAtomic<Bool>(false)
    private let callbackStarted = ResidentAtomic<UInt64>(0)
    private let runLoopProgress = ResidentAtomic<UInt64>(0)
    private let runLoopHeartbeatPending = ResidentAtomic<Bool>(false)
    private let authorityProgress = ResidentAtomic<UInt64>(0)
    private let watchdogReleaseCount = ResidentAtomic<Int>(0)
    private let osDisabledCount = ResidentAtomic<Int>(0)
    private let rearmCount = ResidentAtomic<Int>(0)
    private let createFailed = ResidentAtomic<Bool>(false)
    private let safetyReleased = ResidentAtomic<Bool>(false)
    private let watchdogQueue = DispatchQueue(label: "leyline.resident.input.watchdog", qos: .userInteractive)
    // Used only by the dedicated tap thread and independent watchdog queue.
    // AppKit/timeline never hold this lock, including stop() and health().
    private let portLock = NSLock()
    private var tap: CFMachPort?
    private var tapLoop: CFRunLoop?
    private var watchdog: DispatchSourceTimer?
    private var thread: Thread?
    private struct HeldChord {
        let chord: String
        let actionId: String
        let generation: UInt64
    }
    private var heldChords: [Int: HeldChord] = [:] // dedicated tap-thread only
    // Stop acknowledgment is a lifecycle edge, not a health poll. Neither the
    // keyboard callback nor watchdog liveness reads take this lifecycle lock.
    private let stoppedCallbacksLock = NSLock()
    private var stoppedCallbacks: [@Sendable () -> Void] = []

    static func load(home: String, supportedActionIds: Set<String> = retainedActionIds,
                     dispatchAction: @escaping ResidentInputActionDispatch,
                     onModeChanged: @escaping @Sendable (String, UInt64, Bool) -> Bool,
                     onFaultRelease: @escaping @Sendable (ResidentInputFaultRelease) -> Void = { _ in }) throws -> ResidentInput {
        let decode = try KeyDecode(fixtureData: Data(contentsOf: URL(
            fileURLWithPath: ResidentLayout.keymap("decode-us", home: home))))
        guard decode.droppedRows.isEmpty else {
            throw ResidentInputError(code: "INPUT.DECODE_INVALID", message: "Keyboard decode contains rejected rows")
        }
        let fsm = try ModeFSM(manifestData: Data(contentsOf: URL(fileURLWithPath: ResidentLayout.keymap("modes", home: home))))
        let configuration = try ResidentInputConfiguration(
            decode: decode, fsm: fsm,
            globalData: Data(contentsOf: URL(fileURLWithPath: ResidentLayout.keymap("global", home: home))),
            supportedActionIds: supportedActionIds)
        return ResidentInput(configuration: configuration,
                             dispatchAction: dispatchAction, onModeChanged: onModeChanged, onFaultRelease: onFaultRelease)
    }

    init(configuration: ResidentInputConfiguration,
         dispatchAction: @escaping ResidentInputActionDispatch,
         onModeChanged: @escaping @Sendable (String, UInt64, Bool) -> Bool,
         onFaultRelease: @escaping @Sendable (ResidentInputFaultRelease) -> Void = { _ in }) {
        routing = ResidentInputRouting(configuration: configuration,
                                       dispatchAction: dispatchAction, onModeChanged: onModeChanged, onFaultRelease: onFaultRelease)
    }

    /// Installs the keyboard tap only on an explicit lifecycle start. Returns
    /// false if an earlier start is active or permission/tap creation fails.
    func start() -> Bool {
        // stop is asynchronous so a wedged run loop never blocks mouse recovery.
        // Until teardown finishes it must not admit a second tap/thread owner.
        guard !workerActive.load(ordering: .acquiring), !tapInstalled.load(ordering: .acquiring) else { return false }
        guard !desiredRunning.exchange(true, ordering: .acquiringAndReleasing) else { return false }
        lifecycleGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        createFailed.store(false, ordering: .releasing)
        safetyReleased.store(false, ordering: .releasing)
        runLoopHeartbeatPending.store(false, ordering: .releasing)
        routing.setAccepting(false)
        let now = DispatchTime.now().uptimeNanoseconds
        runLoopProgress.store(now, ordering: .releasing)
        authorityProgress.store(now, ordering: .releasing)
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread { [self] in runTap(ready: ready) }
        worker.name = "leylined-keyboard-tap"
        thread = worker
        workerActive.store(true, ordering: .releasing)
        worker.start()
        // This bounds activation, not keyboard delivery. A startup failure leaves
        // no tap and remains visible in health instead of pretending to be on.
        guard ready.wait(timeout: .now() + .milliseconds(ResidentInputConstants.tapActivationTimeoutMilliseconds)) == .success,
              tapInstalled.load(ordering: .acquiring) else {
            stop()
            return false
        }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(ResidentInputConstants.watchdogCadenceMilliseconds),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
        return true
    }

    /// Safety release does not join any possibly halted worker or invoke AppKit.
    func stop(onStopped: @escaping @Sendable () -> Void = {}) {
        stoppedCallbacksLock.lock()
        stoppedCallbacks.append(onStopped)
        stoppedCallbacksLock.unlock()
        let stoppedGeneration = lifecycleGeneration.load(ordering: .acquiring)
        desiredRunning.store(false, ordering: .releasing)
        claimsAllowed.store(false, ordering: .releasing)
        spaceControlAllowed.store(false, ordering: .releasing)
        routing.setClaimEligibility(management: false, spaceControl: false)
        routing.setAccepting(false)
        routing.release(reason: .globalStop)
        watchdog?.cancel()
        watchdog = nil
        // Port disable is serialized with any re-enable on the independent
        // watchdog queue. Claim-nothing above is already synchronous and local.
        watchdogQueue.async { [self] in
            guard stoppedGeneration == lifecycleGeneration.load(ordering: .acquiring) else { return }
            portLock.lock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let tapLoop { CFRunLoopStop(tapLoop); CFRunLoopWakeUp(tapLoop) }
            portLock.unlock()
            if !workerActive.load(ordering: .acquiring) { notifyStopped() }
        }
    }

    /// Called only when the authoritative executor actually completes progress.
    /// A fake periodic stamp would conceal the very stall this token detects.
    func noteAuthorityProgress() {
        authorityProgress.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
    }

    /// Effect ACK/new-target evidence refreshes only its exact unfinished input
    /// action. Authority heartbeats and provisional outcomes never call this.
    @discardableResult
    func noteActionProgress(receiptUptimeNs: UInt64, generation: UInt64, progressUptimeNs: UInt64) -> Bool {
        routing.noteActionProgress(receiptUptimeNs: receiptUptimeNs, generation: generation,
            progressUptimeNs: progressUptimeNs)
    }

    /// Context invalidation releases bare modal keys immediately, while the
    /// mode notification crosses the existing bounded delivery lane afterward.
    /// It does not wait for AppKit, the authoritative executor, or landed AX.
    func releaseModal(reason: ResidentInputReleaseReason) {
        routing.release(reason: reason, preserveSpaceControls: spaceControlAllowed.load(ordering: .acquiring))
    }

    /// The authoritative world gate must positively allow claims. A running
    /// tap on an incomplete/unknown/OFF world remains a pass-through monitor.
    func setClaimsAllowed(_ allowed: Bool, spaceControlAllowed controlAllowed: Bool = false, reason: ResidentInputReleaseReason = .worldUnavailable) {
        let previous = claimsAllowed.exchange(allowed, ordering: .acquiringAndReleasing)
        let priorControl = spaceControlAllowed.exchange(controlAllowed, ordering: .acquiringAndReleasing)
        if priorControl && !controlAllowed { routing.invalidateSpaceContext() }
        routing.setClaimEligibility(management: allowed, spaceControl: controlAllowed)
        if !allowed {
            routing.setAccepting(false)
            if previous || routing.mode != "default" { routing.release(reason: reason, preserveSpaceControls: controlAllowed) }
        }
        if desiredRunning.load(ordering: .acquiring), tapInstalled.load(ordering: .acquiring),
           !safetyReleased.load(ordering: .acquiring) {
            routing.setAccepting(allowed || controlAllowed)
        }
    }

    func health() -> JSONObject {
        var value = routing.health()
        value["tap_installed"] = .bool(tapInstalled.load(ordering: .acquiring))
        value["desired_running"] = .bool(desiredRunning.load(ordering: .acquiring))
        value["claims_allowed"] = .bool(claimsAllowed.load(ordering: .acquiring))
        value["space_control_allowed"] = .bool(spaceControlAllowed.load(ordering: .acquiring))
        value["tap_create_failed"] = .bool(createFailed.load(ordering: .acquiring))
        value["safety_released"] = .bool(safetyReleased.load(ordering: .acquiring))
        value["watchdog_release_count"] = .int(Int64(watchdogReleaseCount.load(ordering: .relaxed)))
        value["os_disabled_count"] = .int(Int64(osDisabledCount.load(ordering: .relaxed)))
        value["rearm_count"] = .int(Int64(rearmCount.load(ordering: .relaxed)))
        value["run_loop_heartbeat_pending"] = .bool(runLoopHeartbeatPending.load(ordering: .acquiring))
        value["watchdog_cadence_ms"] = .int(Int64(ResidentInputConstants.watchdogCadenceMilliseconds))
        value["watchdog_release_budget_ms"] = .int(Int64(ResidentInputConstants.releaseBudgetMilliseconds))
        value["release_ceiling_ms"] = .int(Int64(ResidentInputConstants.releaseCeilingMilliseconds))
        return value
    }

    #if LEYLINE_BUILD_TESTS
    @discardableResult
    func inject(chord: String, keyUp: Bool = false) -> ResidentInputAdmission {
        routing.admit(chord: chord, phase: keyUp ? .keyUp : .keyDown)
    }

    #endif

    static let keyboardEventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    #if LEYLINE_BUILD_TESTS
    /// Drives the exact no-tap-safe deadline handler without installing a tap.
    /// Tests can block action delivery and still prove synchronous claim release.
    func driveWatchdogDecisionForSelfTest(_ decision: ResidentInputWatchdogDecision) {
        applyWatchdogDecision(decision)
    }

    #endif

    private func runTap(ready: DispatchSemaphore) {
        defer {
            workerActive.store(false, ordering: .releasing)
            notifyStopped()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: Self.keyboardEventMask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ResidentInput>.fromOpaque(pointer).takeUnretainedValue().receive(type: type, event: event)
            }, userInfo: context),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            createFailed.store(true, ordering: .releasing)
            desiredRunning.store(false, ordering: .releasing)
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()
        portLock.lock()
        tap = created
        tapLoop = loop
        CFRunLoopAddSource(loop, source, .commonModes)
        let run = desiredRunning.load(ordering: .acquiring)
        CGEvent.tapEnable(tap: created, enable: run)
        tapInstalled.store(run, ordering: .releasing)
        routing.setAccepting(run && (claimsAllowed.load(ordering: .acquiring) || spaceControlAllowed.load(ordering: .acquiring)))
        portLock.unlock()
        ready.signal()
        if run { CFRunLoopRun() }
        routing.setAccepting(false)
        portLock.lock()
        CGEvent.tapEnable(tap: created, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(created)
        tap = nil
        tapLoop = nil
        tapInstalled.store(false, ordering: .releasing)
        portLock.unlock()
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            osDisabledCount.wrappingAdd(1, ordering: .relaxed)
            // No main-thread or action-queue lock. This gate prevents an OS
            // callback re-enabling after global stop or watchdog release.
            portLock.lock()
            if desiredRunning.load(ordering: .acquiring), !safetyReleased.load(ordering: .acquiring), let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            portLock.unlock()
            return Unmanaged.passUnretained(event)
        }
        guard type != .flagsChanged, desiredRunning.load(ordering: .acquiring),
              routing.isAccepting else { return Unmanaged.passUnretained(event) }
        let now = DispatchTime.now().uptimeNanoseconds
        let spaceContext = routing.spaceContextGeneration
        callbackStarted.store(now, ordering: .releasing)
        defer { callbackStarted.store(0, ordering: .releasing) }
        runLoopProgress.store(now, ordering: .releasing)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            guard let held = heldChords.removeValue(forKey: code) else { return Unmanaged.passUnretained(event) }
            ResidentPerformanceTrace.shared.record("key_up", fields: ["origin": .string("input"), "input_boundary": .string("cg_session_tap"),
                "hardware_origin_verified": .bool(false),
                "action_id": .string(held.actionId), "chord": .string(held.chord),
                "input_generation": .int(Int64(clamping: held.generation)),
                "cg_event_timestamp_ns": .int(Int64(clamping: event.timestamp))], timestamp: now, nonblocking: true)
            if held.actionId.hasPrefix(ResidentActionIDs.resizeAdjustPrefix), held.generation == routing.generation {
                _ = routing.admit(chord: held.chord, phase: .keyUp, receiptUptimeNs: now)
            }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if repeated, heldChords[code]?.actionId == ResidentInputConstants.spaceToggleActionID { return nil }
        var flags: KeyDecode.Flags = []
        if event.flags.contains(.maskCommand) { flags.insert(.cmd) }
        if event.flags.contains(.maskControl) { flags.insert(.ctrl) }
        if event.flags.contains(.maskAlternate) { flags.insert(.alt) }
        if event.flags.contains(.maskShift) { flags.insert(.shift) }
        if event.flags.contains(.maskSecondaryFn) { flags.insert(.fn) }
        guard let chord = routing.configuration.decode.chord(keyCode: code, flags: flags) else {
            return Unmanaged.passUnretained(event)
        }
        let generation = routing.generation
        guard let route = routing.route(for: chord),
              routing.admit(chord: chord, receiptUptimeNs: now, isRepeat: repeated, spaceContextGeneration: spaceContext) == .claimed else {
            return Unmanaged.passUnretained(event)
        }
        heldChords[code] = HeldChord(chord: chord, actionId: route.actionId, generation: generation)
        ResidentPerformanceTrace.shared.record("tap_receipt", fields: ["origin": .string("input"), "input_boundary": .string("cg_session_tap"),
                "hardware_origin_verified": .bool(false),
            "action_id": .string(route.actionId), "chord": .string(chord),
            "input_generation": .int(Int64(clamping: generation)),
            "cg_event_timestamp_ns": .int(Int64(clamping: event.timestamp))], timestamp: now, nonblocking: true)
        return nil
    }

    private func watchdogTick() {
        guard desiredRunning.load(ordering: .acquiring) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let decision = ResidentInputWatchdogDecision.evaluate(
            now: now, callbackStarted: callbackStarted.load(ordering: .acquiring),
            runLoopProgress: runLoopProgress.load(ordering: .acquiring),
            authorityProgress: authorityProgress.load(ordering: .acquiring),
            modal: routing.mode != "default" || routing.hasPendingSpaceControl, started: tapInstalled.load(ordering: .acquiring),
            pendingActionStarted: routing.oldestPendingInputUptimeNs)
        applyWatchdogDecision(decision)
        portLock.lock()
        if let loop = tapLoop,
           !runLoopHeartbeatPending.exchange(true, ordering: .acquiringAndReleasing) {
            let heartbeatGeneration = lifecycleGeneration.load(ordering: .acquiring)
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, heartbeatGeneration == self.lifecycleGeneration.load(ordering: .acquiring) else { return }
                self.runLoopProgress.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
                self.runLoopHeartbeatPending.store(false, ordering: .releasing)
            }
            CFRunLoopWakeUp(loop)
        }
        let runProgress = runLoopProgress.load(ordering: .acquiring)
        let authority = authorityProgress.load(ordering: .acquiring)
        // Recovery requires fresh progress from BOTH lanes. Default-mode idle
        // cannot disguise a stuck authority, and no tap teardown loses re-arm.
        if safetyReleased.load(ordering: .acquiring), now >= runProgress, now >= authority,
           now - runProgress < ResidentInputConstants.rearmFreshnessNanoseconds,
           now - authority < ResidentInputConstants.rearmFreshnessNanoseconds,
           desiredRunning.load(ordering: .acquiring), let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            routing.setAccepting(claimsAllowed.load(ordering: .acquiring) || spaceControlAllowed.load(ordering: .acquiring))
            safetyReleased.store(false, ordering: .releasing)
            rearmCount.wrappingAdd(1, ordering: .relaxed)
        }
        portLock.unlock()
    }

    private func applyWatchdogDecision(_ decision: ResidentInputWatchdogDecision) {
        guard decision.shouldRelease,
              !safetyReleased.exchange(true, ordering: .acquiringAndReleasing) else { return }
        routing.setAccepting(false)
        routing.release(reason: decision.reason ?? .watchdogDeadline)
        watchdogReleaseCount.wrappingAdd(1, ordering: .relaxed)
        portLock.lock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        portLock.unlock()
    }

    private func notifyStopped() {
        stoppedCallbacksLock.lock()
        let callbacks = stoppedCallbacks
        stoppedCallbacks.removeAll()
        stoppedCallbacksLock.unlock()
        for callback in callbacks { callback() }
    }
}
