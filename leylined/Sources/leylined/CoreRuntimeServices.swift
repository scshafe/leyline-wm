import AppKit
import ApplicationServices
import Darwin
import Foundation
import LeylineModel

/// Permanent modules of the same resident process. The controls survive global
/// OFF; tap teardown acknowledgment, rather than a health poll, drives restart.
final class CoreRuntimeServices: @unchecked Sendable {
    private let server: CoreServer
    private let observationQueue: DispatchQueue
    private let lifecycleQueue = DispatchQueue(label: "leylined.lifecycle")
    private let feed: ProjectionInputFeed
    private let snapshots: TargetedProjectionSnapshot
    private let renderer: BorderRenderer?
    private let actions: ResidentActionController
    private let trustedProvider: @Sendable () -> Bool
    private let maintenance = ResidentMaintenance()
    private let controlRequests = ResidentControlRequests()
    private let inputCapabilityGate = ResidentControlTimeout.CapabilityGate()
    private let startupSeedGate: ResidentStartupSeedGate
    private let readinessLock = NSLock()
    private var readinessWorld: JSONValue = .null
    private var inputSpaceTarget: ResidentSpaceTarget? // readinessLock only
    private var inputSpaceObserverEpoch: String? // readinessLock only
    private struct ControlDeadline { let admissionSequence: UInt64; let uptimeNs: UInt64; let expire: @Sendable () -> Void }
    private let controlDeadlineLock = NSLock()
    private var controlDeadlineTimer: DispatchSourceTimer?
    private var controlDeadlineJobs: [String: ControlDeadline] = [:]
    private typealias LifecycleCompletion = @Sendable (WmStatus, String?, JSONObject) -> Void
    private let modeEpoch = UUID().uuidString
    private var input: ResidentInput?
    private var inputStopBarrier: ResidentInputStopBarrier!
    private let inputStartAttempted = ResidentAtomic<Bool>(false)
    @MainActor private var controls: ResidentControls?
    private var controlsMailbox: CorePresentationMailbox!
    private var faultNoticeMailbox: ResidentInputFaultMailbox?
    private var settings: SettingsEvents?
    private var geometryEvents: SettingsEvents?
    private var heartbeat: DispatchSourceTimer?
    private let lifecycleGeneration = ResidentAtomic<UInt64>(0)
    private let modeLock = NSLock()
    private var modeSequence: Int64 = 0
    private var settingsFaulted = false
    private var desiredRunning = true // lifecycleQueue only

