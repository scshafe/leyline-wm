import Foundation
import LeylineModel

struct ResidentEffectContext: Sendable, Equatable {
    var revision: UInt64
    var observerGeneration: UInt64
    var activeSpaceKey: String?
    var topologyRevision: UInt64
    var trusted: Bool
    var complete: Bool
    var spaceEnabled: Bool
}

enum ResidentEffectKind: String, Sendable { case frame, focus }

struct ResidentEffectRequest: Sendable {
    let requestID: String
    let actionID: String
    let windowID: String
    let expectedRevision: UInt64
    let observerGeneration: UInt64
    let activeSpaceKey: String
    let topologyRevision: UInt64
    let receiptNanos: UInt64
    let frame: Frame
    var relativeWidthDelta: Double? = nil
    var relativeHeightDelta: Double? = nil
    var ordered: Bool = false
    var effectKind: ResidentEffectKind = .frame
    /// A member selection may reframe the newly presented top and focus it in
    /// one journaled goal. Both independent observations must land.
    var requiresFocus = false
    var stackTopWindowIDs: [String] = []
    var priorInteraction: JSONValue? = nil
    var priorModelState: JSONValue? = nil
    var proposedState: JSONValue? = nil
    var frameTargets: [String: Frame] = [:]
    var schedulingLane: String? = nil
    var windowGenerations: [String: UInt64] = [:]
    var windowSpaceKeys: [String: String] = [:]
    var windowPids: [String: Int64] = [:]
    var windowDisplayIDs: [String: String] = [:]
    var windowApplicationKeys: [String: String] = [:]
    var observerEpoch: String? = nil
    var sessionGeneration: UInt64? = nil
    var sourceInputGeneration: UInt64? = nil

    var fingerprint: String {
        JSONValue.object([
            "action_id": .string(actionID), "window_id": .string(windowID),
            "expected_revision": .int(Int64(expectedRevision)),
            "observer_generation": .int(Int64(observerGeneration)),
            "active_space_key": .string(activeSpaceKey),
            "topology_revision": .int(Int64(topologyRevision)), "frame": frame.json,
            "relative_width_delta": relativeWidthDelta.map(JSONValue.double) ?? .null,
            "relative_height_delta": relativeHeightDelta.map(JSONValue.double) ?? .null,
            "ordered": .bool(ordered),
            "effect_kind": .string(effectKind.rawValue),
            "requires_focus": .bool(requiresFocus), "prior_interaction": priorInteraction ?? .null,
            "stack_top_window_ids": .array(stackTopWindowIDs.map(JSONValue.string)),
            "prior_model_state": priorModelState ?? .null,
            "proposed_state": proposedState ?? .null,
            "frame_targets": .object(JSONObject(unordered: frameTargets.mapValues(\.json))),
            "scheduling_lane": schedulingLane.map(JSONValue.string) ?? .null,
            "source_input_generation": sourceInputGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
            "window_space_keys": .object(JSONObject(unordered: windowSpaceKeys.mapValues(JSONValue.string))),
            "window_pids": .object(JSONObject(unordered: windowPids.mapValues(JSONValue.int))),
            "window_display_ids": .object(JSONObject(unordered: windowDisplayIDs.mapValues(JSONValue.string))),
            "window_application_keys": .object(JSONObject(unordered: windowApplicationKeys.mapValues(JSONValue.string))),
            "observer_epoch": observerEpoch.map(JSONValue.string) ?? .null,
            "session_generation": sessionGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
            "window_generations": .object(JSONObject(unordered: windowGenerations.mapValues { .int(Int64(clamping: $0)) })),
        ]).canonical()
    }
}

struct ResidentEffectOutcome: Sendable {
    let requestID: String
    let status: WmStatus
    let reason: String?
    let revision: UInt64
    let generation: UInt64
    let phase: String
    let requestedFrame: Frame?
    let landedFrame: Frame?
    let receiptNanos: UInt64
    let effectIssuedNanos: UInt64?
    let firstMatchingObservationNanos: UInt64?
    let verifiedNanos: UInt64?
    let effectKind: ResidentEffectKind
    let focusConfirmed: Bool
    let requestedFrames: [String: Frame]
    let landedFrames: [String: Frame]
    let requestedGeneration: UInt64
    let observedGeneration: UInt64?
    let desiredStateCommittedRevision: UInt64?

    var json: JSONValue {
        func nanos(_ value: UInt64?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }
        return .object([
            "request_id": .string(requestID), "status": .string(status.rawValue),
            "reason": reason.map(JSONValue.string) ?? .null, "revision": .int(Int64(revision)),
            "observer_generation": .int(Int64(generation)), "phase": .string(phase),
            "requested_frame": requestedFrame?.json ?? .null, "landed_frame": landedFrame?.json ?? .null,
            "receipt_nanos": nanos(receiptNanos), "effect_issued_nanos": nanos(effectIssuedNanos),
            "first_matching_observation_nanos": nanos(firstMatchingObservationNanos),
            "verified_nanos": nanos(verifiedNanos), "visible_evidence": .bool(false),
            "effect_kind": .string(effectKind.rawValue), "focus_confirmed": .bool(focusConfirmed),
            "requested_frames": .object(JSONObject(unordered: requestedFrames.mapValues(\.json))),
            "landed_frames": .object(JSONObject(unordered: landedFrames.mapValues(\.json))),
            "requested_observer_generation": .int(Int64(clamping: requestedGeneration)),
            "observed_observer_generation": observedGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
            "desired_state_committed_revision": desiredStateCommittedRevision.map { .int(Int64(clamping: $0)) } ?? .null,
        ])
    }
}

/// Canonical observer supplies window identity; this port performs ONLY the targeted operation.
/// A setter acknowledgment is not landed evidence. Notifications/readback call observe separately.
protocol ResidentEffectorPort: AnyObject, Sendable {
    func issue(request: ResidentEffectRequest, frame: Frame,
               completion: @escaping @Sendable (String?) -> Void)
    func cancel(requestID: String)
}

