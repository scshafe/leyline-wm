import Foundation
import LeylineModel

/// Native command dispatch and lifecycle reconciliation share this bounded
/// planning lane. It holds requested state through resize repetitions, while
/// only CoreServer can commit a journaled arrangement and allocate a revision.
final class ResidentActionController: @unchecked Sendable {
    // Restart and the Space toggle are lifecycle controls owned by CoreRuntimeServices, not planned actions.
    static let actionIDs = ResidentInput.retainedActionIds
        .subtracting(["service.restart", ResidentInputConstants.spaceToggleActionID]).union(["window.select"])
    private let queue = DispatchQueue(label: "leylined.commands", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let lock = NSLock()
    private let server: CoreServer
    private let axPort: ResidentAXPort
    private let journal: ResidentEffectorFileJournal
    private let gap: Int
    /// Pure model fixtures can provide their declared canvas reservation.
    /// Production leaves this nil so the fixed border width owns all edge spacing.
    private let outerGap: Int?
    private var latest: CoreCommittedSnapshot
    private var desired: JSONValue
    private var callbacks: [String: @Sendable (Int) -> Void] = [:]
    private var reconciliationCompletions: [String: @Sendable (JSONValue) -> Void] = [:]
    private var results: [String: JSONValue] = [:]
    private var fingerprints: [String: String] = [:]
    private var requestActions: [String: String] = [:]
    private struct MinimumCandidate: Sendable {
        let request: ResidentEffectRequest
        let evidence: [ResidentMinimumEvidence]
        let source: CommandSource
        let admission: UInt64
    }
    private var pendingMinimums: [MinimumCandidate] = [] // planning queue only
    private var startupDeferredMinimums: [MinimumCandidate] = [] // planning queue only
    private var minimumLearningStatus = "no_proven_floor_change"
    private var minimumAutomaticReplans: Set<String> = [] // planning queue only
    struct ConfirmedFocusCandidate: Sendable {
        let windowID: Int64
        let pid: Int64
        let windowGeneration: UInt64
        let spaceKey: String
        let displayID: String
        let observerEpoch: String
        let observerGeneration: UInt64
        let observedNanos: UInt64
        var identity: JSONValue {
            .object(["window_id": .int(windowID), "pid": .int(pid),
                "window_generation": .int(Int64(clamping: windowGeneration)),
                "space_key": .string(spaceKey), "display_id": .string(displayID)])
        }
    }
    private var pendingConfirmedFocus: ConfirmedFocusCandidate? // one newest proof, planning queue only
    struct CommandSource: Sendable {
        let actionID: String
        let origin: String
        let inputGeneration: UInt64?
        let receipt: UInt64
        let admissionGeneration: UInt64
        let eventProvenance: JSONObject
        init(actionID: String, origin: String, inputGeneration: UInt64?, receipt: UInt64,
             admissionGeneration: UInt64, eventProvenance: JSONObject = [:]) {
            self.actionID = actionID; self.origin = origin; self.inputGeneration = inputGeneration
            self.receipt = receipt; self.admissionGeneration = admissionGeneration
            self.eventProvenance = eventProvenance
        }
        var metadata: JSONObject {
            let fields: JSONObject = ["action_id": .string(actionID), "origin": .string(origin),
             "source_input_generation": inputGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
             "source_receipt_uptime_ns": .int(Int64(clamping: receipt)),
             "source_admission_generation": .int(Int64(clamping: admissionGeneration))]
            return fields.merging(eventProvenance)
        }
    }
    private struct ReconciliationEvent: Sendable {
        let event: String
        let revision: UInt64
        let receipt: UInt64
        let notificationReceipt: Int64?
        let notificationWindowID: Int64?
        let lifecycleCause: String?
        let receiptBoundary: String
        init(_ snapshot: CoreCommittedSnapshot) {
            let capturedEvent = snapshot.world.at(path: "event")?.stringValue ?? "external-event"
            let windowLifecycle = AccessibilityFocusEventKind.isWindowLifecycle(capturedEvent)
            let notification = windowLifecycle ? snapshot.world.at(path: "notification_receipt_uptime_ns")?.intValue : nil
            event = capturedEvent
            revision = snapshot.revision
            notificationReceipt = notification
            notificationWindowID = windowLifecycle ? snapshot.world.at(path: "notification_window_id")?.intValue : nil
            if let notification, notification > 0, UInt64(notification) <= snapshot.receiptUptimeNs {
                receipt = UInt64(notification); receiptBoundary = "notification_receipt"
            } else {
                receipt = snapshot.receiptUptimeNs; receiptBoundary = "committed_snapshot_receipt"
            }
            lifecycleCause = capturedEvent == "ax_window_minimized" ? "window.minimized"
                : ["ax_window_destroyed", "app_terminated"].contains(capturedEvent) ? "window.destroyed" : nil
        }
        /// A command found the per-Space checkpoint behind current observation;
        /// the reconcile that should have re-recorded it is owed.
        init(repairing snapshot: CoreCommittedSnapshot) {
            event = "stale_partition_repair"; revision = snapshot.revision; receipt = snapshot.receiptUptimeNs
            notificationReceipt = nil; notificationWindowID = nil; lifecycleCause = nil
            receiptBoundary = "committed_snapshot_receipt"
        }
        var metadata: JSONObject {
            ["source_event": .string(event), "source_event_revision": .int(Int64(clamping: revision)),
             "source_event_receipt_uptime_ns": .int(Int64(clamping: receipt)),
             "source_receipt_boundary": .string(receiptBoundary),
             "source_notification_receipt_uptime_ns": notificationReceipt.map(JSONValue.int) ?? .null,
             "source_notification_window_id": notificationWindowID.map(JSONValue.int) ?? .null,
             "lifecycle_cause": lifecycleCause.map(JSONValue.string) ?? .null]
        }
    }
    private var commandSources: [String: CommandSource] = [:]
    private let stateOnlyAppend: @Sendable (JSONValue, ResidentEffectorFileJournal) throws -> Void
    private var inputGenerationReader: (@Sendable () -> UInt64?)?
    private var inputGenerations: [String: UInt64] = [:]
    private var inputReceipts: [String: UInt64] = [:]
    private var inputProgressHandler: (@Sendable (UInt64, UInt64, UInt64) -> Void)?
    private var activeEffectRequests: [String: ResidentEffectRequest] = [:]
    private var activeFrameGenerations: [String: UInt64] = [:]
    private var activeFocusGenerations: [String: UInt64] = [:]
    private var activeRequestLifetimes: [String: [String: UInt64]] = [:]
    private struct DeferredCommand {
        let actionID: String
        let requestID: String
        let arguments: JSONValue
        let receipt: UInt64
        let expectedRevision: UInt64?
        let generation: UInt64
    }
    private var deferredCommands: [DeferredCommand] = []
    /// Whether the controller may plan at all: persistence, geometry and the
    /// observation queue are all sound. Callers hold `lock`.
    private var availableLocked: Bool { persistenceAvailable && geometryAvailable && !observationOverflowed }
    /// No effect in flight or pending, and no command deferred behind one.
    private var commandLaneIdle: Bool {
        let effects = effector.snapshot()
        return effects.at(path: "in_flight") == .null && effects.at(path: "pending_count")?.intValue == 0 && deferredCommands.isEmpty
    }
    /// Queue a command behind the in-flight effect; false when the queue is full and the caller must refuse.
    private func deferCommand(actionID: String, requestID: String, arguments: JSONValue, receipt: UInt64,
                              expectedRevision: UInt64?) -> Bool {
        guard deferredCommands.count < 32 else { return false }
        lock.lock(); let generation = admissionGeneration; lock.unlock()
        deferredCommands.append(DeferredCommand(actionID: actionID, requestID: requestID, arguments: arguments,
                                                receipt: receipt, expectedRevision: expectedRevision, generation: generation))
        return true
    }
    private var resultOrder: [String] = []
    private var reconcileScheduled = false
    private var pendingReconciliationEvents: [ReconciliationEvent] = [] // planning queue; same bound as snapshot admission
    private var reconciliationEventOverflow = false
    /// The facts one reconcile carried, held until its outcome so a lost
    /// authority race requeues them instead of stranding a stale checkpoint.
    private struct ReconciliationBatch {
        let events: [ReconciliationEvent]
        let overflow: Bool
        let attempt: Int
    }
    private var pendingReconciliationAttempt = 0
    private var reconciliationBatches: [String: ReconciliationBatch] = [:]
    static let reconciliationRaceReasons: Set<String> = [
        "expected_revision_mismatch", "queued_command_invalidated", "effect_identity_or_context_changed"]
    static let reconciliationRetryLimit = 3
    /// Snapshot admission and the planning queue share the feed's input bound.
    private static let observationQueueBound = ProjectionInputFeed.maximumPendingInputs
    private var pendingSnapshots: [CoreCommittedSnapshot] = []
    private var recoveredWorldRevisions: Set<UInt64> = []
    private var effectFenceRequests: [UInt64: Set<String>] = [:]
    private var ignoredLifecycleRevisions: Set<UInt64> = []
    private var snapshotDrainScheduled = false
    private var observationOverflowed = false
    private var admissionGeneration: UInt64 = 0
    private var persistenceAvailable = true
    private var geometryAvailable = true
    private var effector: ResidentEffector!

    init(server: CoreServer, snapshots: TargetedProjectionSnapshot,
         observationQueue: DispatchQueue, journal: ResidentEffectorFileJournal, gap: Int, outerGap: Int? = nil,
         effectPort: (any ResidentEffectorPort)? = nil,
         stateOnlyAppend: @escaping @Sendable (JSONValue, ResidentEffectorFileJournal) throws -> Void = { try $1.append($0) }) {
        self.server = server; self.gap = gap; self.outerGap = outerGap; self.journal = journal
        self.stateOnlyAppend = stateOnlyAppend
        latest = server.committedSnapshot
        desired = latest.world.at(path: "model_state") ?? .object([:])
        persistenceAvailable = latest.world.at(path: "persistence_available")?.boolValue != false
        axPort = ResidentAXPort(snapshots: snapshots, observationQueue: observationQueue)
        effector = ResidentEffector(context: Self.context(latest, persistenceAvailable: persistenceAvailable),             journal: journal, port: effectPort ?? axPort, commitJournaledPlan: { [weak self] request, _, expected in
                guard let self, self.authorized(request) else { return nil }
                self.lock.lock(); let source = self.commandSources[request.requestID]; self.lock.unlock()
                guard let source else { return nil }
                let server = self.server
                let previousSnapshot = server.committedSnapshot
                let result = server.applyWorldDelta(self.commandMetadata(request.requestID).merging([
                    "event": .string("desired_plan_committed"),
                    "request_id": .string(request.requestID),
                    "model_state": request.proposedState ?? server.worldState.at(path: "model_state") ?? .object([:]),
                ]), expectedRevision: expected, commitGuard: { [weak self] in
                    guard let self else { return "controller_unavailable" }
                    return self.effectPublicationRefusal(request, source: source, admission: source.admissionGeneration)
                })
                Self.recordPlanCommit(result, state: request.proposedState ?? .object([:]),
                    source: source, snapshot: previousSnapshot, requestID: request.requestID, request: request)
                return result.status == .accepted ? result.revision.value : nil
            }, onPersistenceFault: { [weak self] reason in self?.persistenceFault(reason) },
            onProgress: { [weak self] request, stamp in self?.effectProgress(requestID: request, timestamp: stamp) },
            onMinimumEvidence: { [weak self] request, evidence in self?.minimumEvidenceReady(request, evidence: evidence) },
            onOutcome: { [weak self] outcome in self?.completed(outcome) })
        let minimumPort = (effectPort as? any ResidentMinimumEvidencePort) ?? axPort
        minimumPort.onMinimumEvidence = { [weak self] evidence in
            guard let self else { return }
            self.queue.async { [self] in _ = effector.observeMinimumEvidence(evidence) }
        }
        axPort.onFrame = { [weak self] request, window, frame, generation, stamp in
            guard let self else { return }
            self.queue.async { [self] in
                _ = effector.observe(requestID: request, windowID: window, frame: frame,
                    generation: generation, windowGeneration: activeWindowGeneration(requestID: request, windowID: window),
                    timestampNanos: stamp)
            }
        }
        axPort.onFocus = { [weak self] request, window, generation, stamp in
            guard let self else { return }
            self.queue.async { [self] in
                _ = effector.observeFocus(requestID: request, windowID: window, generation: generation,
                    windowGeneration: activeWindowGeneration(requestID: request, windowID: window), timestampNanos: stamp)
            }
        }
        axPort.onFocusIssue = { [weak self] request, stamp in self?.effector.noteFocusIssued(requestID: request, timestampNanos: stamp) }
        axPort.isRequestActive = { [weak self] request in
            guard let self else { return false }
            return self.mayIssueEffect(request)
        }
        axPort.currentObservationGeneration = { [weak self] request in self?.observationGeneration(for: request) }
        axPort.onDeadline = { [weak self] in self?.expireEvidence(at: $0) }
    }

    /// Publication may not call back into a transition. A bounded FIFO retains
    /// exact targeted evidence and lifecycle order; overflow cancels and fences
    /// work until an explicit fresh baseline, never a hidden state poll.
    func receive(_ snapshot: CoreCommittedSnapshot) {
        lock.lock()
        let previous = latest
        latest = snapshot
        let event = snapshot.world.worldEvent
        let changedSpaces = Set((snapshot.world.at(path: "invalidation_space_keys")?.arrayValue ?? []).compactMap(\.stringValue))
        let affectedRequests = activeEffectRequests.values.filter { !Set($0.windowSpaceKeys.values).isDisjoint(with: changedSpaces) }
        let scopedActivation = !changedSpaces.isEmpty && (!affectedRequests.isEmpty
            || snapshot.world.at(path: "mode_context_space_key")?.stringValue.map(changedSpaces.contains) == true)
        let lifecycleEvent = AccessibilityFocusEventKind.isWindowLifecycle(event)
        let lifecycleInvalidating = lifecycleEvent
            && residentLifecycleInvalidatesInteraction(event: event, before: previous.world, after: snapshot.world)
        let foregroundRebind = WorldEvent.foregroundRebind.contains(event)
        let hardInvalidating = scopedActivation || WorldEvent.hardInvalidating.contains(event)
            || lifecycleInvalidating
            || snapshot.world.worldComplete == false
            || previous.world.at(path: "observer_epoch") != snapshot.world.at(path: "observer_epoch")
        let generationChanged = previous.world.at(path: "observer_generation") != snapshot.world.at(path: "observer_generation")
        let available = availableLocked
        let currentGeneration = Self.context(snapshot, persistenceAvailable: available).observerGeneration
        var obsolete: [String] = []
        for request in activeEffectRequests.values {
            let focusContinuous = !hardInvalidating && request.effectKind == .focus
                && (!generationChanged || foregroundRebind)
                && effector.issuedTimestamp(for: request.requestID).flatMap {
                    Self.freshFocusedTargetStamp(request, snapshot: snapshot, available: available, issued: $0)
                } != nil
            if focusContinuous {
                activeFocusGenerations[request.requestID] = currentGeneration
                continue
            }
            let continuous = !hardInvalidating && request.effectKind == .frame
                && Self.frameScopeMatches(request, snapshot: snapshot, available: available)
                && (!generationChanged || foregroundRebind)
            if continuous { activeFrameGenerations[request.requestID] = currentGeneration }
            else if request.effectKind == .frame || generationChanged || hardInvalidating
                || (activeFocusGenerations[request.requestID] != nil && foregroundRebind) {
                activeFrameGenerations.removeValue(forKey: request.requestID)
                activeFocusGenerations.removeValue(forKey: request.requestID)
                obsolete.append(request.requestID)
            }
        }
        let invalidating = hardInvalidating || (generationChanged && (!obsolete.isEmpty || activeEffectRequests.isEmpty))
        if invalidating { admissionGeneration &+= 1 }
        if WorldEvent.fullRecovery.contains(event) {
            observationOverflowed = false
        }
        if pendingSnapshots.count >= Self.observationQueueBound {
            observationOverflowed = true
            admissionGeneration &+= 1
            pendingSnapshots.removeAll()
            recoveredWorldRevisions.removeAll()
            effectFenceRequests.removeAll()
            ignoredLifecycleRevisions.removeAll()
        }
        if previous.world.worldComplete == false
            && snapshot.world.worldComplete == true {
            recoveredWorldRevisions.insert(snapshot.revision)
        }
        pendingSnapshots.append(snapshot)
        if lifecycleEvent && !lifecycleInvalidating { ignoredLifecycleRevisions.insert(snapshot.revision) }
        let schedule = !snapshotDrainScheduled
        snapshotDrainScheduled = true
        let fenced = hardInvalidating || observationOverflowed
        if fenced && !activeEffectRequests.isEmpty {
            effectFenceRequests[snapshot.revision] = Set(activeEffectRequests.keys)
        } else if !obsolete.isEmpty {
            effectFenceRequests[snapshot.revision] = Set(obsolete)
        }
        lock.unlock()
        if fenced { axPort.cancelAll() }
        else { for id in obsolete { axPort.cancel(requestID: id) } }
        if schedule { queue.async { [self] in drainSnapshots() } }
    }

    private func drainSnapshots() {
        for _ in 0..<16 {
            lock.lock()
            guard !pendingSnapshots.isEmpty else {
                snapshotDrainScheduled = false; lock.unlock(); return
            }
            let snapshot = pendingSnapshots.removeFirst()
            lock.unlock()
            processSnapshot(snapshot)
        }
        queue.async { [self] in drainSnapshots() }
    }

    private func processSnapshot(_ snapshot: CoreCommittedSnapshot) {
        lock.lock()
        let available = availableLocked
        let worldRecovered = recoveredWorldRevisions.remove(snapshot.revision) != nil
        let fencedRequests = effectFenceRequests.removeValue(forKey: snapshot.revision) ?? []
        let ignoredLifecycle = ignoredLifecycleRevisions.remove(snapshot.revision) != nil
        let worldEvent = snapshot.world.worldEvent
        let needsReconcile = available
            && snapshot.world.managementEnabled
            && (WorldEvent.reconcileTriggers.contains(worldEvent)
                || (AccessibilityFocusEventKind.isWindowLifecycle(worldEvent) && !ignoredLifecycle)
                || worldRecovered || (worldEvent == "app_activated"
                    && snapshot.world.at(path: "observation.world_recovered")?.boolValue == true))
        let shouldReconcile = needsReconcile && !reconcileScheduled
        if needsReconcile {
            if pendingReconciliationEvents.count < Self.observationQueueBound { pendingReconciliationEvents.append(ReconciliationEvent(snapshot)) }
            else { reconciliationEventOverflow = true }
        }
        if shouldReconcile { reconcileScheduled = true }
        lock.unlock()
        let context = Self.context(snapshot, persistenceAvailable: available)
        let focusedGoal = focusedGoalProof(snapshot, available: available)
        if let (request, stamp) = focusedGoal {
            _ = effector.confirmFocusedGoal(requestID: request.requestID, windowID: request.windowID,
                windowGeneration: request.windowGenerations[request.windowID]!, observedContext: context, timestampNanos: stamp)
        }
        effector.updateContext(context, cause: snapshot.world.at(path: "event")?.stringValue ?? "external-event",
            eventID: "revision:\(snapshot.revision)", receiptNanos: snapshot.receiptUptimeNs,
            preservingFrameRequests: continuousFrameRequests(snapshot, available: available),
            invalidatingRequestIDs: fencedRequests,
            preservingFocusRequests: Set(focusedGoal.map { [$0.0.requestID] } ?? []))
        if let (request, stamp) = focusedGoal {
            _ = effector.observeFocus(requestID: request.requestID, windowID: request.windowID,
                generation: context.observerGeneration, windowGeneration: request.windowGenerations[request.windowID], timestampNanos: stamp)
        }
        let affectedSpaces = Set((snapshot.world.at(path: "invalidation_space_keys")?.arrayValue ?? []).compactMap(\.stringValue))
        if let flight = effector.snapshot().at(path: "in_flight")?.stringValue {
            lock.lock(); let request = activeEffectRequests[flight]; lock.unlock()
            if let request, !Set(request.windowSpaceKeys.values).isDisjoint(with: affectedSpaces)
                || (request.effectKind == .frame && !Self.frameScopeMatches(request, snapshot: snapshot, available: available)) {
                effector.updateContext(context, cause: "cancel", eventID: "space-invalidation:\(snapshot.revision)", receiptNanos: snapshot.receiptUptimeNs)
            }
        }
        // A cached row on a mode/settings/result delta is never landing evidence.
        let event = snapshot.world.worldEvent
        if ["ax_window_moved", "ax_window_resized", "ax_focus_changed", "ax_window_restored", "ax_window_created"].contains(event),
           let requestID = effector.snapshot().at(path: "in_flight")?.stringValue,
           let id = snapshot.world.at(path: "observation_window_id")?.intValue,
           let stamp = snapshot.world.at(path: "observation_completed_uptime_ns")?.intValue, stamp > 0,
           let window = snapshot.world.at(path: "windows")?.arrayValue?.first(where: { $0.at(path: "window_id")?.intValue == id }),
           let frame = Frame.from(window.at(path: "frame")) {
            let observerGeneration = UInt64(max(0, snapshot.world.at(path: "observer_generation")?.intValue ?? 0))
            let windowGeneration = window.at(path: "window_generation")?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
            _ = effector.observe(requestID: requestID, windowID: String(id), frame: frame,
                generation: observerGeneration, windowGeneration: windowGeneration, timestampNanos: UInt64(stamp))
            if event == "ax_focus_changed", snapshot.world.at(path: "focus.window_id")?.intValue == id {
                _ = effector.observeFocus(requestID: requestID, windowID: String(id),
                    generation: observerGeneration, windowGeneration: windowGeneration, timestampNanos: UInt64(stamp))
            }
        }
        lock.lock(); let isLatest = latest.revision == snapshot.revision; lock.unlock()
        if isLatest, commandLaneIdle, let published = snapshot.world.at(path: "model_state") {
            desired = published
        }
        if shouldReconcile {
            queue.async { [self] in runPendingReconciliation() }
        }
        if let focus = Self.confirmedFocus(snapshot) {
            if pendingConfirmedFocus.map({ $0.observedNanos <= focus.observedNanos }) ?? true { pendingConfirmedFocus = focus }
            drainConfirmedFocus()
        }
    }

    private func runPendingReconciliation() {
        lock.lock()
        let events = pendingReconciliationEvents, overflow = reconciliationEventOverflow
        let attempt = pendingReconciliationAttempt
        pendingReconciliationEvents.removeAll(); reconciliationEventOverflow = false; pendingReconciliationAttempt = 0
        reconcileScheduled = false
        guard let first = events.first else { lock.unlock(); return }
        let requestID = UUID().uuidString
        reconciliationBatches[requestID] = ReconciliationBatch(events: events, overflow: overflow, attempt: attempt)
        lock.unlock()
        let causes = Array(Set(events.compactMap(\.lifecycleCause))).sorted()
        let arguments = JSONValue.object(first.metadata.merging([
            "source_events": .array(events.map { .object($0.metadata) }),
            "lifecycle_causes": .array(causes.map(JSONValue.string)),
            "reconciliation_source_overflow": .bool(overflow)]))
        execute(actionID: "world.reconcile", requestID: requestID, arguments: arguments, receipt: first.receipt)
    }

    /// A command refused for a checkpoint that trails current observation owes the
    /// reconcile that never landed. The refusal stays honest; the repair lets the
    /// next command plan against re-recorded identities.
    private func requestCheckpointRepair(_ snapshot: CoreCommittedSnapshot) {
        lock.lock(); let pending = !pendingReconciliationEvents.isEmpty; lock.unlock()
        if !pending { scheduleReconciliation([ReconciliationEvent(repairing: snapshot)]) }
    }

    /// Requeue owed facts ahead of newer ones; the caller holds no lock.
    private func scheduleReconciliation(_ events: [ReconciliationEvent], overflow: Bool = false, attempt: Int = 0) {
        lock.lock()
        let merged = events + pendingReconciliationEvents
        pendingReconciliationEvents = Array(merged.prefix(Self.observationQueueBound))
        reconciliationEventOverflow = reconciliationEventOverflow || overflow || merged.count > Self.observationQueueBound
        pendingReconciliationAttempt = max(pendingReconciliationAttempt, attempt)
        let schedule = !reconcileScheduled
        reconcileScheduled = true
        lock.unlock()
        if schedule { queue.async { [self] in runPendingReconciliation() } }
    }

    private func confirmedFocusScopeMatches(_ candidate: ConfirmedFocusCandidate) -> Bool {
        lock.lock(); let snapshot = latest
        let available = availableLocked; lock.unlock()
        let context = Self.context(snapshot, persistenceAvailable: available)
        guard context.trusted, context.complete, snapshot.world.managementEnabled,
              snapshot.world.at(path: "observer_epoch")?.stringValue == candidate.observerEpoch,
              context.observerGeneration == candidate.observerGeneration else { return false }
        let matches = (snapshot.world.at(path: "windows")?.arrayValue ?? []).filter { $0.at(path: "window_id")?.intValue == candidate.windowID }
        guard matches.count == 1, let window = matches.first else { return false }
        guard Arrangement.memberWindows(snapshot.world.at(path: "model_state.arrangement") ?? .object([:])).contains(where: {
            $0.at(path: "window_id")?.intValue == candidate.windowID
        }) else { return false }
        return window.at(path: "pid")?.intValue == candidate.pid
            && window.at(path: "window_generation")?.intValue == Int64(clamping: candidate.windowGeneration)
            && window.at(path: "space_key")?.stringValue == candidate.spaceKey
            && window.at(path: "display_id")?.stringValue == candidate.displayID
            && window.at(path: "eligible")?.boolValue == true && window.at(path: "space_enabled")?.boolValue == true
            && window.at(path: "space_visible")?.boolValue == true && window.at(path: "minimized")?.boolValue != true
            && window.at(path: "destroyed")?.boolValue != true
    }

    /// History updates merge into the actual checkpoint only after the command
    /// lane drains, preserving any newer interaction and accumulated resize draft.
    private func drainConfirmedFocus() {
        guard commandLaneIdle, let candidate = pendingConfirmedFocus else { return }
        pendingConfirmedFocus = nil
        guard confirmedFocusScopeMatches(candidate) else { return }
        let snapshot = server.committedSnapshot
        guard var state = snapshot.world.at(path: "model_state")?.objectValue else { return }
        let history = state["focus_history"]?.arrayValue ?? []
        if history.first == candidate.identity && state["confirmed_focus_window_id"] == .int(candidate.windowID) { return }
        state["focus_history"] = .array(Array(([candidate.identity] + history.filter {
            $0.at(path: "window_id")?.intValue != candidate.windowID
        }).prefix(10)))
        state["confirmed_focus_window_id"] = .int(candidate.windowID)
        guard let bound = Self.bindCandidate(.object(state), snapshot: snapshot) else { return }
        lock.lock(); let admission = admissionGeneration; lock.unlock()
        let source = CommandSource(actionID: "focus.confirmed", origin: "observer", inputGeneration: nil,
            receipt: candidate.observedNanos, admissionGeneration: admission)
        commitStateOnly(bound, snapshot: snapshot, requestID: "focus-history:\(candidate.observedNanos)",
            receipt: candidate.observedNanos, source: source, admission: admission, preserveModeAuthority: true,
            additionalGuard: { [weak self] in self?.confirmedFocusScopeMatches(candidate) == true ? nil : "confirmed_focus_context_changed" },
            completion: { _, _ in })
    }

    /// Canonical per-write gate, used by the real AX port. Safety release is
    /// observable here before a delayed mode notification reaches the timeline.
    func mayIssueEffect(_ request: ResidentEffectRequest) -> Bool {
        authorized(request) && effector.snapshot().at(path: "in_flight")?.stringValue == request.requestID
    }

    /// AX work binds to validated world identity, not the transient frontmost-app registration.
    /// This is the real generation used by a new targeted resolve/read; request evidence stays original.
    func observationGeneration(for request: ResidentEffectRequest) -> UInt64? {
        guard effector.snapshot().at(path: "in_flight")?.stringValue == request.requestID else { return nil }
        return validatedObservationGeneration(request)
    }

    private func authorized(_ request: ResidentEffectRequest) -> Bool {
        validatedObservationGeneration(request) != nil
    }

    private func validatedObservationGeneration(_ request: ResidentEffectRequest) -> UInt64? {
        lock.lock(); let snapshot = latest; let available = availableLocked
        let frameGeneration = activeFrameGenerations[request.requestID]; lock.unlock()
        let context = Self.context(snapshot, persistenceAvailable: available)
        if let required = request.sourceInputGeneration {
            lock.lock(); let reader = inputGenerationReader; lock.unlock()
            guard reader?() == required else { return nil }
        }
        if request.effectKind == .frame {
            return frameGeneration == context.observerGeneration
                && Self.frameScopeMatches(request, snapshot: snapshot, available: available)
                ? context.observerGeneration : nil
        }
        lock.lock(); let focusGeneration = activeFocusGenerations[request.requestID]; lock.unlock()
        if focusGeneration == context.observerGeneration,
           let issued = effector.issuedTimestamp(for: request.requestID),
           Self.focusTargetMatches(request, snapshot: snapshot, available: available),
           Self.observedFocusStamp(snapshot, issued: issued) != nil {
            return context.observerGeneration
        }
        guard context.complete, context.trusted, context.spaceEnabled,
              context.observerGeneration == request.observerGeneration,
              context.topologyRevision == request.topologyRevision,
              context.activeSpaceKey == request.activeSpaceKey else { return nil }
        let windows = (snapshot.world.at(path: "windows")?.arrayValue ?? []).filter(\.isLiveEnabledWindow)
        let requiredSpaces = Set(request.windowSpaceKeys.values)
        let scoped = requiredSpaces.isEmpty ? windows : windows.filter {
            $0.at(path: "space_key")?.stringValue.map(requiredSpaces.contains) == true
        }
        guard scoped.count == request.windowGenerations.count else { return nil }
        let valid = scoped.allSatisfy { window in
            guard let id = window.at(path: "window_id")?.intValue,
                  let generation = window.at(path: "window_generation")?.intValue, generation > 0 else { return false }
            return request.windowGenerations[String(id)] == UInt64(generation)
        }
        return valid ? context.observerGeneration : nil
    }

    private func focusedGoalProof(_ snapshot: CoreCommittedSnapshot, available: Bool) -> (ResidentEffectRequest, UInt64)? {
        guard let id = effector.snapshot().at(path: "in_flight")?.stringValue,
              let issued = effector.issuedTimestamp(for: id) else { return nil }
        lock.lock(); let request = activeEffectRequests[id]; lock.unlock()
        guard let request, let stamp = Self.freshFocusedTargetStamp(request, snapshot: snapshot, available: available, issued: issued) else { return nil }
        return (request, stamp)
    }

    private func continuousFrameRequests(_ snapshot: CoreCommittedSnapshot, available: Bool) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let generation = Self.context(snapshot, persistenceAvailable: available).observerGeneration
        return Set(activeEffectRequests.values.filter {
            activeFrameGenerations[$0.requestID] == generation
                && Self.frameScopeMatches($0, snapshot: snapshot, available: available)
        }.map(\.requestID))
    }

