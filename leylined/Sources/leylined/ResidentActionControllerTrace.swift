// Performance-trace records the action controller emits at admission and
// plan commit. Moved verbatim from ResidentActionController.swift.
import Foundation
import LeylineModel

extension ResidentActionController {
    /// Registered requests own one admission fact. Re-execution of deferred
    /// work and sources already registered by handle/startup cannot mint another.
    static func recordAdmission(_ snapshot: CoreCommittedSnapshot, source: CommandSource, requestID: String) {
        ResidentPerformanceTrace.shared.record("admission", fields: traceFields(snapshot, source: source)
            .merging(["request_id": .string(requestID)]), timestamp: source.receipt)
    }

    static func traceFields(_ snapshot: CoreCommittedSnapshot, source: CommandSource) -> JSONObject {
        let focus = snapshot.world.at(path: "focus")
        return source.metadata.merging(["revision": .int(Int64(clamping: snapshot.revision)),
            "observer_generation": snapshot.world.at(path: "observer_generation") ?? .null,
            "observer_epoch": snapshot.world.at(path: "observer_epoch") ?? .null,
            "topology_revision": snapshot.world.at(path: "topology_revision") ?? .null,
            "window_id": focus?.at(path: "window_id") ?? .null, "pid": focus?.at(path: "pid") ?? .null,
            "window_generation": focus?.at(path: "window_generation") ?? .null,
            "space_key": focus?.at(path: "space_key") ?? .null, "display_id": focus?.at(path: "display_id") ?? .null])
    }

    /// Publication-return is an explicit endpoint bound to this accepted result,
    /// never a nearby receipt or a guessed renderer/compositor observation.
    static func recordPlanCommit(_ result: WmResult, state: JSONValue, source: CommandSource,
                                         snapshot: CoreCommittedSnapshot, requestID: String, request: ResidentEffectRequest? = nil) {
        guard result.status == .accepted else { return }
        let candidate = state.at(path: "interaction.candidate") ?? request?.priorInteraction?.at(path: "candidate")
        var fields = traceFields(snapshot, source: source).merging([
            "request_id": .string(requestID),
            "revision": .int(Int64(clamping: result.revision.value)),
            "committed_revision": .int(Int64(clamping: result.revision.value)),
            "base_revision": .int(Int64(clamping: snapshot.revision)),
            "boundary": .string("authoritative_publication_return"),
            "candidate_id": candidate?.at(path: "candidate_id") ?? .null,
            "targets": candidate?.at(path: "targets") ?? .object([:]),
            "candidate_window_identities": candidate?.at(path: "base.window_identities") ?? .null])
        if let request {
            fields["target_frames"] = .object(JSONObject(unordered: request.frameTargets.mapValues(\.json)))
            fields["window_pids"] = .object(JSONObject(unordered: request.windowPids.mapValues(JSONValue.int)))
            fields["window_generations"] = .object(JSONObject(unordered: request.windowGenerations.mapValues { .int(Int64(clamping: $0)) }))
        }
        ResidentPerformanceTrace.shared.record("plan_committed", fields: fields)
    }
}