    init(server: CoreServer, home: String,
         observationQueue: DispatchQueue, feed: ProjectionInputFeed,
         snapshots: TargetedProjectionSnapshot, renderer: BorderRenderer?,
         actions: ResidentActionController, trustedProvider: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) throws {
        self.server = server; self.observationQueue = observationQueue
        self.feed = feed; self.snapshots = snapshots; self.renderer = renderer; self.actions = actions; self.trustedProvider = trustedProvider
        startupSeedGate = ResidentStartupSeedGate()
        readinessWorld = server.worldState
        do {
            let initial = ResidentSettingsStore.read(path: ResidentSettingsStore.defaultPath())
            desiredRunning = initial.errorCode == nil && initial.desiredRunning
            settingsFaulted = initial.errorCode != nil
            _ = server.applyWorldDelta(["event": .string("management_preference_loaded"),
                "desired_running": initial.errorCode == nil ? .bool(initial.desiredRunning) : .null])
            if !desiredRunning {
                _ = server.applyWorldDelta(["event": .string("settings_boot_disabled"), "management_enabled": .bool(false),
                    "resident_status": .string(initial.errorCode == nil ? "Stopped" : "Recovery needed"),
                    "resident_unavailable_reason": initial.errorCode.map(JSONValue.string) ?? .null])
            }
        }
        do {
            input = try ResidentInput.load(home: home, dispatchAction: { [weak self] action, completion in
                guard let self else { completion(4); return }
                if action.actionId == "service.restart" {
                    self.lifecycle(.restart); completion(0)
                } else if action.actionId == ResidentInputConstants.spaceToggleActionID {
                    self.toggleFocusedSpace(action, completion: completion)
                } else {
                    if ResidentActionIDs.cancelling.contains(action.actionId) {
                        self.actions.invalidate(cause: "cancel")
                    }
                    self.actions.dispatch(action, completion: completion)
                }
            }, onModeChanged: { [weak self] mode, generation, resetsInteraction in
                guard let self, let input = self.input, input.routing.generation == generation else { return false }
                self.modeLock.lock()
                let sequence = self.modeSequence + 1
                let result = self.server.applyModeFrame(ModeFrame(type: .changed, epoch: self.modeEpoch,
                    sequence: sequence, mode: mode, resetsInteraction: resetsInteraction, inputGeneration: generation), commitGuard: { [weak input] in
                        input?.routing.generation == generation ? nil : "input_generation_released"
                    })
                if result.status == .accepted { self.modeSequence = sequence }
                self.modeLock.unlock()
                guard result.status == .accepted else { return false }
                if mode == "default" { self.actions.invalidate(cause: "cancel") }
                let ready = input.health()["tap_installed"]?.boolValue == true
                self.server.updateModeSubscriptionHealth(ModeHealth(connected: ready, ready: ready,
                    epoch: self.modeEpoch, sequence: sequence, degradedReason: ready ? nil : "resident_input_unavailable"))
                self.server.updateResidentHealth(["input_generation": .int(Int64(clamping: generation)), "mode_source": .string("in_process")])
                return true
            }, onFaultRelease: { [weak self] event in self?.faultNoticeMailbox?.submit(event) })
            server.updateResidentHealth(["mode_source": .string("in_process")])
            actions.setInputGenerationReader { [weak input] in input?.routing.generation }
            actions.setInputProgressHandler { [weak input] receipt, generation, progress in
                _ = input?.noteActionProgress(receiptUptimeNs: receipt, generation: generation, progressUptimeNs: progress)
            }
            _ = server.applyModeFrame(ModeFrame(type: .snapshot, epoch: modeEpoch, sequence: 0, mode: "default", resetsInteraction: true))
        }
        inputStopBarrier = ResidentInputStopBarrier(queue: lifecycleQueue,
            stopPort: { [input, inputCapabilityGate] acknowledge in
                if let input { inputCapabilityGate.perform { input.stop(onStopped: acknowledge) } } else { acknowledge() }
            }, didStop: { [input, server] in
                if let input { server.updateResidentHealth(["input": .object(input.health()), "input_started": .bool(false)]) }
            }, overflow: { [server] in
                server.updateResidentHealth(["input_unavailable_reason": .string("input_stop_waiter_overflow")])
            })
        do {
            let path = ResidentLayout.borders(config: ResidentPaths.config())
            geometryEvents = SettingsEvents(path: path, readSnapshot: Self.readGeometry,
                onSnapshot: { [weak self] snapshot in self?.geometryChanged(snapshot) })
        }
        do {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "leylined.control.completion.deadline"))
            timer.setEventHandler { [weak self] in self?.expireControlDeadlines() }
            timer.schedule(deadline: .distantFuture, repeating: .never)
            controlDeadlineTimer = timer
            timer.resume()
            MainActor.assumeIsolated {
                controls = ResidentControls(onToggleSpace: { [weak self] target in self?.toggleSpace(target) },
                    onLifecycle: { [weak self] action in self?.lifecycle(action) },
                    onAction: { [weak self] action in self?.menuAction(action) })
                controls?.start()
            }
            controlsMailbox = CorePresentationMailbox(execute: { DispatchQueue.main.async(execute: $0) },
                present: { [weak self] snapshot in
                    MainActor.assumeIsolated {
                        guard let self, let controls = self.controls else { return }
                        controls.receive(revision: snapshot.revision, world: snapshot.world)
                        server.updateResidentHealth(["controls": .object(controls.health())])
                    }
                })
            if let input {
                faultNoticeMailbox = ResidentInputFaultMailbox(inputEpoch: input.inputEpoch,
                    execute: { DispatchQueue.main.async(execute: $0) }, deliver: { [weak self, weak input] event in
                        guard let self, let input else { return }
                        MainActor.assumeIsolated {
                            self.controls?.receiveFaultRelease(event, currentInputEpoch: input.inputEpoch,
                                currentInputGeneration: input.routing.generation)
                        }
                    })
            }
            settings = SettingsEvents(onSnapshot: { [weak self] snapshot in self?.settingsChanged(snapshot) })
            server.configureResidentControls { [weak self] request in
                self?.handleControl(request) ?? ResidentReply.refused(requestID: request["request_id"] ?? .null,
                    reason: "resident_control_unavailable")
            }
        }
    }

    private func handleControl(_ request: JSONObject) -> JSONValue {
        if request["op"]?.stringValue == "control-result" {
            return controlRequests.result(requestID: request["request_id"]?.stringValue ?? "", revision: server.currentRevision)
        }
        let admitted = controlRequests.admit(request, revision: server.currentRevision)
        guard let intent = admitted.intent else { return admitted.result }
        let expire: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            ResidentControlTimeout.expire(requestID: intent.requestID,
                expectedAdmissionSequence: intent.admissionSequence,
                revision: admitted.result.at(path: "revision")?.intValue.map(UInt64.init) ?? 0,
                requests: self.controlRequests, lifecycleGeneration: self.lifecycleGeneration,
                capabilityGate: self.inputCapabilityGate,
                onTerminal: { self.cancelControlDeadline(intent.requestID, admissionSequence: intent.admissionSequence) },
                releaseClaims: { self.input?.setClaimsAllowed(false, reason: .residentControlTimeout) },
                cancelMaintenance: { _ = self.maintenance.cancel(requestID: intent.requestID) },
                enqueue: { self.lifecycleQueue.async(execute: $0) },
                continueStopping: { [weak self] timeout in self?.stopTimedOutControl(timeout) })
        }
        controlDeadlineLock.lock()
        guard controlDeadlineJobs.count < ResidentControlRequests.resultLimit else {
            controlDeadlineLock.unlock()
            finishControl(intent.requestID, admissionSequence: intent.admissionSequence, status: .refused, reason: "resident_control_deadline_limit")
            return controlRequests.result(requestID: intent.requestID, revision: server.currentRevision)
        }
        let current = controlRequests.result(requestID: intent.requestID, revision: 0)
        guard current.at(path: "phase")?.stringValue == "queued",
              current.at(path: "control_admission_sequence")?.intValue == Int64(intent.admissionSequence) else {
            controlDeadlineLock.unlock(); return current
        }
        controlDeadlineJobs[intent.requestID] = ControlDeadline(admissionSequence: intent.admissionSequence,
            uptimeNs: DispatchTime.now().uptimeNanoseconds
            + ResidentControlRequests.completionDeadlineNs, expire: expire)
        scheduleControlDeadlineLocked()
        controlDeadlineLock.unlock()
        lifecycleQueue.async { [self] in
            if let expected = intent.expectedRevision, expected != server.currentRevision {
                finishControl(intent.requestID, admissionSequence: intent.admissionSequence,
                    status: .refused, reason: "expected_revision_mismatch"); return
            }
            let action: ResidentLifecycleAction
            switch intent.action {
            case .start: action = .start
            case .stop: action = .stop
            case .restart: action = .restart
            case .reset: action = intent.hard ? .hardReset : .restart
            }
            let resume: Bool? = (intent.action == .reset || intent.action == .restart)
                ? (intent.resume ?? desiredRunning) : intent.resume
            performLifecycle(action, resumeOverride: resume, controlRequestID: intent.requestID,
                controlAdmissionSequence: intent.admissionSequence,
                persistDesired: action == .stop ? false : action == .start ? true : resume ?? desiredRunning) { [weak self] status, reason, details in
                self?.finishControl(intent.requestID, admissionSequence: intent.admissionSequence,
                    status: status, reason: reason, details: details)
            }
        }
        return admitted.result
    }

    private func finishControl(_ id: String, admissionSequence: UInt64, status: WmStatus, reason: String?, details: JSONObject = [:]) {
        guard let result = controlRequests.complete(requestID: id, expectedAdmissionSequence: admissionSequence,
            status: status, revision: server.currentRevision,
            reason: reason, details: details) else { return }
        cancelControlDeadline(id, admissionSequence: admissionSequence)
        _ = server.applyWorldDelta(["event": .string("resident_control_result"), "control_last_result": result], commitGuard: { [controlRequests] in
            controlRequests.result(requestID: id, revision: 0) == result ? nil : "resident_control_result_retired"
        })
    }

    private func cancelControlDeadline(_ id: String, admissionSequence: UInt64) {
        controlDeadlineLock.lock()
        if controlDeadlineJobs[id]?.admissionSequence == admissionSequence { controlDeadlineJobs.removeValue(forKey: id) }
        scheduleControlDeadlineLocked(); controlDeadlineLock.unlock()
    }

    private func scheduleControlDeadlineLocked() {
        let next = controlDeadlineJobs.values.map(\.uptimeNs).min()
        controlDeadlineTimer?.schedule(deadline: next.map { DispatchTime(uptimeNanoseconds: $0) } ?? .distantFuture,
            repeating: .never)
    }

    private func expireControlDeadlines() {
        let now = DispatchTime.now().uptimeNanoseconds
        controlDeadlineLock.lock()
        let expired = controlDeadlineJobs.filter { $0.value.uptimeNs <= now }
        for id in expired.keys { controlDeadlineJobs.removeValue(forKey: id) }
        scheduleControlDeadlineLocked(); controlDeadlineLock.unlock()
        for deadline in expired.values { deadline.expire() }
    }

    /// This is continuation of the timeout's existing fence, not a new stop
    /// intent. A later admitted control wins before it even begins on this lane.
    private func stopTimedOutControl(_ timeout: ResidentControlTimeoutResolution) {
        let current: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return ResidentControlTimeout.isCurrent(timeout, requests: self.controlRequests, lifecycleGeneration: self.lifecycleGeneration)
        }
        guard current() else { return }
        desiredRunning = false
        actions.invalidate(cause: "cancel")
        let stopped = server.applyWorldDelta(["event": .string("global_stop"), "management_enabled": .bool(false),
            "resident_starting": .bool(false), "resident_running": .bool(false), "resident_status": .string("Stopped"),
            "mode": .string("default"), "control_last_result": timeout.result], commitGuard: {
                current() ? nil : "resident_control_timeout_retired"
            })
        guard stopped.status == .accepted, current() else { return }
        inputStopBarrier.stop(resume: { [weak self] in
            guard let self, current() else { return }
            self.stopProjections(whileCurrent: { current() })
        })
    }

    func start() {
        let startup = input == nil ? nil : startupSeedGate.arm(generation: lifecycleGeneration.load(ordering: .acquiring),
            observationEpoch: server.observationEpoch)
        geometryEvents?.start()
        settings?.start()
        if let input {
            lifecycleQueue.async { [self] in
                guard let startup, desiredRunning, startupSeedGate.isCurrent(startup,
                    generation: lifecycleGeneration.load(ordering: .acquiring), observationEpoch: server.observationEpoch),
                    server.worldState.managementEnabled else { return }
                _ = server.applyWorldDelta(["event": .string("resident_starting"), "resident_starting": .bool(true),
                    "resident_running": .bool(false), "resident_status": .string("Starting")])
            }
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "leylined.authority.liveness"))
            source.schedule(deadline: .now(), repeating: .milliseconds(50))
            source.setEventHandler { [weak self, weak input] in
                guard self?.server.probeAuthority() == true else { return }
                input?.noteAuthorityProgress()
            }
            heartbeat = source
            source.resume()
        }
    }

    func receive(_ snapshot: CoreCommittedSnapshot) {
        let controlEligible = !startupSeedGate.blocksClaims && Self.inputCanControlSpace(snapshot.world, trusted: trustedProvider())
        let target = controlEligible ? ResidentSpaceTarget.focused(in: snapshot.world) : nil
        let epoch = snapshot.world.at(path: "observer_epoch")?.stringValue
        readinessLock.withLock {
            let changed = inputSpaceTarget != target || inputSpaceObserverEpoch != epoch
            // Publish the new target only after retiring admission from the old
            // Space. The callback uses atomics and never takes this lock.
            if changed {
                input?.routing.invalidateSpaceContext()
                if inputSpaceTarget != nil { input?.releaseModal(reason: .externalContextInvalidated) }
            }
            inputSpaceTarget = target; inputSpaceObserverEpoch = epoch; readinessWorld = snapshot.world
        }
        actions.receive(snapshot)
        if let startup = startupSeedGate.observe(snapshot, generation: lifecycleGeneration.load(ordering: .acquiring),
            observationEpoch: server.observationEpoch) {
            lifecycleQueue.async { [self] in
                guard desiredRunning, startupSeedGate.isCurrent(startup,
                    generation: lifecycleGeneration.load(ordering: .acquiring), observationEpoch: server.observationEpoch) else { return }
                reconcileBaseline(generation: startup.generation, completion: nil, startup: startup)
            }
        }
        let eligible = !startupSeedGate.blocksClaims && Self.inputCanClaim(snapshot.world, trusted: trustedProvider())
        if eligible || controlEligible, let input, input.health()["tap_installed"]?.boolValue != true,
           !inputStartAttempted.exchange(true, ordering: .acquiringAndReleasing) {
            lifecycleQueue.async { [self] in
                // Deliberately NOT worldReady: a guard failure here leaves inputStartAttempted
                // latched until a control stop/restart, so this recheck must stay exactly as
                // narrow as it was (geometry is gated by inputCanClaim, not by tap startup).
                guard desiredRunning, trustedProvider(), server.worldState.managementEnabled,
                      server.worldState.at(path: "persistence_available")?.boolValue != false,
                      server.worldState.worldComplete == true else { return }
                _ = startInput(input)
            }
        }
        inputCapabilityGate.perform { input?.setClaimsAllowed(eligible, spaceControlAllowed: controlEligible, reason: .worldOrFocusedSpaceUnavailable) }
        if let input, input.routing.mode != "default",
           Self.committedDefaultCanReleaseInput(snapshot.world, currentInputGeneration: input.routing.generation) {
            input.releaseModal(reason: .committedInteractionContextInvalidated)
        }
        input?.noteAuthorityProgress()
        controlsMailbox?.submit(snapshot)
        var health: JSONObject = ["effects": actions.health]
        if let input { health["input"] = .object(input.health()) }
        server.updateResidentHealth(health)
    }

    /// Default mode feedback needs current input authority or a genuine
    /// observer/lifecycle invalidation. An older default history/focus revision
    /// cannot cancel a newer optimistic entry waiting to publish its mode.
    static func committedDefaultCanReleaseInput(_ world: JSONValue, currentInputGeneration: UInt64) -> Bool {
        guard world.at(path: "mode") == .string("default") else { return false }
        let published = world.at(path: "mode_input_generation")?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
        if world.at(path: "event") != .string("mode_changed"), world.at(path: "interaction_invalidated") == .bool(true) {
            return true
        }
        return published.map { $0 >= currentInputGeneration } ?? false
    }

    /// Stop observation on its lane, then unmount the projection on main and publish
    /// its health, re-checking `isCurrent` at every hop; `then` runs on main afterwards.
    private func stopProjections(whileCurrent isCurrent: @escaping @Sendable () -> Bool,
                                 then completion: (@Sendable (CoreRuntimeServices) -> Void)? = nil) {
        observationQueue.async { [weak self] in
            guard let self, isCurrent() else { return }
            self.feed.stop(); self.snapshots.stop()
            DispatchQueue.main.async { [weak self] in
                guard let self, isCurrent() else { return }
                MainActor.assumeIsolated {
                    self.renderer?.unmount()
                    if let renderer = self.renderer { self.server.updateProjectionHealth(renderer.health) }
                }
                completion?(self)
            }
        }
    }

    /// The four facts every readiness decision shares: a complete world, management
    /// on, durable persistence and valid geometry. Each caller adds its own terms.
    static func worldReady(_ world: JSONValue) -> Bool {
        world.worldComplete == true && world.managementEnabled
            && world.at(path: "persistence_available")?.boolValue != false
            && world.at(path: "geometry_available")?.boolValue != false
    }

    static func inputCanControlSpace(_ world: JSONValue, trusted: Bool) -> Bool {
        guard trusted, worldReady(world),
              world.at(path: "desired_running")?.boolValue != false,
              world.at(path: "resident_starting")?.boolValue != true,
              let target = ResidentSpaceTarget.focused(in: world), target.isVisible(in: world),
              ResidentSpaceTarget.focusedContext(in: world)?.at(path: "space_identity_available")?.boolValue == true,
              ResidentSpaceTarget.focusedContext(in: world)?.at(path: "space_visible")?.boolValue == true else { return false }
        return true
    }

    static func spaceShortcutTarget(spaceContextGeneration: UInt64, currentSpaceContextGeneration: UInt64?,
                                    world: JSONValue, trusted: Bool) -> ResidentSpaceTarget? {
        guard currentSpaceContextGeneration == spaceContextGeneration, inputCanControlSpace(world, trusted: trusted) else { return nil }
        return ResidentSpaceTarget.focused(in: world)
    }

    private func toggleFocusedSpace(_ action: ResidentInputAction, completion: @escaping @Sendable (Int) -> Void) {
        // This is the world that supplied the tap's claim policy, not a newer
        // server publication whose subscriber has not retired old input yet.
        let world = readinessLock.withLock { readinessWorld }
        guard action.phase == .keyDown,
              let target = Self.spaceShortcutTarget(spaceContextGeneration: action.spaceContextGeneration,
                currentSpaceContextGeneration: input?.routing.spaceContextGeneration, world: world, trusted: trustedProvider()) else { completion(4); return }
        toggleSpace(target, inputAction: action, completion: completion)
    }

    static func inputCanClaim(_ world: JSONValue, trusted: Bool) -> Bool {
        trusted && worldReady(world)
            && world.at(path: "desired_running")?.boolValue != false
            && world.at(path: "resident_starting")?.boolValue != true
            && world.at(path: "focus.eligible")?.boolValue == true
            && world.at(path: "focus.space_enabled")?.boolValue == true
            && world.at(path: "focus.space_visible")?.boolValue == true
    }

    /// A committed reconcile whose only shortfall is a confirmed application minimum or
    /// refused shape: every other frame landed, and the learned constraint replans the
    /// layout once the resident runs.
    static func isMinimumShortfall(_ result: JSONValue) -> Bool {
        result.at(path: "status") == .string("failed")
            && ["minimum_constraint", "fixed_aspect_constraint"].contains(result.at(path: "reason")?.stringValue ?? "")
            && result.at(path: "desired_state_committed_revision")?.intValue != nil
    }

    static func startupReconciliationMatches(_ result: JSONValue, requestID: String, baselineRevision: UInt64,
                                             world: JSONValue) -> Bool {
        result.at(path: "request_id")?.stringValue == requestID && result.at(path: "phase")?.stringValue == "completed"
            && result.at(path: "action_id")?.stringValue == "world.reconcile"
            && result.at(path: "origin")?.stringValue == "internal_reconcile"
            && (WmStatus(rawValue: result.at(path: "status")?.stringValue ?? "")?.isOK == true || isMinimumShortfall(result))
            && (result.at(path: "revision")?.intValue ?? -1) >= Int64(clamping: baselineRevision)
            && result.at(path: "reconciliation_ready")?.boolValue == true
            && result.at(path: "reconciliation_verified_scope") == ResidentActionController.reconciliationScope(world)
    }

    /// Contention a fresh startup plan may resolve. A Space switch publishes
    /// `space_changed` and `app_activated` a few ms apart, in either order; the
    /// first wakes the seed gate and the second (a) bumps the revision, (b) bumps
    /// admission through the observer generation, or (c) cancels the startup
    /// frame effect already issued (`invalidated_<event>`, status failed).
    /// Identity/Space changes are excluded by the scope check, not by reason.
    static let startupReconciliationContentionReasons: Set<String> = [
        "expected_revision_mismatch", "queued_command_invalidated",
        "invalidated_space_changed", "invalidated_app_activated"]

    /// Startup shares the controller's reconcile retry bound: a retry can itself
    /// collide with the reconcile the same Space-switch event scheduled.
    static let startupReconciliationRetryLimit = ResidentActionController.reconciliationRetryLimit

    /// A bounded fresh plan may resolve harmless revision/admission/invalidation
    /// contention. The refused/cancelled intent stays aborted; changed
    /// identities/Spaces or lifecycle authority cannot be retried under the old
    /// startup scope.
    static func startupReconciliationCanReplan(_ result: JSONValue, baseline: JSONValue, current: JSONValue,
                                               trusted: Bool, generation: UInt64, currentGeneration: UInt64,
                                               attempt: Int) -> Bool {
        attempt < startupReconciliationRetryLimit && generation == currentGeneration && trusted
            && result.at(path: "phase") == .string("completed")
            && (result.at(path: "status") == .string("refused") || result.at(path: "status") == .string("failed"))
            && result.at(path: "reason")?.stringValue.map(startupReconciliationContentionReasons.contains) == true
            && result.at(path: "action_id") == .string("world.reconcile")
            && result.at(path: "origin") == .string("internal_reconcile")
            && worldReady(current)
            && current.at(path: "desired_running")?.boolValue != false
            && ResidentActionController.reconciliationScope(baseline) == ResidentActionController.reconciliationScope(current)
    }

    /// A display whose current Space is native full-screen (or another non-desktop
    /// Space) has no desktop context, so planning refuses. That is a place the
    /// operator is, not a fault: startup keeps waiting, and the next Space-switch
    /// sweep with a complete world re-runs it instead of parking "Recovery needed".
    static let startupDesktopSpaceAwaitReasons: Set<String> = [
        "space_contexts_unavailable", "space_contexts_ambiguous_or_incomplete"]

    static func startupAwaitsDesktopSpace(_ result: JSONValue) -> Bool {
        result.at(path: "status") == .string("refused")
            && result.at(path: "action_id") == .string("world.reconcile")
            && (result.at(path: "reconciliation_failure_reason") ?? result.at(path: "reason"))?.stringValue
                .map(startupDesktopSpaceAwaitReasons.contains) == true
    }

    /// Pure final authority guard. The publication mirror is updated in commit
    /// order and never calls back into CoreServer while this guard runs.
    static func startupPublicationRefusal(_ result: JSONValue, requestID: String, baselineRevision: UInt64,
                                          world: JSONValue, partitions: JSONValue?, generation: UInt64,
                                          currentGeneration: UInt64) -> String? {
        guard generation == currentGeneration else { return "startup_lifecycle_retired" }
        guard worldReady(world), world.at(path: "desired_running")?.boolValue != false,
              startupReconciliationMatches(result, requestID: requestID, baselineRevision: baselineRevision, world: world),
              world.at(path: "model_state.space_partitions") == partitions else { return "startup_reconciliation_scope_changed" }
        return nil
    }

    func stopForShutdown() {
        heartbeat?.cancel(); heartbeat = nil
        geometryEvents?.stop()
        settings?.stop()
        controlDeadlineLock.lock(); controlDeadlineTimer?.cancel(); controlDeadlineTimer = nil
        controlDeadlineJobs.removeAll(); controlDeadlineLock.unlock()
        input?.stop()
    }

    func sessionUnavailable() {
        input?.setClaimsAllowed(false, reason: .sessionLocked)
        actions.invalidate(cause: "cancel")
        var delta: JSONObject = ["event": .string("session_locked"), "mode": .string("default"),
            "focus": .null, "observation": .object(["world_complete": .bool(false), "failure_code": .string("session_locked")])]
        if server.worldState.at(path: "persistence_available")?.boolValue != false,
           server.worldState.at(path: "geometry_available")?.boolValue != false {
            delta["resident_status"] = .string("Desktop locked")
            delta["resident_unavailable_reason"] = .string("session_locked")
        }
        _ = server.applyWorldDelta(delta)
        if let input { server.updateResidentHealth(["input": .object(input.health())]) }
    }

    func sessionMayResume() -> Bool {
        !maintenance.isExclusive && server.worldState.managementEnabled
    }

    private func startInput(_ input: ResidentInput) -> Bool {
        let started = inputCapabilityGate.perform { input.health()["tap_installed"]?.boolValue == true || input.start() }
        modeLock.lock(); let sequence = modeSequence; modeLock.unlock()
        server.updateResidentHealth(["input": .object(input.health()), "input_started": .bool(started),
            "input_unavailable_reason": started ? .null : .string("input_monitoring_permission_or_tap_unavailable")])
        server.updateModeSubscriptionHealth(ModeHealth(connected: started, ready: started,
            epoch: modeEpoch, sequence: sequence, degradedReason: started ? nil : "resident_input_unavailable"))
        _ = server.applyWorldDelta(["event": .string(started ? "resident_input_started" : "resident_input_start_failed"),
            "resident_unavailable_reason": started ? .null : .string("input_monitoring_permission_or_tap_unavailable")])
        return started
    }

    private static func readGeometry(path: String, generation: UInt64) -> ResidentSettingsSnapshot {
        let loaded = ResidentSettingsStore.loadObject(path: path, maximumBytes: 65_536,
            codes: ("GEOMETRY.STAT_FAILED", "GEOMETRY.INVALID", "GEOMETRY.INVALID"))
        guard loaded.present else {
            // An absent file is the empty configuration; a stat failure is not.
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true, present: false,
                errorCode: loaded.errorCode, generation: generation,
                configuration: loaded.errorCode == nil ? .object([:]) : nil)
        }
        guard let object = loaded.object,
              object["border_radius"] == nil || ((object["border_radius"]?.intValue).map { (0...512).contains($0) } ?? false) else {
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true, present: true,
                errorCode: "GEOMETRY.INVALID", generation: generation)
        }
        return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true, present: true,
            errorCode: nil, generation: generation, configuration: .object(object))
    }

    private func geometryChanged(_ snapshot: ResidentSettingsSnapshot) {
        lifecycleQueue.async { [self] in applyGeometry(snapshot) }
    }

    private func applyGeometry(_ snapshot: ResidentSettingsSnapshot) {
        actions.setGeometryError(snapshot.errorCode)
        guard snapshot.errorCode == nil, let store = snapshot.configuration else {
            _ = server.applyWorldDelta(["event": .string("geometry_invalid"),
                "resident_unavailable_reason": snapshot.errorCode.map(JSONValue.string) ?? .string("geometry_unavailable")])
            return
        }
        let applied = store
        _ = server.applyWorldDelta(["event": .string("border_palette_applied")])
        DispatchQueue.main.async { [renderer, server, applied] in
            MainActor.assumeIsolated {
                renderer?.updateStore(applied)
                let snapshot = server.committedSnapshot
                _ = renderer?.render(plan: snapshot.borderPlan, revision: snapshot.revision)
                if let renderer { server.updateProjectionHealth(renderer.health) }
            }
        }
    }

    private func toggleSpace(_ target: ResidentSpaceTarget, inputAction: ResidentInputAction? = nil,
                             completion: @escaping @Sendable (Int) -> Void = { _ in }) {
        lifecycleQueue.async { [self] in
            if let inputAction {
                guard Self.spaceShortcutTarget(spaceContextGeneration: inputAction.spaceContextGeneration,
                    currentSpaceContextGeneration: input?.routing.spaceContextGeneration, world: server.worldState, trusted: trustedProvider()) == target else { completion(4); return }
            }
            do {
                let enabled = try ResidentSpaceManagement.toggle(target: target, world: server.worldState,
                    settingsPath: ResidentSettingsStore.defaultPath(), desiredRunning: desiredRunning,
                    commit: { server.setSpaceEnabled($0, enabled: $1) })
                _ = server.applyWorldDelta(["event": .string("space_control_result"),
                    "space_control_last_result": .object(["status": .string(WmStatus.accepted.rawValue), "space_key": .string(target.spaceKey),
                        "display_id": .string(target.displayId), "space_enabled": .bool(enabled),
                        "origin": .string(inputAction == nil ? "menu" : "input"),
                        "input_generation": inputAction.map { .int(Int64(clamping: $0.generation)) } ?? .null,
                        "space_context_generation": inputAction.map { .int(Int64(clamping: $0.spaceContextGeneration)) } ?? .null,
                        "source_receipt_uptime_ns": inputAction.map { .int(Int64(clamping: $0.receiptUptimeNs)) } ?? .null])])
                completion(0)
            } catch let error as ResidentInputError {
                _ = server.applyWorldDelta(["event": .string("space_control_result"),
                    "space_control_last_result": .object(["status": .string(WmStatus.refused.rawValue), "reason": .string(error.code),
                        "space_key": .string(target.spaceKey), "display_id": .string(target.displayId)])])
                completion(4)
            } catch { settingsFailure("SETTINGS.WRITE_FAILED"); completion(4) }
        }
    }

    private func settingsFailure(_ code: String) {
        settingsFaulted = true
        _ = server.applyWorldDelta(["event": .string("settings_failed"), "resident_unavailable_reason": .string(code)])
    }

    private func menuAction(_ action: ResidentMenuAction) {
        lifecycleQueue.async { [self] in
            let world = server.worldState
            let visible = (world.at(path: "space_contexts")?.arrayValue ?? []).contains {
                $0.at(path: "space_key")?.stringValue == action.target.spaceKey
                    && $0.at(path: "display_id")?.stringValue == action.target.displayId
                    && $0.at(path: "space_visible")?.boolValue == true
                    && $0.at(path: "space_enabled")?.boolValue != false
            }
            guard visible else {
                _ = server.applyWorldDelta(["event": .string("control_refused"), "resident_unavailable_reason": .string("menu_target_unavailable")]); return
            }
            _ = actions.handleMenuAction(action)
        }
    }

    private func settingsChanged(_ snapshot: ResidentSettingsSnapshot) {
        lifecycleQueue.async { [self] in
            let actual = ResidentSettingsStore.read(path: ResidentSettingsStore.defaultPath())
            guard actual.errorCode == snapshot.errorCode, actual.spacesEnabled == snapshot.spacesEnabled,
                  actual.desiredRunning == snapshot.desiredRunning else { return }
            guard snapshot.errorCode == nil else {
                settingsFaulted = true
                actions.invalidate(cause: "settings-failure")
                input?.releaseModal(reason: .settingsFailure)
                _ = server.applyWorldDelta(["event": .string("settings_failed"), "management_enabled": .bool(false),
                    "desired_running": .null,
                    "resident_unavailable_reason": .string(snapshot.errorCode!)])
                return
            }
            let recovering = settingsFaulted
            settingsFaulted = false
            _ = server.applyWorldDelta(["event": .string("settings_changed"),
                "desired_running": .bool(snapshot.desiredRunning),
                "space_activation": .object(JSONObject(unordered: snapshot.spacesEnabled.mapValues(JSONValue.bool))),
                "resident_unavailable_reason": .null])
            if snapshot.desiredRunning != desiredRunning || (recovering && snapshot.desiredRunning) {
                performLifecycle(snapshot.desiredRunning ? .start : .stop)
            }
        }
    }

    private func lifecycle(_ action: ResidentLifecycleAction) {
        lifecycleQueue.async { [self] in
            let wanted = action == .stop ? false : action == .start ? true : desiredRunning
            performLifecycle(action, resumeOverride: action == .restart || action == .hardReset ? wanted : nil,
                persistDesired: wanted)
        }
    }

    /// Admission refusal has no epoch. It still terminates this exact current
    /// lifecycle request; success and admitted failures require their real epoch.
    static func maintenanceOutcomeIsCurrent(_ outcome: Result<JSONValue, MaintenanceFailure>, requestID: String,
                                             generation: UInt64, currentGeneration: UInt64,
                                             epochIsCurrent: (UInt64) -> Bool) -> Bool {
        guard generation == currentGeneration else { return false }
        switch outcome {
        case .success(let result):
            guard result.at(path: "maintenance_request_id")?.stringValue == requestID,
                  let raw = result.at(path: "maintenance_epoch")?.intValue, raw > 0 else { return false }
            return epochIsCurrent(UInt64(raw))
        case .failure(let failure):
            guard failure.requestID == requestID else { return false }
            return failure.epoch.map { $0 > 0 && epochIsCurrent($0) } ?? true
        }
    }

    private func performLifecycle(_ action: ResidentLifecycleAction, resumeOverride: Bool? = nil,
                                  controlRequestID: String? = nil, controlAdmissionSequence: UInt64? = nil,
                                  persistDesired: Bool? = nil,
                                  completion: LifecycleCompletion? = nil) {
            if maintenance.isExclusive && action != .stop {
                _ = server.applyWorldDelta(["event": .string("maintenance_busy"), "resident_unavailable_reason": .string("maintenance_in_progress")])
                completion?(.refused, "maintenance_in_progress", [:])
                return
            }
            let generation: UInt64
            if let controlRequestID {
                guard let controlAdmissionSequence,
                      let allocated = controlRequests.begin(requestID: controlRequestID,
                        expectedAdmissionSequence: controlAdmissionSequence, allocateGeneration: {
                    lifecycleGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
                }) else { return }
                generation = allocated
            } else { generation = lifecycleGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1 }
            if action == .stop, let id = maintenance.snapshot().at(path: "request_id")?.stringValue { _ = maintenance.cancel(requestID: id) }
            for result in controlRequests.supersede(except: controlRequestID, revision: server.currentRevision) {
                if let id = result.at(path: "request_id")?.stringValue,
                   let serial = result.at(path: "control_admission_sequence")?.intValue, serial > 0 {
                    cancelControlDeadline(id, admissionSequence: UInt64(serial))
                }
                _ = server.applyWorldDelta(["event": .string("resident_control_result"), "control_last_result": result], commitGuard: { [controlRequests] in
                    guard let id = result.at(path: "request_id")?.stringValue else { return "resident_control_result_retired" }
                    return controlRequests.result(requestID: id, revision: 0) == result ? nil : "resident_control_result_retired"
                })
            }
            guard lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
            var persistenceFailure: String?
            if let persistDesired {
                let current = ResidentSettingsStore.read(path: ResidentSettingsStore.defaultPath())
                if let errorCode = current.errorCode { persistenceFailure = errorCode }
                else {
                    do {
                        try ResidentSettingsStore.write(path: ResidentSettingsStore.defaultPath(),
                            spacesEnabled: current.spacesEnabled, desiredRunning: persistDesired)
                    } catch { persistenceFailure = "SETTINGS.WRITE_FAILED" }
                }
                if let persistenceFailure {
                    settingsFailure(persistenceFailure)
                    // Explicit Stop remains an escape even when durable state is
                    // damaged. Report the persistence failure after teardown.
                    if action != .stop {
                        completion?(.failed, persistenceFailure, [:]); return
                    }
                } else {
                    _ = server.applyWorldDelta(["event": .string("management_preference_recorded"),
                        "desired_running": .bool(persistDesired)])
                }
            }
            let stopPersistenceFailure = persistenceFailure
            startupSeedGate.cancel()
            switch action {
            case .stop:
                desiredRunning = false
                actions.invalidate(cause: "cancel")
                _ = server.applyWorldDelta(["event": .string("global_stop"), "management_enabled": .bool(false),
                    "resident_starting": .bool(false), "resident_running": .bool(false), "resident_status": .string("Stopped"), "mode": .string("default")])
                inputStopBarrier.stop(resume: { [weak self] in
                    guard let self, self.lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                    self.stopProjections(whileCurrent: { [weak self] in
                        self?.lifecycleGeneration.load(ordering: .acquiring) == generation
                    }, then: { _ in
                        completion?(stopPersistenceFailure == nil ? .accepted : .failed, stopPersistenceFailure,
                            ["management_enabled": .bool(false), "journal_preserved": .bool(true),
                            "readiness_verified": .bool(false), "resident_process_alive": .bool(true),
                            "desired_state_persisted": .bool(stopPersistenceFailure == nil)])
                    })
                })
            case .start:
                inputStartAttempted.store(false, ordering: .releasing)
                desiredRunning = true
                _ = server.applyWorldDelta(["event": .string("resident_starting"), "resident_starting": .bool(true),
                    "resident_running": .bool(false), "resident_status": .string("Starting")])
                inputStopBarrier.stop(resume: { [weak self] in
                    guard let self, self.desiredRunning, self.lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                    self.startFresh(generation: generation, completion: completion)
                })
            case .restart:
                inputStartAttempted.store(false, ordering: .releasing)
                let resume = resumeOverride ?? true
                desiredRunning = resume
                actions.invalidate(cause: "cancel")
                _ = server.applyWorldDelta(["event": .string("global_restart"), "management_enabled": .bool(false),
                    "resident_starting": .bool(true), "resident_status": .string("Restarting"), "mode": .string("default")])
                inputStopBarrier.stop(resume: { [weak self] in
                    guard let self, self.lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                    if self.desiredRunning { self.startFresh(generation: generation, completion: { status, reason, details in
                        completion?(status, reason, details.merging(["journal_preserved": .bool(true)]))
                    }) }
                    else {
                        // Restart to OFF now publishes the unmounted projection's health like every other teardown.
                        self.stopProjections(whileCurrent: { [weak self] in
                            self?.lifecycleGeneration.load(ordering: .acquiring) == generation
                        }, then: { services in
                            _ = services.server.applyWorldDelta(["event": .string("global_stop"), "management_enabled": .bool(false),
                                "resident_starting": .bool(false), "resident_status": .string("Stopped"), "resident_running": .bool(false)])
                            completion?(.accepted, nil, ["management_enabled": .bool(false), "journal_preserved": .bool(true),
                                "readiness_verified": .bool(false), "resident_process_alive": .bool(true)])
                        })
                    }
                })
            case .hardReset:
                let resume = resumeOverride ?? desiredRunning
                desiredRunning = false
                inputStopBarrier.stop()
                actions.beginMaintenance()
                _ = server.applyWorldDelta(["event": .string("global_reset"), "resident_starting": .bool(resume),
                    "resident_running": .bool(false), "resident_status": .string("Resetting")])
                let requestID = controlRequestID ?? UUID().uuidString
                let participants: [ResidentMaintenance.StopParticipant] = [
                    { [inputStopBarrier] acknowledge in inputStopBarrier!.whenStopped(acknowledge) },
                    { [observationQueue, feed, snapshots] acknowledge in observationQueue.async { feed.stop(); snapshots.stop(); acknowledge() } },
                    { [actions] acknowledge in actions.whenIOQuiescent(acknowledge) },
                    { [actions] acknowledge in actions.whenAXQuiescent(acknowledge) },
                    { [renderer, server] acknowledge in DispatchQueue.main.async {
                        MainActor.assumeIsolated { renderer?.unmount(); if let renderer { server.updateProjectionHealth(renderer.health) } }
                        acknowledge()
                    } },
                ]
                maintenance.begin(requestID: requestID, stopParticipants: participants,
                    reset: { [actions, lifecycleGeneration] permit in
                        guard lifecycleGeneration.load(ordering: .acquiring) == generation else {
                            throw MaintenanceFailure(code: "MAINTENANCE.CANCELLED", message: "Control lifetime ended before journal reset",
                                requestID: permit.requestID, epoch: permit.epoch)
                        }
                        return try actions.resetJournal(permit: permit)
                    },
                    onOutcome: { [weak self] outcome in
                        guard let self else { return }
                        self.lifecycleQueue.async { [self] in
                            guard Self.maintenanceOutcomeIsCurrent(outcome, requestID: requestID, generation: generation,
                                currentGeneration: lifecycleGeneration.load(ordering: .acquiring),
                                epochIsCurrent: maintenance.isCurrentEpoch) else { return }
                            let epoch: UInt64?
                            switch outcome {
                            case .success(let result): epoch = result.at(path: "maintenance_epoch")?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
                            case .failure(let failure): epoch = failure.epoch
                            }
                            switch outcome {
                            case .success(let resetResult):
                                guard let epoch else { return }
                                actions.finishMaintenance { [weak self] in
                                    guard let self else { return }
                                    self.lifecycleQueue.async { [self] in
                                        guard maintenance.isCurrentEpoch(epoch), lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                                        desiredRunning = resume
                                        _ = server.applyWorldDelta(["event": .string("reset_completed"), "resident_status": .string(resume ? "Starting" : "Stopped")])
                                        if resume { startFresh(generation: generation, completion: { status, reason, details in
                                            completion?(status, reason, (resetResult.objectValue ?? [:]).merging(details)
                                                .merging(["journal_preserved": .bool(false)]))
                                        }) }
                                        else { completion?(.accepted, nil, (resetResult.objectValue ?? [:]).merging([
                                            "management_enabled": .bool(false), "journal_preserved": .bool(false), "readiness_verified": .bool(false)])) }
                                    }
                                }
                            case .failure(let failure):
                                _ = server.applyWorldDelta(["event": .string("reset_failed"), "resident_status": .string("Recovery needed"),
                                    "resident_starting": .bool(false), "resident_unavailable_reason": .string(failure.code)])
                                completion?(.failed, failure.code, ["maintenance_failure": failure.json, "management_enabled": .bool(false)])
                            }
                        }
                    })
            }
    }

    private func startFresh(generation: UInt64, completion: LifecycleCompletion? = nil) {
        guard lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
            let running = NSWorkspace.shared.frontmostApplication
            let application = running.map { ProjectionApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "") }
            self.observationQueue.async { [self] in
                guard lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                feed.start(frontmost: application)
                guard lifecycleGeneration.load(ordering: .acquiring) == generation else { feed.stop(); snapshots.stop(); return }
                _ = server.applyWorldDelta(["event": .string("global_start"), "management_enabled": .bool(true),
                    "resident_starting": .bool(true), "resident_running": .bool(false), "resident_status": .string("Starting")])
                lifecycleQueue.async { [self] in
                    guard desiredRunning, lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                    reconcileBaseline(generation: generation, completion: completion)
                }
            }
        }
    }

    private func reconcileBaseline(generation: UInt64, completion: LifecycleCompletion?, startup: ResidentStartupSeedGate.Scope? = nil,
                                   contentionAttempt: Int = 0) {
        guard desiredRunning, lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
        inputStartAttempted.store(true, ordering: .releasing)
        let baseline = server.committedSnapshot
        let requestID = UUID().uuidString
        actions.reconcile(requestID: requestID) { [weak self] result in
            guard let self else { return }
            self.lifecycleQueue.async { [self] in
                guard desiredRunning, lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                if let startup, !startupSeedGate.isCurrent(startup, generation: generation, observationEpoch: server.observationEpoch) { return }
                let matched = result.at(path: "request_id")?.stringValue == requestID
                    && (result.at(path: "revision")?.intValue ?? -1) >= Int64(clamping: baseline.revision)
                let beforeInput = server.committedSnapshot
                if Self.startupReconciliationCanReplan(result, baseline: baseline.world, current: beforeInput.world,
                    trusted: trustedProvider(), generation: generation,
                    currentGeneration: lifecycleGeneration.load(ordering: .acquiring), attempt: contentionAttempt) {
                    ResidentPerformanceTrace.shared.record("startup_reconcile_replan", fields: [
                        "prior_request_id": .string(requestID), "attempt": .int(Int64(contentionAttempt + 1)),
                        "revision": .int(Int64(clamping: beforeInput.revision)),
                        "reason": result.at(path: "reason") ?? .null])
                    reconcileBaseline(generation: generation, completion: completion, startup: startup,
                        contentionAttempt: contentionAttempt + 1)
                    return
                }
                let reconciled = Self.startupReconciliationMatches(result, requestID: requestID, baselineRevision: baseline.revision,
                    world: beforeInput.world)
                let ready = reconciled && trustedProvider() && Self.worldReady(beforeInput.world)
                let inputStarted = ready && (input.map(startInput) ?? true)
                guard lifecycleGeneration.load(ordering: .acquiring) == generation else { input?.stop(); return }
                let verified = server.committedSnapshot
                let started = inputStarted && trustedProvider() && Self.worldReady(verified.world)
                    && result.at(path: "reconciliation_verified_scope") == ResidentActionController.reconciliationScope(verified.world)
                    && verified.world.at(path: "model_state.space_partitions") == beforeInput.world.at(path: "model_state.space_partitions")
                let reason = started ? nil : !matched ? "startup_reconcile_stale" : !reconciled
                    ? result.at(path: "reconciliation_failure_reason")?.stringValue ?? result.at(path: "reason")?.stringValue ?? "world_reconcile_failed"
                    : !ready ? "world_incomplete" : "resident_input_unavailable"
                if let startup, !started,
                   (!trustedProvider() || verified.world.worldComplete != true || Self.startupAwaitsDesktopSpace(result)),
                   startupSeedGate.waitForRecovery(startup, generation: generation, observationEpoch: server.observationEpoch) {
                    input?.stop()
                    return
                }
                if let startup, !startupSeedGate.finish(startup, generation: lifecycleGeneration.load(ordering: .acquiring),
                    observationEpoch: server.observationEpoch) { input?.stop(); return }
                // Readiness failure parks capabilities while preserving the
                // operator's ON preference for recovery/restart.
                if !started { input?.stop() }
                let published = server.applyWorldDelta(["event": .string(started ? "resident_start_completed" : "resident_start_failed"),
                    "resident_starting": .bool(false), "management_enabled": .bool(started), "resident_running": .bool(started),
                    "resident_status": .string(started ? "Running" : "Recovery needed"),
                    "startup_readiness": .object(["readiness_verified": .bool(started),
                        "readiness_revision": .int(Int64(clamping: verified.revision)),
                        "reconciliation_request_id": .string(requestID), "reconciliation_result": result]),
                    "resident_unavailable_reason": reason.map(JSONValue.string) ?? .null], commitGuard: { [weak self] in
                        guard let self else { return "runtime_unavailable" }
                        guard started else { return self.lifecycleGeneration.load(ordering: .acquiring) == generation ? nil : "startup_lifecycle_retired" }
                        let world = self.readinessLock.withLock { self.readinessWorld }
                        return Self.startupPublicationRefusal(result, requestID: requestID, baselineRevision: baseline.revision,
                            world: world, partitions: beforeInput.world.at(path: "model_state.space_partitions"),
                            generation: generation, currentGeneration: self.lifecycleGeneration.load(ordering: .acquiring))
                    })
                guard published.status == .accepted else {
                    input?.stop()
                    if lifecycleGeneration.load(ordering: .acquiring) == generation {
                        _ = server.applyWorldDelta(["event": .string("resident_start_failed"), "resident_starting": .bool(false),
                            "management_enabled": .bool(false), "resident_running": .bool(false),
                            "resident_status": .string("Recovery needed"),
                            "resident_unavailable_reason": published.reason.map(JSONValue.string) ?? .string("startup_publication_refused")],
                            commitGuard: { [lifecycleGeneration] in
                                lifecycleGeneration.load(ordering: .acquiring) == generation ? nil : "startup_lifecycle_retired"
                            })
                    }
                    completion?(.failed, published.reason, ["readiness_verified": .bool(false), "management_enabled": .bool(false)])
                    return
                }
                completion?(started ? .accepted : .failed, reason, ["baseline_ready": .bool(ready),
                    "management_enabled": .bool(started), "readiness_verified": .bool(started),
                    "readiness_revision": .int(Int64(clamping: verified.revision)), "resident_process_alive": .bool(true),
                    "observer_generation": verified.world.at(path: "observer_generation") ?? .null,
                    "reconciliation_request_id": .string(requestID), "reconciliation_result": result])
                if started { actions.resumeStartupMinimums() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lifecycleGeneration.load(ordering: .acquiring) == generation else { return }
                    MainActor.assumeIsolated {
                        if started {
                            _ = self.renderer?.mount()
                            let current = self.server.committedSnapshot
                            _ = self.renderer?.render(plan: current.borderPlan, revision: current.revision)
                        } else { self.renderer?.unmount() }
                        if let renderer = self.renderer { self.server.updateProjectionHealth(renderer.health) }
                    }
                }
            }
        }
    }
}