    /// Internal observer/recovery entry; the caller supplies an id for an
    /// observable terminal result. It is not a second mutation wire namespace.
    /// The tap's release generation is read synchronously before each effect,
    /// independently of asynchronous mode notification delivery.
    func setInputGenerationReader(_ reader: @escaping @Sendable () -> UInt64?) {
        lock.lock(); inputGenerationReader = reader; lock.unlock()
    }

    /// Progress never replaces the original event receipt or final WmResult completion.
    func setInputProgressHandler(_ handler: @escaping @Sendable (UInt64, UInt64, UInt64) -> Void) {
        lock.lock(); inputProgressHandler = handler; lock.unlock()
    }

    private func effectProgress(requestID: String, timestamp: UInt64) {
        lock.lock()
        let request = activeEffectRequests[requestID], receipt = inputReceipts[requestID]
        let generation = inputGenerations[requestID], handler = inputProgressHandler
        let snapshot = latest, available = availableLocked
        lock.unlock()
        guard let request, let receipt, let generation, request.sourceInputGeneration == generation,
              timestamp >= receipt, timestamp <= DispatchTime.now().uptimeNanoseconds,
              Self.effectScopeMatches(request, snapshot: snapshot, available: available) else { return }
        handler?(receipt, generation, timestamp)
    }