protocol ResidentEffectorJournal: AnyObject, Sendable {
    func append(_ record: JSONValue) throws
}

/// @canonical resident_effector -- owner/precondition gates, journal before effect, targeted landing.
/// A serial worker handles IO; the state lock never encompasses journal IO or an AX read/write.
/// Queueing and immutable outcome publication remain responsive to slow external ports.
final class ResidentEffector: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "leylined.resident.effector.io")
    private let journal: any ResidentEffectorJournal
    private let port: any ResidentEffectorPort
    private let now: @Sendable () -> UInt64
    private let onOutcome: @Sendable (ResidentEffectOutcome) -> Void
    private let onPersistenceFault: @Sendable (String) -> Void
    private let onProgress: @Sendable (String, UInt64) -> Void
    private let onMinimumEvidence: @Sendable (ResidentEffectRequest, [ResidentMinimumEvidence]) -> Void
    private let commitJournaledPlan: @Sendable (ResidentEffectRequest, Frame, UInt64) -> UInt64?
    private var context: ResidentEffectContext
    private var scheduler: CommandScheduling
    private var requests: [String: ResidentEffectRequest] = [:]
    private var fingerprints: [String: String] = [:]
    private var outcomes: [String: ResidentEffectOutcome] = [:]
    private var completedIDs: [String] = []
    private var issued: [String: UInt64] = [:]
    private var validatedFrameGenerations: [String: UInt64] = [:]
    private var validatedFocusGenerations: [String: UInt64] = [:]
    private var committedRevisions: [String: UInt64] = [:]
    private var committingRequests: Set<String> = []
    private struct DeferredCancellation {
        let reason: String
        let requestedFrame: Frame?
    }
    private var deferredCancellations: [String: DeferredCancellation] = [:]
    private var firstMatched: [String: UInt64] = [:]
    private var matchedSourceStamps: [String: [String: UInt64]] = [:]
    private var minimumEvidence: [String: [String: ResidentMinimumEvidence]] = [:]
    private var unprovenMinimumClamps = 0
    private var setterAcknowledged: Set<String> = []
    private var observedFrames: [String: Frame] = [:]
    private var observedFocus: Set<String> = []
    private var focusIssued: [String: UInt64] = [:]
    private var observedTargets: [String: [String: Frame]] = [:]
    private var matchingTargets: [String: Set<String>] = [:]
    private var progressTargets: [String: Set<String>] = [:]
    private var observedGenerations: [String: UInt64] = [:]
    private var workerRunning = false
    private var quiescentCallbacks: [@Sendable () -> Void] = []
    private var workerPending: CommandScheduling.Intent?
    private var replanAttempts: [String: Int] = [:]
    private var replanCount = 0
    private var lastContextCause = "bootstrap"
    private var gateRefusalCount = 0
    private let replayCapacity = 1024
    let evidenceDeadlineNanos: UInt64
    private(set) var evidenceReadCount = 0

    init(context: ResidentEffectContext,
         journal: any ResidentEffectorJournal, port: any ResidentEffectorPort,
         evidenceDeadlineNanos: UInt64 = 1_000_000_000,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         commitJournaledPlan: @escaping @Sendable (ResidentEffectRequest, Frame, UInt64) -> UInt64? = { _, _, revision in revision + 1 },
         onPersistenceFault: @escaping @Sendable (String) -> Void = { _ in },
         onProgress: @escaping @Sendable (String, UInt64) -> Void = { _, _ in },
         onMinimumEvidence: @escaping @Sendable (ResidentEffectRequest, [ResidentMinimumEvidence]) -> Void = { _, _ in },
         onOutcome: @escaping @Sendable (ResidentEffectOutcome) -> Void = { _ in }) {
        precondition(evidenceDeadlineNanos > 0)
        self.context = context
        self.journal = journal; self.port = port; self.now = now; self.onOutcome = onOutcome
        self.commitJournaledPlan = commitJournaledPlan
        self.onPersistenceFault = onPersistenceFault
        self.onProgress = onProgress
        self.onMinimumEvidence = onMinimumEvidence
        self.evidenceDeadlineNanos = evidenceDeadlineNanos
        scheduler = CommandScheduling(generation: context.observerGeneration)
    }

    /// Returns an admission/refusal immediately. Completion is a separate generation-checked event.
    /// Replay is bounded to this epoch; reusing a request id with different input refuses.
    @discardableResult
    func submit(_ request: ResidentEffectRequest) -> ResidentEffectOutcome {
        lock.lock()
        if let fingerprint = fingerprints[request.requestID] {
            if fingerprint != request.fingerprint { gateRefusalCount += 1 }
            let value = fingerprint == request.fingerprint
                ? outcomes[request.requestID]!
                : outcome(request, status: .refused, reason: "request_id_conflict", phase: "admission")
            lock.unlock(); return value
        }
        if let reason = refusal(request, requireRevision: true) {
            let value = outcome(request, status: .refused, reason: reason, phase: "admission")
            gateRefusalCount += 1; fingerprints[request.requestID] = request.fingerprint; rememberCompletion(value)
            lock.unlock(); return value
        }
        let admission: CommandScheduling.Admission
        if request.relativeWidthDelta != nil || request.relativeHeightDelta != nil {
            admission = scheduler.admitRelativeResize(
                requestID: request.requestID, lane: request.schedulingLane ?? request.windowID,
                generation: request.observerGeneration, receiptNanos: request.receiptNanos,
                baseline: request.frame, widthDelta: request.relativeWidthDelta ?? 0,
                heightDelta: request.relativeHeightDelta ?? 0)
        } else {
            admission = scheduler.admit(.init(requestID: request.requestID, lane: request.schedulingLane ?? request.windowID,
                generation: request.observerGeneration, receiptNanos: request.receiptNanos,
                desiredFrame: request.frame, ordered: request.ordered))
        }
        guard admission.accepted else {
            let value = outcome(request, status: .refused, reason: admission.reason, phase: "admission")
            fingerprints[request.requestID] = request.fingerprint; rememberCompletion(value)
            lock.unlock(); return value
        }
        requests[request.requestID] = request; fingerprints[request.requestID] = request.fingerprint
        let value = outcome(request, status: .accepted, reason: nil, phase: "queued")
        outcomes[request.requestID] = value
        var superseded: ResidentEffectOutcome?
        if let id = admission.supersededRequestID, let old = requests[id] {
            superseded = outcome(old, status: .noop, reason: "superseded_pending", phase: "completed")
            rememberCompletion(superseded!)
        }
        let next = scheduler.beginNext()
        lock.unlock()
        if let superseded { onOutcome(superseded) }
        if let next { start(next) }
        return value
    }

    /// Invalidation cancels pending intent and marks issued work obsolete before another issue.
    /// Committed/issued work fails with retained evidence; untouched work refuses. A callback
    /// already committing resolves its terminal status on return, outside the state lock.
    func updateContext(_ replacement: ResidentEffectContext,
                       cause: String, eventID: String, receiptNanos: UInt64,
                       preservingFrameRequests: Set<String> = [], invalidatingRequestIDs: Set<String> = [],
                       preservingFocusRequests: Set<String> = []) {
        lock.lock()
        let explicitlyFenced = scheduler.inFlight.map { invalidatingRequestIDs.contains($0.requestID) } == true
            || scheduler.pending.contains { invalidatingRequestIDs.contains($0.requestID) }
        let changed = explicitlyFenced || replacement.observerGeneration != context.observerGeneration
            || replacement.activeSpaceKey != context.activeSpaceKey
            || replacement.topologyRevision != context.topologyRevision
            || !replacement.trusted || !replacement.complete || !replacement.spaceEnabled
            || cause == "escape" || cause == "cancel" || cause == "space-off"
        context = replacement
        lastContextCause = cause
        var cancelled: [ResidentEffectOutcome] = []
        var cancelIDs: [String] = []
        var next: CommandScheduling.Intent?
        if changed {
            let priorMailbox = workerPending
            workerPending = nil
            let intents = (scheduler.inFlight.map { [$0] } ?? []) + scheduler.pending
            let priorFlight = scheduler.inFlight?.requestID
            let frames = Dictionary(uniqueKeysWithValues: intents.map { ($0.requestID, $0.desiredFrame) })
            let retained = Set(preservingFrameRequests.union(preservingFocusRequests).filter { id in
                guard let request = requests[id] else { return false }
                let eligible = request.effectKind == .frame && preservingFrameRequests.contains(id)
                    || (request.effectKind == .focus && preservingFocusRequests.contains(id) && issued[id] != nil)
                return eligible && !request.windowGenerations.isEmpty
                    && !invalidatingRequestIDs.contains(id)
                    && request.topologyRevision == replacement.topologyRevision
                    && replacement.trusted && replacement.complete && replacement.spaceEnabled
                    && !["escape", "cancel", "space-off"].contains(cause)
            })
            for id in scheduler.invalidate(generation: replacement.observerGeneration,
                    cause: cause, eventID: eventID, receiptNanos: receiptNanos) {
                if let request = requests[id] {
                    if retained.contains(id) {
                        if request.effectKind == .frame { validatedFrameGenerations[id] = replacement.observerGeneration }
                        else { validatedFocusGenerations[id] = replacement.observerGeneration }
                        continue
                    }
                    cancelIDs.append(id)
                    let cancellation = DeferredCancellation(reason: "invalidated_" + cause,
                        requestedFrame: frames[id] ?? nil)
                    if committingRequests.contains(id) {
                        deferredCancellations[id] = cancellation
                    } else {
                        let value = cancellationOutcome(request, cancellation: cancellation)
                        rememberCompletion(value); cancelled.append(value)
                    }
                }
            }
            // The original requests/fingerprints and landed evidence remain untouched.
            // Re-admit their exact accumulated intents under the newly validated generation.
            for intent in intents where retained.contains(intent.requestID) {
                let rebound = CommandScheduling.Intent(requestID: intent.requestID, lane: intent.lane,
                    generation: replacement.observerGeneration, receiptNanos: intent.receiptNanos,
                    desiredFrame: intent.desiredFrame, ordered: intent.ordered)
                precondition(scheduler.admit(rebound).accepted, "validated_frame_rebind_cannot_expand_queue")
                if intent.requestID == priorFlight {
                    _ = scheduler.beginNext()
                    if priorMailbox?.requestID == intent.requestID { workerPending = rebound }
                }
            }
            if scheduler.inFlight == nil { next = scheduler.beginNext() }
        } else { scheduler.recordCause(cause: cause, eventID: eventID, receiptNanos: receiptNanos) }
        lock.unlock()
        for id in cancelIDs { port.cancel(requestID: id) }
        for value in cancelled { onOutcome(value) }
        if let next { start(next) }
    }

    func keyUp(eventID: String, receiptNanos: UInt64) {
        lock.lock(); scheduler.keyUp(eventID: eventID, receiptNanos: receiptNanos); lock.unlock()
    }

    /// A handoff may preserve only the active already-issued goal, never pending/journal-only intent.
    func issuedTimestamp(for requestID: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return scheduler.inFlight?.requestID == requestID ? issued[requestID] : nil
    }

    /// Minimum provenance is admitted separately from frame landing. Unproven
    /// clamps keep the effect's honest mismatch/timeout result and create no floor.
    @discardableResult
    func observeMinimumEvidence(_ evidence: ResidentMinimumEvidence) -> Bool {
        lock.lock()
        let id = evidence.write.requestID
        guard let flight = scheduler.inFlight, flight.requestID == id,
              let request = requests[id], let stamp = issued[id] else { lock.unlock(); return false }
        if let refusal = ResidentMinimumLearning.refusal(evidence, request: request,
            currentGeneration: context.observerGeneration, issuedNanos: stamp, now: now()) {
            if refusal == "minimum_clamp_unproven" { unprovenMinimumClamps += 1 }
            lock.unlock()
            return false
        }
        minimumEvidence[id, default: [:]][evidence.write.windowID] = evidence
        if ResidentMinimumLearning.settledClampAxes(evidence) != nil {
            let observed = evidence.confirmationFrame ?? evidence.observed
            observedTargets[id, default: [:]][evidence.write.windowID] = observed
            observedGenerations[id] = context.observerGeneration
            if evidence.write.windowID == request.windowID { observedFrames[id] = observed }
        }
        let constrained = setterAcknowledged.contains(id) && minimumConstrained(request, primaryFrame: flight.desiredFrame)
        lock.unlock()
        if constrained { complete(requestID: id, status: .failed, reason: "minimum_constraint", verifiedNanos: nil) }
        return true
    }

    /// Independently targeted notification/readback evidence; never called from a setter reply.
    /// Matching AX observation is reported explicitly, without fabricating physical visibility.
    @discardableResult
    func observe(requestID: String, windowID: String, frame: Frame,
                 generation: UInt64, windowGeneration: UInt64? = nil,
                 timestampNanos: UInt64, tolerance: Double = 1) -> Bool {
        lock.lock()
        let receivedAt = now()
        guard let flight = scheduler.inFlight, flight.requestID == requestID,
              flight.generation == generation,
              context.observerGeneration == generation,
              requests[requestID]?.effectKind == .frame,
              let issueTime = issued[requestID], timestampNanos >= issueTime, timestampNanos <= receivedAt,
              let request = requests[requestID],
              let desired = targetFrames(request, primaryFrame: flight.desiredFrame)[windowID] else { lock.unlock(); return false }
        if let expected = request.windowGenerations[windowID], expected != windowGeneration { lock.unlock(); return false }
        evidenceReadCount += 1
        observedGenerations[requestID] = generation
        observedTargets[requestID, default: [:]][windowID] = frame
        if windowID == request.windowID { observedFrames[requestID] = frame }
        guard Geometry.frameEq(desired, frame, tol: tolerance) else {
            matchingTargets[requestID]?.remove(windowID)
            let constrained = setterAcknowledged.contains(requestID) && minimumConstrained(request, primaryFrame: flight.desiredFrame)
            lock.unlock()
            if constrained { complete(requestID: requestID, status: .failed, reason: "minimum_constraint", verifiedNanos: nil) }
            return false
        }
        firstMatched[requestID] = firstMatched[requestID] ?? timestampNanos
        recordMatchedSourceStamp(requestID: requestID, windowID: windowID, timestampNanos: timestampNanos)
        matchingTargets[requestID, default: []].insert(windowID)
        let progressed = request.windowGenerations[windowID] != nil && timestampNanos <= now()
            && progressTargets[requestID, default: []].insert(windowID).inserted
        let acknowledged = setterAcknowledged.contains(requestID) && goalObserved(request, primaryFrame: flight.desiredFrame)
        let constrained = setterAcknowledged.contains(requestID) && minimumConstrained(request, primaryFrame: flight.desiredFrame)
        lock.unlock()
        if progressed { onProgress(requestID, timestampNanos) }
        if acknowledged { complete(requestID: requestID, status: .accepted, reason: nil, verifiedNanos: receivedAt) }
        else if constrained { complete(requestID: requestID, status: .failed, reason: "minimum_constraint", verifiedNanos: nil) }
        return true
    }

    /// Targeted focused-window AX notification/readback confirms navigation independently of AXRaise.
    /// A final focus phase follows all stack-front raises, clearing earlier focus
    /// evidence so it cannot verify the final goal after an intervening raise.
    func noteFocusIssued(requestID: String, timestampNanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard scheduler.inFlight?.requestID == requestID, issued[requestID].map({ timestampNanos >= $0 }) == true,
              requests[requestID].map({ $0.effectKind == .focus || $0.requiresFocus }) == true else { return }
        focusIssued[requestID] = timestampNanos
        observedFocus.remove(requestID)
    }

    /// Targeted focused-window AX notification/readback confirms navigation independently of AXRaise.
    @discardableResult
    func observeFocus(requestID: String, windowID: String, generation: UInt64,
                      windowGeneration: UInt64? = nil, timestampNanos: UInt64) -> Bool {
        lock.lock()
        let receivedAt = now()
        guard let flight = scheduler.inFlight, flight.requestID == requestID,
              requests[requestID]?.windowID == windowID, flight.generation == generation,
              context.observerGeneration == generation, let request = requests[requestID],
              request.effectKind == .focus || request.requiresFocus,
              let issueTime = focusIssued[requestID] ?? issued[requestID], timestampNanos >= issueTime, timestampNanos <= receivedAt else { lock.unlock(); return false }
        if let expected = requests[requestID]?.windowGenerations[windowID], expected != windowGeneration { lock.unlock(); return false }
        evidenceReadCount += 1
        observedGenerations[requestID] = generation
        observedFocus.insert(requestID); firstMatched[requestID] = firstMatched[requestID] ?? timestampNanos
        recordMatchedSourceStamp(requestID: requestID, windowID: windowID, timestampNanos: timestampNanos)
        let progressed = requests[requestID]?.windowGenerations[windowID] != nil && timestampNanos <= now()
            && progressTargets[requestID, default: []].insert(windowID).inserted
        let acknowledged = setterAcknowledged.contains(requestID) && goalObserved(request, primaryFrame: flight.desiredFrame)
        lock.unlock()
        if progressed { onProgress(requestID, timestampNanos) }
        if acknowledged { complete(requestID: requestID, status: .accepted, reason: nil, verifiedNanos: now()) }
        return true
    }

    /// Own cross-app navigation can replace the observer generation before its focus callback.
    /// This completes an independently observed goal, without retagging the original callback:
    /// requested and observed generations remain explicit. Exact lifetime, Space, topology,
    /// trust/completeness and post-issue readback are required; cancellation or missing ack refuses.
    @discardableResult
    func confirmFocusedGoal(requestID: String, windowID: String, windowGeneration: UInt64,
                            observedContext: ResidentEffectContext, timestampNanos: UInt64) -> Bool {
        lock.lock()
        let receivedAt = now()
        guard let flight = scheduler.inFlight, flight.requestID == requestID,
              let request = requests[requestID], request.effectKind == .focus,
              request.windowID == windowID,
              flight.generation == (validatedFocusGenerations[requestID] ?? request.observerGeneration),
              scheduler.generation == flight.generation, context.observerGeneration == flight.generation,
              observedContext.observerGeneration > request.observerGeneration,
              observedContext.observerGeneration >= flight.generation,
              request.windowGenerations[windowID] == windowGeneration,
              observedContext.activeSpaceKey == (request.windowSpaceKeys[windowID] ?? request.activeSpaceKey),
              observedContext.topologyRevision == request.topologyRevision,
              observedContext.trusted, observedContext.complete, observedContext.spaceEnabled,
              refusal(request, requireRevision: false) == nil,
              let issueTime = focusIssued[requestID] ?? issued[requestID], timestampNanos >= issueTime, timestampNanos <= receivedAt,
              setterAcknowledged.contains(requestID),
              scheduler.finish(requestID: requestID, generation: flight.generation) else {
            lock.unlock(); return false
        }
        evidenceReadCount += 1; observedFocus.insert(requestID)
        observedGenerations[requestID] = observedContext.observerGeneration
        firstMatched[requestID] = timestampNanos
        recordMatchedSourceStamp(requestID: requestID, windowID: windowID, timestampNanos: timestampNanos)
        let progressed = timestampNanos <= now() && progressTargets[requestID, default: []].insert(windowID).inserted
        context = observedContext; lastContextCause = "own-focus"
        workerPending = nil
        let pendingFrames = Dictionary(uniqueKeysWithValues: scheduler.pending.map { ($0.requestID, $0.desiredFrame) })
        let cancelledIDs = scheduler.invalidate(generation: observedContext.observerGeneration,
            cause: "own-focus", eventID: requestID, receiptNanos: timestampNanos)
        let value = outcome(request, status: .accepted, reason: nil, phase: "completed",
            verifiedNanos: verificationTimestamp(request))
        rememberCompletion(value)
        var cancelled: [ResidentEffectOutcome] = []
        for id in cancelledIDs {
            guard let old = requests[id] else { continue }
            let refusal = cancellationOutcome(old, cancellation: .init(
                reason: "observer_generation_changed_by_own_focus", requestedFrame: pendingFrames[id] ?? nil))
            rememberCompletion(refusal); cancelled.append(refusal)
        }
        lock.unlock()
        if progressed { onProgress(requestID, timestampNanos) }
        for refusal in cancelled { port.cancel(requestID: refusal.requestID); onOutcome(refusal) }
        onOutcome(value)
        return true
    }

    /// Deadline invocation is explicit; no retry/settle/poll loop exists in the effector.
    func expireEvidence(at timestampNanos: UInt64) {
        lock.lock()
        let expired = scheduler.inFlight.flatMap { flight -> String? in
            guard let stamp = issued[flight.requestID], timestampNanos >= stamp,
                  timestampNanos - stamp >= evidenceDeadlineNanos else { return nil }
            return flight.requestID
        }
        let clamped = expired.map { id in (minimumEvidence[id] ?? [:]).values.contains { ResidentMinimumLearning.settledClampAxes($0) != nil } } == true
        lock.unlock()
        if let expired { complete(requestID: expired, status: .failed, reason: clamped ? "minimum_constraint" : "targeted_evidence_timeout", verifiedNanos: nil) }
    }

    func snapshot() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object([
            "in_flight": scheduler.inFlight.map { .string($0.requestID) } ?? .null,
            "pending_count": .int(Int64(scheduler.pending.count)),
            "pending_request_ids": .array(scheduler.pending.map { .string($0.requestID) }),
            "issued_request_ids": .array(issued.keys.sorted().map(JSONValue.string)),
            "unproven_minimum_clamps": .int(Int64(unprovenMinimumClamps)),
            "committing_request_ids": .array(committingRequests.sorted().map(JSONValue.string)),
            "committed_request_revisions": .object(JSONObject(unordered: committedRevisions.mapValues { .int(Int64(clamping: $0)) })),
            "coalesced_intents": .int(Int64(scheduler.coalescedCount)),
            "refusals": .int(Int64(scheduler.refusedCount + gateRefusalCount)),
            "evidence_reads": .int(Int64(evidenceReadCount)), "enumeration_count": .int(0),
            "journal_worker_running": .bool(workerRunning), "journal_worker_pending": .int(workerPending == nil ? 0 : 1),
            "replans": .int(Int64(replanCount)),
            "shell_spawn_count": .int(0), "jq_spawn_count": .int(0),
            "generation_causes": .array(scheduler.causes.map { .object([
                "generation": .int(Int64($0.generation)), "cause": .string($0.cause),
                "event_id": .string($0.eventID), "receipt_nanos": .int(Int64($0.receiptNanos))]) }),
        ])
    }

    private func refusal(_ request: ResidentEffectRequest, requireRevision: Bool) -> String? {
        guard context.trusted else { return "ax_untrusted" }
        guard context.complete else { return "world_incomplete" }
        guard context.spaceEnabled else { return "space_disabled" }
        guard let space = context.activeSpaceKey, !space.isEmpty else { return "active_space_unknown" }
        let continuedFrame = request.effectKind == .frame
            && validatedFrameGenerations[request.requestID] == context.observerGeneration
        let continuedFocus = request.effectKind == .focus
            && validatedFocusGenerations[request.requestID] == context.observerGeneration
            && (request.windowSpaceKeys[request.windowID] ?? request.activeSpaceKey) == space
        guard request.activeSpaceKey == space || continuedFrame || continuedFocus else { return "active_space_mismatch" }
        guard request.observerGeneration == context.observerGeneration || continuedFrame || continuedFocus else { return "observer_generation_mismatch" }
        guard request.topologyRevision == context.topologyRevision else { return "topology_revision_mismatch" }
        guard !requireRevision || request.expectedRevision == context.revision else { return "expected_revision_mismatch" }
        guard !request.requestID.isEmpty, !request.windowID.isEmpty,
              request.frame.x.isFinite, request.frame.y.isFinite,
              request.frame.w.isFinite, request.frame.h.isFinite,
              request.frame.w > 0, request.frame.h > 0 else { return "invalid_effect_request" }
        if !request.frameTargets.isEmpty && (request.relativeWidthDelta != nil || request.relativeHeightDelta != nil) {
            return "relative_batch_requires_accumulated_plan"
        }
        if request.frameTargets.contains(where: { id, frame in
            id.isEmpty || !frame.x.isFinite || !frame.y.isFinite || !frame.w.isFinite || !frame.h.isFinite
                || frame.w <= 0 || frame.h <= 0 }) { return "invalid_effect_batch" }
        return nil
    }

    @discardableResult
    func whenIOQuiescent(_ callback: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard quiescentCallbacks.count < 8 else { lock.unlock(); return false }
        if !workerRunning && workerPending == nil { lock.unlock(); callback(); return true }
        quiescentCallbacks.append(callback)
        lock.unlock()
        return true
    }

    private func start(_ intent: CommandScheduling.Intent) {
        lock.lock()
        guard scheduler.inFlight?.requestID == intent.requestID else { lock.unlock(); return }
        workerPending = intent
        let shouldLaunch = !workerRunning
        workerRunning = true
        lock.unlock()
        if shouldLaunch { worker.async { [self] in drainJournalWorker() } }
    }

    /// Dispatch owns one running worker, not one queued block per start. Repeated cancel/restart
    /// while storage is blocked replaces this one pending mailbox slot and cannot grow IO backlog.
    private func drainJournalWorker() {
        while true {
            lock.lock()
            guard let intent = workerPending else {
                workerRunning = false
                let callbacks = quiescentCallbacks; quiescentCallbacks.removeAll()
                lock.unlock()
                for callback in callbacks { callback() }
                return
            }
            workerPending = nil
            lock.unlock()
            processJournaledIntent(intent)
        }
    }

    private func processJournaledIntent(_ intent: CommandScheduling.Intent) {
            lock.lock()
            guard scheduler.inFlight?.requestID == intent.requestID,
                  let request = requests[intent.requestID], let frame = intent.desiredFrame else { lock.unlock(); return }
            let invalid = refusal(request, requireRevision: false)
            let plannedRevision = context.revision + 1
            lock.unlock()
            if let invalid { complete(requestID: request.requestID, status: .refused, reason: invalid, verifiedNanos: nil); return }
            do {
                try journal.append(.object([
                    "type": .string("effect_intent"), "request_id": .string(request.requestID),
                    "action_id": .string(request.actionID), "window_id": .string(request.windowID),
                    "effect_kind": .string(request.effectKind.rawValue),
                    "revision": .int(Int64(plannedRevision)),
                    "observer_generation": .int(Int64(request.observerGeneration)),
                    "active_space_key": .string(request.activeSpaceKey), "frame": frame.json,
                    "proposed_state": request.proposedState ?? .null,
                    "state": request.proposedState ?? .null,
                    "requested_frames": .object(JSONObject(unordered: targetFrames(request, primaryFrame: frame).mapValues(\.json))),
                    "window_generations": .object(JSONObject(unordered: request.windowGenerations.mapValues { .int(Int64(clamping: $0)) })),
                    "receipt_nanos": .int(Int64(request.receiptNanos)),
                ]))
            } catch {
                journalFailure(requestID: request.requestID, reason: "journal_append_failed")
                return
            }
            lock.lock()
            guard scheduler.inFlight?.requestID == intent.requestID else { lock.unlock(); return }
            if let invalid = refusal(request, requireRevision: false) {
                let status: WmStatus = committedRevisions[request.requestID] == nil ? .refused : .failed
                lock.unlock()
                complete(requestID: request.requestID, status: status, reason: invalid, verifiedNanos: nil)
                return
            }
            guard context.revision + 1 == plannedRevision else {
                lock.unlock()
                replanJournaled(intent, revision: plannedRevision, reason: "revision_changed_during_journal")
                return
            }
            committingRequests.insert(request.requestID)
            lock.unlock()
            // CoreServer owns the sole revision allocator in production. The injected callback
            // synchronously commits the journaled draft iff this expected revision still holds.
            let commitResult = commitJournaledPlan(request, frame, plannedRevision - 1)
            lock.lock()
            committingRequests.remove(request.requestID)
            if let commitResult {
                committedRevisions[request.requestID] = commitResult
                context.revision = max(context.revision, commitResult)
            }
            let cancelled = deferredCancellations[request.requestID].map {
                cancellationOutcome(request, cancellation: $0)
            }
            if let cancelled { rememberCompletion(cancelled) }
            lock.unlock()
            if let cancelled { onOutcome(cancelled) }
            guard let committedRevision = commitResult else {
                if cancelled != nil { return }
                replanJournaled(intent, revision: plannedRevision, reason: "authoritative_commit_revision_mismatch")
                return
            }
            guard committedRevision == plannedRevision else {
                complete(requestID: request.requestID, status: .failed,
                    reason: "authoritative_commit_revision_mismatch", verifiedNanos: nil)
                return
            }
            do {
                // An intention can outlive a refused compare-and-commit. Recovery promotes only
                // this explicit durable commit marker, never the tail intention on its own.
                try journal.append(.object([
                    "type": .string("effect_commit"), "request_id": .string(request.requestID),
                    "revision": .int(Int64(committedRevision)), "state": request.proposedState ?? .null,
                    "observer_generation": .int(Int64(request.observerGeneration)),
                    "active_space_key": .string(request.activeSpaceKey),
                ]))
            } catch {
                journalFailure(requestID: request.requestID, reason: "journal_commit_failed")
                return
            }
            lock.lock()
            guard scheduler.inFlight?.requestID == intent.requestID else { lock.unlock(); return }
            if let invalid = refusal(request, requireRevision: false) {
                lock.unlock()
                complete(requestID: request.requestID, status: .failed, reason: invalid, verifiedNanos: nil)
                return
            }
            context.revision = max(context.revision, committedRevision)
            issued[request.requestID] = now()
            let issueStamp = issued[request.requestID]!
            let issueGeneration = context.observerGeneration
            scheduler.recordCause(cause: "own-apply", eventID: request.requestID, receiptNanos: request.receiptNanos)
            lock.unlock()
            ResidentPerformanceTrace.shared.record("effect_issued", fields: [
                "request_id": .string(request.requestID), "action_id": .string(request.actionID),
                "boundary": .string("targeted_port_issue"), "revision": .int(Int64(clamping: committedRevision)),
                "observer_generation": .int(Int64(clamping: issueGeneration)),
                "observer_epoch": request.observerEpoch.map(JSONValue.string) ?? .null,
                "window_id": .string(request.windowID), "space_key": .string(request.activeSpaceKey),
                "topology_revision": .int(Int64(clamping: request.topologyRevision)),
                "window_pids": .object(JSONObject(unordered: request.windowPids.mapValues(JSONValue.int))),
                "window_generations": .object(JSONObject(unordered: request.windowGenerations.mapValues { .int(Int64(clamping: $0)) })),
                "target_frames": .object(JSONObject(unordered: targetFrames(request, primaryFrame: frame).mapValues(\.json))),
                "source_input_generation": request.sourceInputGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
                "receipt_uptime_ns": .int(Int64(clamping: request.receiptNanos))], timestamp: issueStamp)
            port.issue(request: request, frame: frame) { [weak self] error in
                guard let self else { return }
                if let error { self.complete(requestID: request.requestID, status: .failed, reason: error, verifiedNanos: nil); return }
                self.lock.lock()
                guard self.scheduler.inFlight?.requestID == request.requestID else { self.lock.unlock(); return }
                let firstAcknowledgment = self.setterAcknowledged.insert(request.requestID).inserted
                let progressStamp = self.now()
                let progressed = firstAcknowledgment && !request.windowGenerations.isEmpty
                    && self.issued[request.requestID].map { progressStamp >= $0 } == true
                let matched = self.goalObserved(request, primaryFrame: intent.desiredFrame)
                    ? self.firstMatched[request.requestID] : nil
                let constrained = self.minimumConstrained(request, primaryFrame: intent.desiredFrame)
                self.lock.unlock()
                if progressed { self.onProgress(request.requestID, progressStamp) }
                if matched != nil { self.complete(requestID: request.requestID, status: .accepted,
                    reason: nil, verifiedNanos: max(self.now(), matched!)) }
                else if constrained { self.complete(requestID: request.requestID, status: .failed,
                    reason: "minimum_constraint", verifiedNanos: nil) }
            }
    }

    private func complete(requestID: String, status: WmStatus, reason: String?, verifiedNanos: UInt64?) {
        lock.lock()
        guard let flight = scheduler.inFlight, flight.requestID == requestID,
              let request = requests[requestID], scheduler.finish(requestID: requestID, generation: flight.generation) else {
            lock.unlock(); return
        }
        let value = outcome(request, status: status, reason: reason, phase: "completed",
                            requestedFrame: flight.desiredFrame,
                            verifiedNanos: verifiedNanos.map { _ in verificationTimestamp(request) })
        let minima: [ResidentMinimumEvidence]
        if status == .accepted && value.verifiedNanos != nil {
            minima = Array((minimumEvidence[requestID] ?? [:]).values)
        } else if status == .failed && reason == "minimum_constraint" {
            minima = (minimumEvidence[requestID] ?? [:]).values.filter { ResidentMinimumLearning.settledClampAxes($0) != nil }
        } else { minima = [] }
        rememberCompletion(value)
        if status == .refused { gateRefusalCount += 1 }
        let next = scheduler.beginNext()
        lock.unlock()
        if !minima.isEmpty { onMinimumEvidence(request, minima) }
        onOutcome(value)
        if let next { start(next) }
    }

    private func abortJournaled(requestID: String, revision: UInt64, reason: String) {
        do {
            try journal.append(.object(["type": .string("effect_abort"), "request_id": .string(requestID),
                "revision": .int(Int64(revision)), "reason": .string(reason)]))
            complete(requestID: requestID, status: .refused, reason: reason, verifiedNanos: nil)
        } catch {
            journalFailure(requestID: requestID, reason: "journal_abort_failed")
        }
    }

    /// Only a distinct authoritative revision in the same valid context may trigger replanning.
    /// It reserves a new journal record, retains exact desired state and caps churn at three;
    /// unchanged refusal is never retried and never converted to successful effect evidence.
    private func replanJournaled(_ intent: CommandScheduling.Intent, revision: UInt64, reason: String) {
        lock.lock()
        let valid = scheduler.inFlight?.requestID == intent.requestID
            && context.revision != revision - 1
            && (["action_result", "effect_completed", "desired_plan_committed", "interaction_committed", "own-apply"].contains(lastContextCause)
                || (["app_activated", "ax_focus_changed"].contains(lastContextCause)
                    && validatedFrameGenerations[intent.requestID] == context.observerGeneration))
            && requests[intent.requestID].map { refusal($0, requireRevision: false) == nil } == true
        let attempts = replanAttempts[intent.requestID] ?? 0
        lock.unlock()
        guard valid && attempts < 3 else {
            abortJournaled(requestID: intent.requestID, revision: revision,
                           reason: valid ? "authoritative_revision_churn" : reason)
            return
        }
        do {
            try journal.append(.object(["type": .string("effect_abort"), "request_id": .string(intent.requestID),
                "revision": .int(Int64(revision)), "reason": .string(reason)]))
        } catch {
            journalFailure(requestID: intent.requestID, reason: "journal_abort_failed")
            return
        }
        lock.lock()
        guard scheduler.inFlight?.requestID == intent.requestID else { lock.unlock(); return }
        replanAttempts[intent.requestID] = attempts + 1; replanCount += 1
        scheduler.recordCause(cause: "replan", eventID: intent.requestID, receiptNanos: intent.receiptNanos)
        lock.unlock()
        start(intent)
    }

    private func outcome(_ request: ResidentEffectRequest, status: WmStatus, reason: String?, phase: String,
                         requestedFrame: Frame? = nil, verifiedNanos: UInt64? = nil) -> ResidentEffectOutcome {
        ResidentEffectOutcome(requestID: request.requestID, status: status, reason: reason,
            revision: context.revision, generation: context.observerGeneration, phase: phase,
            requestedFrame: requestedFrame ?? request.frame, landedFrame: observedFrames[request.requestID],
            receiptNanos: request.receiptNanos, effectIssuedNanos: issued[request.requestID],
            firstMatchingObservationNanos: firstMatched[request.requestID], verifiedNanos: verifiedNanos,
            effectKind: request.effectKind, focusConfirmed: observedFocus.contains(request.requestID),
            requestedFrames: targetFrames(request, primaryFrame: requestedFrame),
            landedFrames: observedTargets[request.requestID] ?? [:],
            requestedGeneration: request.observerGeneration, observedGeneration: observedGenerations[request.requestID],
            desiredStateCommittedRevision: committedRevisions[request.requestID])
    }

    /// Source stamps belong to individual reads; callback arrival order need
    /// not match read completion order. Verification is its own completion
    /// event and cannot precede any admitted match, issue or input receipt.
    private func recordMatchedSourceStamp(requestID: String, windowID: String, timestampNanos: UInt64) {
        matchedSourceStamps[requestID, default: [:]][windowID] = max(
            matchedSourceStamps[requestID]?[windowID] ?? 0, timestampNanos)
    }

    private func verificationTimestamp(_ request: ResidentEffectRequest) -> UInt64 {
        max(now(), max(request.receiptNanos, max(issued[request.requestID] ?? 0,
            matchedSourceStamps[request.requestID]?.values.max() ?? 0)))
    }

    /// Storage faults outlive command cancellation. Publish the current command's precise
    /// terminal result first, then fence persistence through a separate callback outside locks.
    private func journalFailure(requestID: String, reason: String) {
        complete(requestID: requestID, status: .failed, reason: reason, verifiedNanos: nil)
        onPersistenceFault(reason)
    }

    /// Called only under the state lock, before completion removes evidence.
    private func cancellationOutcome(_ request: ResidentEffectRequest,
                                     cancellation: DeferredCancellation) -> ResidentEffectOutcome {
        let status: WmStatus = committedRevisions[request.requestID] != nil || issued[request.requestID] != nil ? .failed : .refused
        if status == .refused { gateRefusalCount += 1 }
        return outcome(request, status: status, reason: cancellation.reason, phase: "completed",
            requestedFrame: cancellation.requestedFrame)
    }

    private func rememberCompletion(_ value: ResidentEffectOutcome) {
        outcomes[value.requestID] = value; requests.removeValue(forKey: value.requestID)
        issued.removeValue(forKey: value.requestID); firstMatched.removeValue(forKey: value.requestID)
        matchedSourceStamps.removeValue(forKey: value.requestID)
        minimumEvidence.removeValue(forKey: value.requestID)
        validatedFrameGenerations.removeValue(forKey: value.requestID)
        validatedFocusGenerations.removeValue(forKey: value.requestID)
        committedRevisions.removeValue(forKey: value.requestID)
        deferredCancellations.removeValue(forKey: value.requestID)
        setterAcknowledged.remove(value.requestID); observedFrames.removeValue(forKey: value.requestID)
        focusIssued.removeValue(forKey: value.requestID)
        observedFocus.remove(value.requestID)
        observedTargets.removeValue(forKey: value.requestID)
        matchingTargets.removeValue(forKey: value.requestID)
        progressTargets.removeValue(forKey: value.requestID)
        observedGenerations.removeValue(forKey: value.requestID)
        replanAttempts.removeValue(forKey: value.requestID)
        completedIDs.append(value.requestID)
        if completedIDs.count > replayCapacity {
            let dropped = completedIDs.removeFirst(); outcomes.removeValue(forKey: dropped); fingerprints.removeValue(forKey: dropped)
        }
    }

    private func targetFrames(_ request: ResidentEffectRequest, primaryFrame: Frame?) -> [String: Frame] {
        if request.effectKind == .focus { return [:] }
        if !request.frameTargets.isEmpty { return request.frameTargets }
        return [request.windowID: primaryFrame ?? request.frame]
    }

    private func allTargetsObserved(_ request: ResidentEffectRequest, primaryFrame: Frame?) -> Bool {
        let targets = targetFrames(request, primaryFrame: primaryFrame)
        let matching = matchingTargets[request.requestID] ?? []
        return !targets.isEmpty && targets.keys.allSatisfy(matching.contains)
    }

    private func goalObserved(_ request: ResidentEffectRequest, primaryFrame: Frame?) -> Bool {
        if request.effectKind == .focus { return observedFocus.contains(request.requestID) }
        return allTargetsObserved(request, primaryFrame: primaryFrame)
            && (!request.requiresFocus || observedFocus.contains(request.requestID))
    }

    /// A clamp is an honest partial landing, never whole-goal verification.
    /// Other windows must independently reach their targets before early exit.
    private func minimumConstrained(_ request: ResidentEffectRequest, primaryFrame: Frame?) -> Bool {
        let proofs = minimumEvidence[request.requestID] ?? [:]
        let clamps = Set(proofs.filter { ResidentMinimumLearning.settledClampAxes($0.value) != nil }.keys)
        guard !clamps.isEmpty else { return false }
        let matching = matchingTargets[request.requestID] ?? []
        return targetFrames(request, primaryFrame: primaryFrame).keys.allSatisfy { matching.contains($0) || clamps.contains($0) }
    }
}
