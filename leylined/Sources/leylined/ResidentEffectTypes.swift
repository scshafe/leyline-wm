// The effector's wire types: context, request, outcome and the port/journal protocols it is given.
import Foundation
import LeylineModel

extension Dictionary where Key == String {
    /// A per-window map as a JSON object with sorted keys.
    func json(_ transform: (Value) -> JSONValue) -> JSONValue {
        .object(JSONObject(unordered: mapValues(transform)))
    }
}

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
    var sourceInputGeneration: UInt64? = nil

    var fingerprint: String {
        JSONValue.object([
            "action_id": .string(actionID), "window_id": .string(windowID),
            "expected_revision": .int(Int64(expectedRevision)),
            "observer_generation": .int(Int64(observerGeneration)),
            "active_space_key": .string(activeSpaceKey),
            "topology_revision": .int(Int64(topologyRevision)), "frame": frame.json,
            "ordered": .bool(ordered),
            "effect_kind": .string(effectKind.rawValue),
            "requires_focus": .bool(requiresFocus), "prior_interaction": priorInteraction ?? .null,
            "stack_top_window_ids": .array(stackTopWindowIDs.map(JSONValue.string)),
            "prior_model_state": priorModelState ?? .null,
            "proposed_state": proposedState ?? .null,
            "frame_targets": frameTargets.json(\.json),
            "scheduling_lane": schedulingLane.map(JSONValue.string) ?? .null,
            "source_input_generation": sourceInputGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
            "window_space_keys": windowSpaceKeys.json(JSONValue.string),
            "window_pids": windowPidsJSON,
            "window_display_ids": windowDisplayIDs.json(JSONValue.string),
            "window_application_keys": windowApplicationKeys.json(JSONValue.string),
            "observer_epoch": observerEpoch.map(JSONValue.string) ?? .null,
            "window_generations": windowGenerationsJSON,
        ]).canonical()
    }

    /// The per-window maps as the journal, traces and fingerprint record them.
    var windowPidsJSON: JSONValue { windowPids.json(JSONValue.int) }
    var windowGenerationsJSON: JSONValue { windowGenerations.json { .int(Int64(clamping: $0)) } }
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