    func beginMaintenance() {
        lock.lock(); persistenceAvailable = false; admissionGeneration &+= 1; lock.unlock()
        invalidate(cause: "cancel")
        _ = server.applyWorldDelta(["event": .string("maintenance_started"), "management_enabled": .bool(false),
            "persistence_available": .bool(false), "mode": .string("default")])
    }

    func whenIOQuiescent(_ callback: @escaping @Sendable () -> Void) {
        // Drain this planning/state-only lane before checking the journal worker.
        queue.async { [self] in _ = effector.whenIOQuiescent(callback) }
    }
    func whenAXQuiescent(_ callback: @escaping @Sendable () -> Void) { _ = axPort.whenIdle(callback) }

    func resetJournal(permit: ResidentMaintenance.ResetPermit) throws -> JSONValue {
        let backup = try journal.quarantineAndReset(check: { try permit.check() })
        try permit.check()
        let requestID = "maintenance:\(permit.requestID)"
        let revision = server.currentRevision + 1
        let state: JSONValue = .object([:])
        try journal.append(.object(["type": .string("model_state_intent"), "request_id": .string(requestID),
            "revision": .int(Int64(clamping: revision)), "state": state]))
        let committed = server.applyWorldDelta(["event": .string("maintenance_model_reset"), "model_state": state,
            "recovery_policy": .string("quarantined_fresh_world_repack")], expectedRevision: revision - 1)
        guard committed.status == .accepted else { throw MaintenanceFailure(code: "MAINTENANCE.REVISION_CHANGED", message: "Authority changed during exclusive recovery", requestID: permit.requestID, epoch: permit.epoch) }
        try journal.append(.object(["type": .string("model_state_commit"), "request_id": .string(requestID),
            "revision": .int(Int64(clamping: revision)), "state": state]))
        return .object(["journal_reset": .bool(true), "quarantined_journal": backup.map(JSONValue.string) ?? .null,
            "checkpoint_revision": .int(Int64(clamping: revision)), "effects_issued": .int(0)])
    }

    func finishMaintenance(onFinished: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            desired = server.worldState.at(path: "model_state") ?? .object([:])
            lock.lock(); persistenceAvailable = true; admissionGeneration &+= 1; lock.unlock()
            _ = server.applyWorldDelta(["event": .string("maintenance_finished"), "persistence_available": .bool(true),
                "resident_unavailable_reason": .null])
            onFinished()
        }
    }

    func reconcile(requestID: String = UUID().uuidString, completion: (@Sendable (JSONValue) -> Void)? = nil) {
        let receipt = DispatchTime.now().uptimeNanoseconds
        if let completion {
            lock.lock()
            if let existing = results[requestID] {
                lock.unlock()
                if existing.at(path: "phase")?.stringValue == "completed" {
                    queue.async { [self] in completion(reconciliationProof(existing)) }
                } else { completion(ResidentReply.refused(requestID: .string(requestID), reason: "reconciliation_already_pending")) }
                return
            }
            guard reconciliationCompletions.count < 32, slots.wait(timeout: .now()) == .success else {
                lock.unlock(); completion(ResidentReply.refused(requestID: .string(requestID), reason: "command_queue_full"))
                return
            }
            let admission = admissionGeneration
            let source = CommandSource(actionID: "world.reconcile", origin: "internal_reconcile", inputGeneration: nil,
                receipt: receipt, admissionGeneration: admission)
            commandSources[requestID] = source; reconciliationCompletions[requestID] = completion
            results[requestID] = .object(source.metadata.merging(["ok": .bool(true), "request_id": .string(requestID),
                "phase": .string("queued"), "completed": .bool(false)]))
            let admittedSnapshot = latest
            lock.unlock()
            Self.recordAdmission(admittedSnapshot, source: source, requestID: requestID)
            queue.async { [self] in
                defer { slots.signal() }
                if let reason = publicationRefusal(source, admission: admission) {
                    finish(requestID: requestID, status: .refused, reason: reason); return
                }
                execute(actionID: "world.reconcile", requestID: requestID, arguments: .object([:]), receipt: receipt)
            }
            return
        }
        queue.async { [self] in
            execute(actionID: "world.reconcile", requestID: requestID,
                    arguments: .object([:]), receipt: receipt)
        }
    }

    /// Same partition admission used by interactive planning, checked after the
    /// real reconciliation result/publication. This lane owns geometry config.
    private func reconciliationProof(_ result: JSONValue) -> JSONValue {
        let verified = server.committedSnapshot
        var reason: String?
        if WmStatus(rawValue: result.at(path: "status")?.stringValue ?? "")?.isOK != true
            && !CoreRuntimeServices.isMinimumShortfall(result) {
            reason = result.at(path: "reason")?.stringValue ?? "world_reconcile_failed"
        } else {
            let world = normalizedWorld(verified.world)
            if world.at(path: "complete")?.boolValue != true { reason = "world_incomplete" }
            else if world.at(path: "trusted")?.boolValue != true { reason = "ax_untrusted" }
            else if verified.world.at(path: "management_enabled")?.boolValue == false { reason = "management_stopped" }
            else {
                let state = verified.world.at(path: "model_state") ?? .object([:])
                if let observed = ResidentPlanner.eligibleWindows(world.at(path: "windows")?.arrayValue ?? [], state: state) {
                    if case .failure(let failure) = ResidentSpacePartitions.prepare(state: state,
                        world: world, topology: world.at(path: "topology") ?? .object([:]), observed: observed, reconcile: false) {
                        reason = failure.reason
                    }
                } else { reason = "fixed_aspect_store_invalid" }
            }
        }
        return .object((result.objectValue ?? [:]).merging(["reconciliation_ready": .bool(reason == nil),
            "reconciliation_failure_reason": reason.map(JSONValue.string) ?? .null,
            "reconciliation_verified_revision": .int(Int64(clamping: verified.revision)),
            "reconciliation_verified_scope": Self.reconciliationScope(verified.world)]))
    }

    func handle(_ request: JSONObject, receipt: UInt64 = DispatchTime.now().uptimeNanoseconds,
                inputGeneration: UInt64? = nil, origin: String? = nil) -> JSONValue {
        func reject(_ reason: String) -> JSONValue {
            refusal(reason, requestID: request["request_id"]?.stringValue,
                actionID: request["action_id"]?.stringValue,
                origin: origin ?? (inputGeneration == nil ? "socket" : "input"),
                receipt: receipt, inputGeneration: inputGeneration)
        }
        guard let id = request["request_id"]?.stringValue, !id.isEmpty, id.utf8.count <= ResidentProtocolLimits.identifierBytes else { return reject("request_id_missing_or_invalid") }
        if request["op"]?.stringValue == "result" {
            lock.lock(); let existing = results[id]; lock.unlock()
            return existing ?? reject("request_unknown")
        }
        guard let action = request["action_id"]?.stringValue, Self.actionIDs.contains(action) else { return reject("unregistered_action") }
        let fingerprint = JSONValue.object(["action_id": .string(action), "args": request["args"] ?? .object([:]),
            "expected_revision": request["expected_revision"] ?? .null]).canonical()
        if let revision = request["expected_revision"], revision.intValue == nil || revision.intValue! < 0 {
            return reject("expected_revision_invalid")
        }
        lock.lock()
        if let existing = results[id] {
            let matches = fingerprints[id] == fingerprint
            lock.unlock()
            return matches ? existing : reject("request_id_conflict")
        }
        guard slots.wait(timeout: .now()) == .success else { lock.unlock(); return reject("command_queue_full") }
        let source = CommandSource(actionID: action, origin: origin ?? (inputGeneration == nil ? "socket" : "input"),
            inputGeneration: inputGeneration, receipt: receipt, admissionGeneration: admissionGeneration)
        commandSources[id] = source
        let admitted: JSONValue = .object(source.metadata.merging(["ok": .bool(true), "request_id": .string(id),
            "phase": .string("queued"), "completed": .bool(false)]))
        results[id] = admitted; fingerprints[id] = fingerprint; requestActions[id] = action
        if let inputGeneration { inputGenerations[id] = inputGeneration; inputReceipts[id] = receipt }
        let admission = admissionGeneration
        let admittedSnapshot = latest
        lock.unlock()
        Self.recordAdmission(admittedSnapshot, source: source, requestID: id)
        queue.async { [self] in
            defer { slots.signal() }
            lock.lock(); let fresh = admission == admissionGeneration; lock.unlock()
            guard fresh else { finish(requestID: id, status: .refused, reason: "queued_command_invalidated"); return }
            execute(actionID: action, requestID: id, arguments: request["args"] ?? .object([:]),
                    receipt: receipt, expectedRevision: request["expected_revision"]?.intValue.flatMap { $0 >= 0 ? UInt64($0) : nil })
        }
        return admitted
    }

    /// Menu tracking retains a Space and an authoring revision, while ordinary
    /// focus/health publications may advance the diagnostic world revision.
    /// The command lane revalidates the exact target before any planning/effect.
    func handleMenuAction(_ action: ResidentMenuAction, requestID: String = UUID().uuidString) -> JSONValue {
        lock.lock(); let snapshot = latest; lock.unlock()
        guard action.expectedRevision <= snapshot.revision else { return refusal("menu_revision_unavailable", requestID: requestID,
            actionID: action.actionID, origin: "menu") }
        var arguments = action.arguments.objectValue ?? [:]
        arguments["target_space_key"] = .string(action.target.spaceKey)
        arguments["target_display_id"] = .string(action.target.displayId)
        arguments["menu_revision"] = .int(Int64(clamping: action.expectedRevision))
        return handle(["action_id": .string(action.actionID), "request_id": .string(requestID),
            "args": .object(arguments)], origin: "menu")
    }

    /// Palette configuration is event-delivered and checked before admission.
    /// Missing files use the standard palette and fixed 1-point spacing.
    func setGeometryError(_ code: String?) {
        lock.lock(); let changed = geometryAvailable != (code == nil); geometryAvailable = code == nil
        if changed { admissionGeneration &+= 1 }; lock.unlock()
        if code != nil { axPort.cancelAll(); invalidate(cause: "geometry-invalid") }
        if changed {
            _ = server.applyWorldDelta(["event": .string(code == nil ? "geometry_configuration_valid" : "geometry_invalid"),
                "geometry_available": .bool(code == nil), "resident_unavailable_reason": code.map(JSONValue.string) ?? .null])
        }
    }

    func dispatch(_ action: ResidentInputAction, completion: @escaping @Sendable (Int) -> Void) {
        if action.phase == .keyUp {
            effector.keyUp(eventID: "key-up:\(action.generation)", receiptNanos: action.receiptUptimeNs)
            completion(0); return
        }
        let id = UUID().uuidString
        lock.lock(); callbacks[id] = completion; lock.unlock()
        let response = handle(["op": .string("act"), "action_id": .string(action.actionId), "request_id": .string(id)], receipt: action.receiptUptimeNs, inputGeneration: action.generation)
        if response.at(path: "ok")?.boolValue != true {
            lock.lock(); callbacks.removeValue(forKey: id); lock.unlock()
            completion(4)
        }
    }

    func invalidate(cause: String) {
        _ = invalidate(cause: cause, expectedAdmission: nil)
    }

    private func invalidate(cause: String, expectedAdmission: UInt64?) -> UInt64? {
        lock.lock()
        guard expectedAdmission == nil || expectedAdmission == admissionGeneration else { lock.unlock(); return nil }
        admissionGeneration &+= 1; let next = admissionGeneration; let snapshot = latest; lock.unlock()
        axPort.cancelAll()
        effector.updateContext(Self.context(snapshot, persistenceAvailable: false), cause: cause, eventID: cause, receiptNanos: DispatchTime.now().uptimeNanoseconds)
        return next
    }

    private func commandMetadata(_ requestID: String) -> JSONObject {
        lock.lock(); defer { lock.unlock() }; return commandSources[requestID]?.metadata ?? [:]
    }

    /// Pure authority-boundary gate: controller metadata and lock-free routing
    /// generation only. Never call CoreServer, AX, journal IO or the effector here.
    private func publicationRefusal(_ source: CommandSource, admission: UInt64) -> String? {
        lock.lock(); let reader = inputGenerationReader; lock.unlock()
        if let required = source.inputGeneration, reader?() != required { return "input_generation_released" }
        lock.lock(); let current = admissionGeneration; lock.unlock()
        return current == admission ? nil : "queued_command_invalidated"
    }

    private func effectPublicationRefusal(_ request: ResidentEffectRequest, source: CommandSource,
                                           admission: UInt64) -> String? {
        if let reason = publicationRefusal(source, admission: admission) { return reason }
        lock.lock(); let snapshot = latest; let available = availableLocked; lock.unlock()
        return Self.effectScopeMatches(request, snapshot: snapshot, available: available)
            ? nil : "effect_identity_or_context_changed"
    }

    private func minimumEvidenceReady(_ request: ResidentEffectRequest, evidence: [ResidentMinimumEvidence]) {
        lock.lock(); let source = commandSources[request.requestID]; lock.unlock()
        guard let source else { return }
        queue.async { [self] in
            guard pendingMinimums.count < 32 else { setMinimumStatus("minimum_learning_queue_overflow"); return }
            pendingMinimums.append(MinimumCandidate(request: request, evidence: evidence, source: source, admission: source.admissionGeneration))
        }
    }

    /// Startup publishes Running only after its reconcile completes, so its constraint
    /// proofs wait instead of being discarded; every other fence still applies on resume.
    static func startupDefersMinimumLearning(_ world: JSONValue) -> Bool {
        world.at(path: "resident_starting")?.boolValue == true && world.at(path: "resident_running")?.boolValue != true
    }

    /// Called once startup has published Running: the deferred proofs drain through the
    /// ordinary fences and their one constraint replan.
    func resumeStartupMinimums() {
        queue.async { [self] in
            guard !startupDeferredMinimums.isEmpty else { return }
            pendingMinimums.insert(contentsOf: startupDeferredMinimums, at: 0)
            startupDeferredMinimums.removeAll()
            drainMinimums()
        }
    }

    private func setMinimumStatus(_ value: String) { lock.lock(); minimumLearningStatus = value; lock.unlock() }

    /// An already admitted observational lesson survives ordinary modal release;
    /// global OFF, session/lifetime/Space/topology/trust changes still fence it.
    private func minimumPublicationRefusal(_ request: ResidentEffectRequest, expectedGeneration: UInt64? = nil,
                                           allowStarting: Bool = false) -> String? {
        lock.lock(); let snapshot = latest
        let available = availableLocked; lock.unlock()
        guard snapshot.world.managementEnabled,
              snapshot.world.at(path: "resident_running")?.boolValue != false
                || (allowStarting && Self.startupDefersMinimumLearning(snapshot.world)),
              expectedGeneration == nil || snapshot.world.at(path: "observer_generation")?.intValue == expectedGeneration.map({ Int64(clamping: $0) }),
              Self.effectScopeMatches(request, snapshot: snapshot, available: available) else { return "minimum_learning_identity_or_context_changed" }
        return nil
    }

    /// Fold into the actual current checkpoint only after all already-planned
    /// effects drain. A later plan cannot overwrite floors with its older draft.
    private func drainMinimums() {
        guard commandLaneIdle else { return }
        while !pendingMinimums.isEmpty {
            let candidate = pendingMinimums.removeFirst()
            lock.lock(); let result = results[candidate.request.requestID]; lock.unlock()
            let clamped = candidate.evidence.contains { ResidentMinimumLearning.settledClampAxes($0) != nil }
            let shaped = candidate.evidence.contains(where: ResidentMinimumLearning.settledShapeRefusal)
            let status = WmStatus(rawValue: result?.at(path: "status")?.stringValue ?? "")
            let reason = result?.at(path: "reason")?.stringValue
            let completed = status == .accepted
                || (status == .failed && reason == "minimum_constraint" && clamped)
                || (status == .failed && reason == "fixed_aspect_constraint" && shaped)
            let evidenceGeneration = candidate.evidence.map { $0.confirmationGeneration ?? $0.observedGeneration }.max()
            guard completed, minimumPublicationRefusal(candidate.request, expectedGeneration: evidenceGeneration) == nil else {
                // Proven by the startup reconcile: learning waits for Running, not for a re-proof.
                if completed, startupDeferredMinimums.count < 32, minimumPublicationRefusal(candidate.request,
                    expectedGeneration: evidenceGeneration, allowStarting: true) == nil {
                    startupDeferredMinimums.append(candidate); setMinimumStatus("minimum_learning_deferred_until_running")
                } else { setMinimumStatus("minimum_learning_obsolete") }
                continue
            }
            let snapshot = server.committedSnapshot
            guard var state = snapshot.world.at(path: "model_state")?.objectValue else { continue }
            let prior = state["minimum_sizes"] ?? .object([:])
            guard Minsize.validStore(prior) else { setMinimumStatus("minimum_store_invalid"); continue }
            let learned = ResidentMinimumLearning.learnedStore(evidence: candidate.evidence, request: candidate.request,
                store: prior, topology: normalizedWorld(snapshot.world).at(path: "topology") ?? .object([:]))
            let priorFixed = state["fixed_aspect_apps"] ?? .array([])
            guard ResidentPlanner.validFixedAspectStore(priorFixed) else { setMinimumStatus("fixed_aspect_store_invalid"); continue }
            let learnedFixed = ResidentMinimumLearning.learnedFixedAspect(evidence: candidate.evidence,
                request: candidate.request, store: priorFixed)
            guard learned != prior || learnedFixed != priorFixed else { setMinimumStatus("no_proven_floor_change"); continue }
            state["minimum_sizes"] = learned
            if learnedFixed != priorFixed { state["fixed_aspect_apps"] = learnedFixed }
            var replacedMove = false
            if clamped, candidate.request.actionID.hasPrefix("move."), state["interaction"] == nil,
               let priorInteraction = candidate.request.priorInteraction,
               let baseline = priorInteraction.at(path: "candidate.base.arrangement") {
                var previewState = state
                previewState["arrangement"] = baseline
                if var cache = previewState["space_partitions"]?.objectValue,
                   var entries = cache["partitions"]?.objectValue,
                   let priorEntries = candidate.request.priorModelState?.at(path: "space_partitions.partitions")?.objectValue {
                    let spaces = Set(candidate.request.windowSpaceKeys.values)
                    for (key, entry) in priorEntries where entry.at(path: "space_key")?.stringValue.map(spaces.contains) == true {
                        entries[key] = entry
                    }
                    cache["partitions"] = .object(entries); previewState["space_partitions"] = .object(cache)
                }
                let replacement = ResidentPlanner.replacementMoveCandidate(state: .object(previewState),
                    world: normalizedWorld(snapshot.world), priorInteraction: priorInteraction)
                if replacement.status == .accepted, let bound = Self.bindCandidate(replacement.state, snapshot: snapshot) {
                    state = bound.objectValue!; replacedMove = true
                }
            }
            let publishedMove = replacedMove
            commitStateOnly(.object(state), snapshot: snapshot, requestID: "minimum:" + candidate.request.requestID,
                receipt: candidate.evidence.map { $0.confirmationCompletedNanos ?? $0.readCompletedNanos }.max() ?? candidate.source.receipt,
                source: candidate.source, admission: candidate.admission, minimumRequest: candidate.request,
                minimumGeneration: evidenceGeneration,
                publishInteraction: replacedMove,
                completion: { [weak self] status, reason in
                    guard let self else { return }
                    setMinimumStatus(status == .accepted ? (publishedMove ? "move_preview_replaced_requires_confirmation"
                        : shaped ? "fixed_aspect_learned" : clamped ? "new_floor_learned" : "known_floor_self_healed")
                        : reason ?? "minimum_learning_refused")
                    if status == .accepted, clamped || shaped, !candidate.request.actionID.hasPrefix("move."),
                       !candidate.request.requestID.hasPrefix("minimum-replan:"),
                       !minimumAutomaticReplans.contains(candidate.request.requestID) {
                        if minimumAutomaticReplans.count >= 1024 { minimumAutomaticReplans.remove(minimumAutomaticReplans.first!) }
                        minimumAutomaticReplans.insert(candidate.request.requestID)
                        reconcile(requestID: "minimum-replan:" + candidate.request.requestID)
                    }
                })
        }
    }

    var health: JSONValue {
        lock.lock()
        let queued = results.filter { $0.value.at(path: "phase")?.stringValue == "queued" }.keys.sorted()
        let minimumStatus = minimumLearningStatus
        lock.unlock()
        var value = effector.snapshot().objectValue!
        value["controller_nonterminal_request_ids"] = .array(queued.map(JSONValue.string))
        value["minimum_learning_status"] = .string(minimumStatus)
        value["minimum_clamp_learning"] = .string("confirmed_partial_shrink")
        return .object(value)
    }

    /// The same explicit one-shot evidence event used by the real AX port.
    func expireEvidence(at timestampNanos: UInt64) { effector.expireEvidence(at: timestampNanos) }

    private func execute(actionID: String, requestID: String, arguments: JSONValue,
                         receipt: UInt64, expectedRevision: UInt64? = nil) {
        lock.lock(); requestActions[requestID] = actionID
        let isNewSource = commandSources[requestID] == nil
        let provenanceKeys = ["source_event", "source_event_revision", "source_event_receipt_uptime_ns", "source_receipt_boundary",
            "source_notification_receipt_uptime_ns", "source_notification_window_id", "lifecycle_cause", "lifecycle_causes",
            "source_events", "reconciliation_source_overflow"]
        let provenance = JSONObject(unordered: Dictionary(uniqueKeysWithValues: provenanceKeys.compactMap { key in
            arguments.at(path: key).map { (key, $0) }
        }))
        let source = commandSources[requestID] ?? CommandSource(actionID: actionID, origin: "internal_reconcile",
            inputGeneration: nil, receipt: receipt, admissionGeneration: admissionGeneration, eventProvenance: provenance)
        commandSources[requestID] = source
        let snapshot = latest; let available = availableLocked; lock.unlock()
        if isNewSource { Self.recordAdmission(snapshot, source: source, requestID: requestID) }
        if arguments.at(path: "reconciliation_source_overflow")?.boolValue == true {
            finish(requestID: requestID, status: .refused, reason: "reconciliation_source_queue_full"); return
        }
        if let expectedRevision, expectedRevision != snapshot.revision {
            finish(requestID: requestID, status: .refused, reason: "expected_revision_mismatch"); return
        }
        guard available, snapshot.world.managementEnabled else {
            finish(requestID: requestID, status: .refused, reason: "planning_or_persistence_unavailable"); return
        }
        let commutative = actionID.hasPrefix(ResidentActionIDs.resizeAdjustPrefix) || actionID == ResidentActionIDs.worldReconcile
        let cancelling = ResidentActionIDs.cancelling.contains(actionID)
        if let reason = publicationRefusal(source, admission: source.admissionGeneration) {
            finish(requestID: requestID, status: .refused, reason: reason); return
        }
        if !commutative && !cancelling && effector.snapshot().at(path: "in_flight")?.stringValue != nil {
            if !deferCommand(actionID: actionID, requestID: requestID, arguments: arguments, receipt: receipt, expectedRevision: expectedRevision) {
                finish(requestID: requestID, status: .refused, reason: "ordered_planning_queue_full")
            }
            return
        }
        let commitAdmission: UInt64
        if cancelling {
            // The command's own cancellation may advance admission once. The
            // source receipt/generation remain original; another fence still wins.
            guard let advanced = invalidate(cause: "cancel", expectedAdmission: source.admissionGeneration) else {
                finish(requestID: requestID, status: .refused, reason: "queued_command_invalidated"); return
            }
            commitAdmission = advanced
        } else { commitAdmission = source.admissionGeneration }
        // Scope updates follow admitted observation order. Before a new plan,
        // admission uses the latest committed authority, never a lagging mirror.
        effector.updateContext(Self.context(snapshot, persistenceAvailable: available),             cause: snapshot.world.at(path: "event")?.stringValue ?? "external-event",
            eventID: "plan:\(requestID)", receiptNanos: receipt,
            preservingFrameRequests: continuousFrameRequests(snapshot, available: available))
        let sourceGeneration = source.inputGeneration
        var world = normalizedWorld(snapshot.world)
        if let target = arguments.at(path: "target_space_key")?.stringValue {
            guard let display = arguments.at(path: "target_display_id")?.stringValue,
                  let context = snapshot.world.at(path: "space_contexts")?.arrayValue?.first(where: {
                      $0.at(path: "space_key")?.stringValue == target && $0.at(path: "display_id")?.stringValue == display
                          && $0.at(path: "space_identity_available")?.boolValue == true
                          && $0.at(path: "space_visible")?.boolValue == true && $0.at(path: "space_enabled")?.boolValue == true
                  }), context.at(path: "space_key")?.stringValue == target,
                  snapshot.world.at(path: "space_activation")?.objectValue?[target]?.boolValue != false else {
                finish(requestID: requestID, status: .refused, reason: "menu_target_unavailable"); return
            }
            if let id = arguments.at(path: "window_id")?.intValue {
                guard let member = snapshot.world.at(path: "windows")?.arrayValue?.first(where: {
                    $0.at(path: "window_id")?.intValue == id && $0.at(path: "space_key")?.stringValue == target
                        && $0.at(path: "display_id")?.stringValue == display && $0.at(path: "eligible")?.boolValue == true
                        && $0.at(path: "space_enabled")?.boolValue == true && $0.at(path: "space_visible")?.boolValue == true
                }) else { finish(requestID: requestID, status: .refused, reason: "member_not_available"); return }
                if let pid = arguments.at(path: "expected_pid"), pid != member.at(path: "pid") {
                    finish(requestID: requestID, status: .refused, reason: "menu_window_lifetime_changed"); return
                }
                if let lifetime = arguments.at(path: "expected_window_generation"), lifetime != member.at(path: "window_generation") {
                    finish(requestID: requestID, status: .refused, reason: "menu_window_lifetime_changed"); return
                }
                if let epoch = arguments.at(path: "expected_observer_epoch"), epoch != snapshot.world.at(path: "observer_epoch") {
                    finish(requestID: requestID, status: .refused, reason: "menu_window_lifetime_changed"); return
                }
            }
            var scoped = world.objectValue ?? [:]
            scoped["active_space_key"] = .string(target); scoped["space_enabled"] = .bool(true)
            world = .object(scoped)
        }
        var plan = ResidentPlanner.plan(actionID: actionID, state: desired, world: world, arguments: arguments)
        let preservedMove = plan.reason == "interaction_context_invalid" && actionID.hasPrefix("move.")
            && Self.moveIntentScopeMatches(desired, snapshot: snapshot)
        let replacementPreview = plan.reason == "move_candidate_stale" || (preservedMove
            && ["move.execute.auto", "move.execute.swap", "move.drop"].contains(actionID)
            && desired.at(path: "interaction.candidate") != nil)
        if replacementPreview {
            guard Self.moveIntentScopeMatches(desired, snapshot: snapshot) else {
                finish(requestID: requestID, status: .refused, reason: "move_candidate_identity_or_context_changed"); return
            }
            plan = ResidentPlanner.replacementMoveCandidate(state: desired, world: world,
                priorInteraction: desired.at(path: "interaction"))
        } else if preservedMove, var rebound = desired.objectValue,
                  var interaction = rebound["interaction"]?.objectValue {
            interaction["observer_generation"] = snapshot.world.at(path: "observer_generation")
            interaction["topology_revision"] = snapshot.world.at(path: "topology_revision")
            rebound["interaction"] = .object(interaction)
            plan = ResidentPlanner.plan(actionID: actionID, state: .object(rebound), world: world, arguments: arguments)
        }
        ResidentPerformanceTrace.shared.record("intent_resolved", fields: Self.traceFields(snapshot, source: source)
            .merging(["request_id": .string(requestID), "status": .string(plan.status.rawValue),
                "reason": plan.reason.map(JSONValue.string) ?? .null,
                "candidate_id": (plan.state.at(path: "interaction.candidate.candidate_id")
                    ?? desired.at(path: "interaction.candidate.candidate_id")) ?? .null,
                "targets": plan.targets]))
        if plan.reason == "space_partitions_require_reconcile" { requestCheckpointRepair(snapshot) }
        guard plan.status == .accepted else { finish(requestID: requestID, status: plan.status, reason: plan.reason); return }
        guard let boundState = Self.bindCandidate(plan.state, snapshot: snapshot) else {
            finish(requestID: requestID, status: .refused, reason: "move_candidate_identity_unavailable"); return
        }
        plan = ResidentPlan(status: plan.status, reason: plan.reason, state: boundState,
            targets: plan.targets, focusTarget: plan.focusTarget)
        var targets: [String: Frame] = [:]
        for (id, value) in plan.targets.objectValue ?? [:] {
            let physicalFrame = value.at(path: "effect_frame") ?? value.at(path: "frame")
            if value.at(path: "presented")?.boolValue == false, physicalFrame == nil || physicalFrame == .null { continue }
            guard let frame = Frame.from(physicalFrame) else {
                finish(requestID: requestID, status: .refused, reason: "overload_representation_unavailable"); return
            }
            let observed = snapshot.world.at(path: "windows")?.arrayValue?.first {
                $0.at(path: "window_id")?.intValue.map(String.init) == id
            }.flatMap { Frame.from($0.at(path: "frame")) }
            if observed.map({ !Geometry.frameEq($0, frame, tol: ResidentEffector.unchangedTolerance) }) ?? true { targets[id] = frame }
        }
        if targets.isEmpty && plan.focusTarget == nil {
            let persistentChanged = plan.state.at(path: "arrangement") != desired.at(path: "arrangement")
                || plan.state.at(path: "space_partitions") != desired.at(path: "space_partitions")
            if persistentChanged {
                if effector.snapshot().at(path: "in_flight")?.stringValue != nil {
                    if !deferCommand(actionID: actionID, requestID: requestID, arguments: arguments, receipt: receipt, expectedRevision: expectedRevision) {
                        finish(requestID: requestID, status: .refused, reason: "ordered_planning_queue_full")
                    }
                    return
                }
                commitStateOnly(plan.state, snapshot: snapshot, requestID: requestID, receipt: receipt,
                    source: source, admission: commitAdmission)
                return
            }
            var delta: JSONObject = ["event": .string("interaction_committed"), "model_state": plan.state,
                                    "mode": plan.state.at(path: "interaction.mode") ?? .string("default")]
            delta["mode_context_window_id"] = plan.state.at(path: "interaction.source_window_id") ?? .null
            delta["mode_context_space_key"] = world.at(path: "active_space_key") ?? .null
            delta = delta.merging(source.metadata).merging(["request_id": .string(requestID)])
            let result = server.applyWorldDelta(delta, expectedRevision: snapshot.revision, commitGuard: { [weak self] in
                guard let self else { return "controller_unavailable" }
                return self.publicationRefusal(source, admission: commitAdmission)
            })
            Self.recordPlanCommit(result, state: plan.state, source: source, snapshot: snapshot, requestID: requestID)
            if result.status == .accepted { desired = plan.state }
            finish(requestID: requestID, status: result.status,
                reason: result.status == .accepted
                    ? (replacementPreview ? "candidate_replaced_requires_confirmation" : plan.reason) : result.reason); return
        }
        let context = Self.context(snapshot, persistenceAvailable: available)
        let primaryID = plan.focusTarget.map(String.init) ?? targets.keys.sorted().first
            ?? snapshot.world.at(path: "focus.window_id")?.intValue.map(String.init) ?? ""
        let primaryFrame = targets[primaryID] ?? snapshot.world.at(path: "windows")?.arrayValue?
            .first(where: { $0.at(path: "window_id")?.intValue.map(String.init) == primaryID })
            .flatMap { Frame.from($0.at(path: "frame")) }
        guard let primaryFrame, let space = context.activeSpaceKey else {
            finish(requestID: requestID, status: .refused, reason: "target_or_space_unavailable"); return
        }
        var request = ResidentEffectRequest(requestID: requestID, actionID: actionID, windowID: primaryID,
            expectedRevision: snapshot.revision, observerGeneration: context.observerGeneration,
            activeSpaceKey: space, topologyRevision: context.topologyRevision,
            receiptNanos: receipt, frame: primaryFrame)
        request.ordered = !actionID.hasPrefix(ResidentActionIDs.resizeAdjustPrefix) && actionID != ResidentActionIDs.worldReconcile
        request.effectKind = plan.focusTarget == nil || !targets.isEmpty ? .frame : .focus
        request.requiresFocus = plan.focusTarget != nil && request.effectKind == .frame
        request.stackTopWindowIDs = Set((plan.targets.objectValue ?? [:]).compactMap { id, target -> String? in
            guard targets[id] != nil, let top = target.at(path: "stack_top_window_id")?.intValue else { return nil }
            return String(top)
        }).sorted()
        request.priorInteraction = desired.at(path: "interaction")
        request.priorModelState = desired
        request.proposedState = plan.state; request.frameTargets = targets
        request.sourceInputGeneration = sourceGeneration
        request.observerEpoch = snapshot.world.at(path: "observer_epoch")?.stringValue
        let goalIDs = Set(targets.keys).union([primaryID]).union(snapshot.world.at(path: "focus.window_id")?.intValue.map { [String($0)] } ?? [])
        let enabledWindows = (world.at(path: "windows")?.arrayValue ?? []).filter(\.isLiveEnabledWindow)
        let scopedKeys = Set(enabledWindows.filter {
            $0.at(path: "window_id")?.intValue.map { goalIDs.contains(String($0)) } == true
        }.compactMap { $0.at(path: "space_key")?.stringValue })
        for window in enabledWindows where window.at(path: "space_key")?.stringValue.map(scopedKeys.contains) == true {
            guard let id = window.at(path: "window_id")?.intValue,
                  let generation = window.at(path: "window_generation")?.intValue, generation > 0,
                  let key = window.at(path: "space_key")?.stringValue,
                  let pid = window.at(path: "pid")?.intValue, pid > 0,
                  let display = window.at(path: "display_uuid")?.stringValue ?? window.at(path: "display_id")?.stringValue else {
                finish(requestID: requestID, status: .refused, reason: "window_lifetime_unavailable"); return
            }
            request.windowGenerations[String(id)] = UInt64(generation)
            request.windowSpaceKeys[String(id)] = key
            request.windowPids[String(id)] = pid
            request.windowDisplayIDs[String(id)] = display
            if let app = Minsize.winApp(window), !app.isEmpty { request.windowApplicationKeys[String(id)] = app }
        }
        if request.effectKind == .frame { request.schedulingLane = "arrangement" }
        lock.lock(); activeRequestLifetimes[requestID] = request.windowGenerations; activeEffectRequests[requestID] = request
        if request.effectKind == .frame { activeFrameGenerations[requestID] = request.observerGeneration }
        lock.unlock()
        let admitted = effector.submit(request)
        if admitted.status == .accepted { desired = plan.state }
        else { finish(requestID: requestID, status: admitted.status, reason: admitted.reason) }
    }

    /// An identified empty/OFF partition can change its durable model without
    /// issuing a synthetic window effect. IO stays off the authority lock.
    private func commitStateOnly(_ state: JSONValue, snapshot: CoreCommittedSnapshot,
                                 requestID: String, receipt: UInt64, source: CommandSource, admission: UInt64,
                                 minimumRequest: ResidentEffectRequest? = nil,
                                 minimumGeneration: UInt64? = nil,
                                 publishInteraction: Bool = false,
                                 preserveModeAuthority: Bool = false,
                                 additionalGuard: (@Sendable () -> String?)? = nil,
                                 completion: (@Sendable (WmStatus, String?) -> Void)? = nil) {
        func conclude(_ status: WmStatus, _ reason: String?) {
            if let completion { completion(status, reason) }
            else { finish(requestID: requestID, status: status, reason: reason) }
        }
        if let reason = minimumRequest.map({ minimumPublicationRefusal($0, expectedGeneration: minimumGeneration) })
            ?? publicationRefusal(source, admission: admission) {
            conclude(.refused, reason); return
        }
        let revision = snapshot.revision + 1
        let intent: JSONValue = .object(source.metadata.merging(["type": .string("model_state_intent"),
            "request_id": .string(requestID), "revision": .int(Int64(clamping: revision)),
            "state": state, "receipt_nanos": .int(Int64(clamping: receipt))]))
        do { try stateOnlyAppend(intent, journal) }
        catch { persistenceFault("journal_append_failed"); conclude(.failed, "journal_append_failed"); return }
        let projection: JSONObject
        if preserveModeAuthority {
            projection = ["event": .string("desired_plan_committed"), "model_state": state]
        } else {
            projection = minimumRequest == nil || publishInteraction
                ? Self.modelProjection(state: state, event: "desired_plan_committed")
                : ["event": .string("minimum_sizes_learned"), "model_state": state]
        }
        let delta = projection
            .merging(["request_id": .string(requestID)]).merging(source.metadata)
        let result = server.applyWorldDelta(delta, expectedRevision: snapshot.revision, commitGuard: { [weak self] in
            guard let self else { return "controller_unavailable" }
            if let reason = additionalGuard?() { return reason }
            if let request = minimumRequest { return self.minimumPublicationRefusal(request, expectedGeneration: minimumGeneration) }
            return self.publicationRefusal(source, admission: admission)
        })
        Self.recordPlanCommit(result, state: state, source: source, snapshot: snapshot, requestID: requestID, request: minimumRequest)
        let kind = result.status == .accepted ? "model_state_commit" : "model_state_abort"
        do {
            try stateOnlyAppend(.object(source.metadata.merging(["type": .string(kind), "request_id": .string(requestID),
                "revision": .int(Int64(clamping: revision)), "state": state,
                "reason": result.reason.map(JSONValue.string) ?? .null])), journal)
        } catch {
            persistenceFault("journal_commit_failed")
            conclude(.failed, "journal_commit_failed"); return
        }
        if result.status == .accepted { desired = state }
        conclude(result.status, result.reason)
    }

    private func persistenceFault(_ reason: String) {
        lock.lock(); persistenceAvailable = false; lock.unlock()
        invalidate(cause: "persistence-failure")
        _ = server.applyWorldDelta(["event": .string("persistence_failed"),
            "persistence_available": .bool(false), "resident_unavailable_reason": .string(reason)])
    }

    private func normalizedWorld(_ raw: JSONValue) -> JSONValue {
        let context = Self.context(CoreCommittedSnapshot(revision: 0, world: raw, receiptUptimeNs: 0), persistenceAvailable: true)
        let displays = (raw.at(path: "topology")?.arrayValue ?? []).map { display -> JSONValue in
            var value = display.objectValue ?? [:]
            value["usable"] = value["usable_frame"]
            return .object(value)
        }
        let usableKnown = !displays.isEmpty && displays.allSatisfy { $0.at(path: "usable_frame_known")?.boolValue == true }
        func actualUUID(_ context: JSONValue) -> JSONValue {
            if let explicit = context.at(path: "space_uuid") { return explicit }
            guard let key = context.at(path: "space_key")?.stringValue, !key.contains("runtime:") else { return .null }
            return .string(key.hasPrefix("space:uuid:") ? String(key.dropFirst("space:uuid:".count)) : key)
        }
        let contexts = (raw.at(path: "space_contexts")?.arrayValue ?? []).map { context -> JSONValue in
            var value = context.objectValue ?? [:]
            value["space_uuid"] = actualUUID(context)
            if let display = displays.first(where: { $0.at(path: "display_id") == context.at(path: "display_id") }) {
                value["display_uuid"] = value["display_id"]
                value["display_id"] = display.at(path: "id")
            }
            if let key = value["space_key"]?.stringValue {
                value["space_enabled"] = .bool(raw.at(path: "space_activation")?.objectValue?[key]?.boolValue
                    ?? value["space_enabled"]?.boolValue ?? true)
            }
            return .object(value)
        }
        let windows = (raw.at(path: "windows")?.arrayValue ?? []).filter {
            $0.at(path: "eligible")?.boolValue == true && $0.at(path: "space_visible")?.boolValue == true
        }.map { window -> JSONValue in
            var value = window.objectValue ?? [:]
            value["space_uuid"] = actualUUID(window)
            if let display = displays.first(where: { $0.at(path: "display_id") == window.at(path: "display_id") }) {
                value["display_uuid"] = value["display_id"]
                value["display_id"] = display.at(path: "id")
                value["display"] = display.at(path: "id")
            }
            return .object(value)
        }
        let heldSpace = raw.at(path: "model_state.interaction.active_space_key")?.stringValue
        let heldSource = raw.at(path: "model_state.interaction.source_window_id")?.intValue
        let holdsSource = ["move", "resize"].contains(raw.at(path: "mode")?.stringValue ?? "")
            && windows.contains { $0.at(path: "window_id")?.intValue == heldSource
                && $0.at(path: "space_key")?.stringValue == heldSpace && $0.at(path: "space_enabled")?.boolValue == true }
        return .object(["complete": .bool(context.complete && usableKnown), "trusted": .bool(context.trusted),
            "mode": raw.at(path: "mode") ?? .null,
            "space_enabled": .bool(context.spaceEnabled), "active_space_key": (holdsSource ? heldSpace : context.activeSpaceKey).map(JSONValue.string) ?? .null,
            "observer_generation": .int(Int64(clamping: context.observerGeneration)),
            "topology_revision": .int(Int64(clamping: context.topologyRevision)),
            "topology": .object(["displays": .array(displays), "gap": .int(Int64(gap)), "outer_gap": .int(Int64(outerGap ?? gap))]),
            "space_contexts": .array(contexts), "observer_epoch": raw.at(path: "observer_epoch") ?? .null,
            "model_state_revision": raw.at(path: "model_state_revision") ?? .null,
            "windows": .array(windows), "focused_window_id": raw.at(path: "focus.window_id") ?? .null])
    }

    private func activeWindowGeneration(requestID: String, windowID: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }; return activeRequestLifetimes[requestID]?[windowID]
    }

    private func completed(_ outcome: ResidentEffectOutcome) {
        axPort.finish(requestID: outcome.requestID)
        lock.lock(); let completedRequest = activeEffectRequests[outcome.requestID]; lock.unlock()
        // Landed/fault publication finishes before the effector drains its next
        // intent. It therefore cannot race a later journal reservation.
        storeResult(outcome.requestID, value: outcome.json, status: outcome.status)
        queue.async { [self] in
            if outcome.focusConfirmed, outcome.verifiedNanos != nil, let request = completedRequest,
               let id = Int64(request.windowID), let pid = request.windowPids[request.windowID],
               let lifetime = request.windowGenerations[request.windowID], let space = request.windowSpaceKeys[request.windowID],
               let display = request.windowDisplayIDs[request.windowID], let epoch = request.observerEpoch,
               let stamp = outcome.verifiedNanos {
                pendingConfirmedFocus = ConfirmedFocusCandidate(windowID: id, pid: pid, windowGeneration: lifetime,
                    spaceKey: space, displayID: display, observerEpoch: epoch,
                    observerGeneration: outcome.observedGeneration ?? request.observerGeneration, observedNanos: stamp)
            }
            if outcome.status == .failed || outcome.status == .refused {
                desired = server.worldState.at(path: "model_state") ?? .object([:])
            }
            drainDeferredCommands()
        }
    }

    private func drainDeferredCommands() {
        while effector.snapshot().at(path: "in_flight")?.stringValue == nil, !deferredCommands.isEmpty {
            let command = deferredCommands.removeFirst()
            lock.lock(); let fresh = command.generation == admissionGeneration; lock.unlock()
            guard fresh else { finish(requestID: command.requestID, status: .refused, reason: "queued_command_invalidated"); continue }
            execute(actionID: command.actionID, requestID: command.requestID, arguments: command.arguments,
                    receipt: command.receipt, expectedRevision: command.expectedRevision)
        }
        drainMinimums()
        drainConfirmedFocus()
    }

    private func refusal(_ reason: String, requestID: String? = nil, actionID: String? = nil,
                         origin: String = "socket", receipt: UInt64? = nil, inputGeneration: UInt64? = nil) -> JSONValue {
        lock.lock(); let snapshot = latest; let admission = admissionGeneration; lock.unlock()
        let source = CommandSource(actionID: actionID ?? "unknown", origin: origin, inputGeneration: inputGeneration,
            receipt: receipt ?? DispatchTime.now().uptimeNanoseconds, admissionGeneration: admission)
        ResidentPerformanceTrace.shared.record("refusal", fields: Self.traceFields(snapshot, source: source)
            .merging(["request_id": requestID.map(JSONValue.string) ?? .null, "reason": .string(reason)]))
        return .object(["ok": .bool(false), "status": .string(WmStatus.refused.rawValue), "reason": .string(reason)])
    }

    private func finish(requestID: String, status: WmStatus, reason: String?) {
        storeResult(requestID, value: .object(["ok": .bool(status.isOK),
            "status": .string(status.rawValue), "phase": .string("completed"), "request_id": .string(requestID),
            "reason": reason.map(JSONValue.string) ?? .null, "revision": .int(Int64(clamping: server.currentRevision))]), status: status)
    }

    private func storeResult(_ id: String, value: JSONValue, status: WmStatus) {
        lock.lock()
        let source = commandSources.removeValue(forKey: id)
        let metadata = source?.metadata ?? [:]
        let effect = activeEffectRequests[id]
        let completedSnapshot = latest
        let value = JSONValue.object((value.objectValue ?? [:]).merging(metadata))
        results[id] = value
        resultOrder.append(id)
        if resultOrder.count > 1024 {
            let old = resultOrder.removeFirst()
            results.removeValue(forKey: old); fingerprints.removeValue(forKey: old)
        }
        activeRequestLifetimes.removeValue(forKey: id)
        activeEffectRequests.removeValue(forKey: id)
        activeFrameGenerations.removeValue(forKey: id)
        activeFocusGenerations.removeValue(forKey: id)
        inputGenerations.removeValue(forKey: id)
        inputReceipts.removeValue(forKey: id)
        let action = requestActions.removeValue(forKey: id)
        let callback = callbacks.removeValue(forKey: id)
        let reconciled = reconciliationCompletions.removeValue(forKey: id)
        let batch = reconciliationBatches.removeValue(forKey: id)
        lock.unlock()
        var trace = (value.objectValue ?? [:]).merging(metadata).merging(["request_id": .string(id),
            "observer_epoch": completedSnapshot.world.at(path: "observer_epoch") ?? .null,
            "topology_revision": completedSnapshot.world.at(path: "topology_revision") ?? .null])
        if let effect {
            trace = trace.merging(["window_id": .string(effect.windowID), "space_key": .string(effect.activeSpaceKey),
                "window_pids": .object(JSONObject(unordered: effect.windowPids.mapValues(JSONValue.int))),
                "window_generations": .object(JSONObject(unordered: effect.windowGenerations.mapValues { .int(Int64(clamping: $0)) })),
                "window_space_keys": .object(JSONObject(unordered: effect.windowSpaceKeys.mapValues(JSONValue.string))),
                "window_display_ids": .object(JSONObject(unordered: effect.windowDisplayIDs.mapValues(JSONValue.string))),
                "candidate_id": effect.priorInteraction?.at(path: "candidate.candidate_id") ?? .null])
        } else if let source { trace = Self.traceFields(completedSnapshot, source: source).merging(trace) }
        ResidentPerformanceTrace.shared.record(status == .refused ? "refusal" : "completion", fields: trace)
        if let stamp = value.at(path: "verified_nanos")?.intValue, stamp > 0 {
            ResidentPerformanceTrace.shared.record("verified", fields: trace, timestamp: UInt64(stamp))
        }
        var delta: JSONObject = metadata.merging(["event": .string("action_result"), "last_result": value])
        if value.at(path: "effect_kind")?.stringValue == "frame" {
            let state = server.worldState.at(path: "model_state") ?? .object([:])
            delta = Self.modelProjection(state: state, event: "action_result").merging(delta)
            if status == .failed { delta["mode"] = .string("default") }
        }
        _ = server.applyWorldDelta(delta)
        let retainedMoveSelection = ["move.cancel", "move.drop", "move.level.up", "move.level.down"].contains(action ?? "")
            && status == .accepted && server.worldState.at(path: "model_state.interaction.mode") == .string("move")
        let replacementPreview = value.at(path: "reason")?.stringValue == "candidate_replaced_requires_confirmation"
            || (action?.hasPrefix("move.") == true && value.at(path: "reason")?.stringValue == "minimum_constraint")
        callback?(retainedMoveSelection || replacementPreview ? 3 : status == .accepted ? 0 : status == .noop ? 1 : 4)
        if let reconciled { queue.async { [self] in reconciled(reconciliationProof(value)) } }
        // A reconcile that lost an authority race never applied, so the lifecycle
        // facts it carried are still owed. Replan them, bounded, on the newer world.
        if let batch, status == .refused, batch.attempt < Self.reconciliationRetryLimit,
           Self.reconciliationRaceReasons.contains(value.at(path: "reason")?.stringValue ?? "") {
            scheduleReconciliation(batch.events, overflow: batch.overflow, attempt: batch.attempt + 1)
        }
    }

}
