import Foundation
import LeylineModel

enum ResidentMinimumAxis: String, Hashable, Sendable { case width = "w", height = "h" }

protocol ResidentMinimumEvidencePort: ResidentEffectorPort {
    var onMinimumEvidence: (@Sendable (ResidentMinimumEvidence) -> Void)? { get set }
}

/// Constructed only after the canonical port's actual CGSize setter succeeds.
/// A batch acknowledgment, planned target or unchanged preflight is no receipt.
struct ResidentSizeWriteReceipt: Sendable {
    let requestID: String
    let windowID: String
    let ownerPID: Int64
    let windowGeneration: UInt64
    let observerEpoch: String
    let observerGeneration: UInt64
    let spaceKey: String
    let displayID: String
    let topologyRevision: UInt64
    let before: Frame
    let requested: Frame
    let axes: Set<ResidentMinimumAxis>
    let completedNanos: UInt64
}

struct ResidentMinimumEvidence: Sendable {
    let write: ResidentSizeWriteReceipt
    let observed: Frame
    let observedGeneration: UInt64
    let readCompletedNanos: UInt64
    let confirmationFrame: Frame?
    let confirmationGeneration: UInt64?
    let confirmationCompletedNanos: UInt64?

    init(write: ResidentSizeWriteReceipt, observed: Frame, observedGeneration: UInt64,
         readCompletedNanos: UInt64, confirmationFrame: Frame? = nil,
         confirmationGeneration: UInt64? = nil, confirmationCompletedNanos: UInt64? = nil) {
        self.write = write; self.observed = observed; self.observedGeneration = observedGeneration
        self.readCompletedNanos = readCompletedNanos; self.confirmationFrame = confirmationFrame
        self.confirmationGeneration = confirmationGeneration; self.confirmationCompletedNanos = confirmationCompletedNanos
    }
}

/// @canonical resident_minimum_learning -- exact issued-write/read provenance
/// gates the existing pure minimum fold. A new floor additionally requires
/// actual shrink progress and a separate unchanged post-write confirmation.
/// An ignored unchanged setter, batch ACK or repair candidate cannot learn.
enum ResidentMinimumLearning {
    /// Axes that shrank toward the issued target and stopped above it. Every
    /// other component must match the target, so external geometry drift refuses.
    static func settledClampAxes(_ evidence: ResidentMinimumEvidence) -> Set<ResidentMinimumAxis>? {
        guard let confirmation = evidence.confirmationFrame,
              let stamp = evidence.confirmationCompletedNanos, stamp > evidence.readCompletedNanos,
              Geometry.frameEq(evidence.observed, confirmation, tol: 0.5),
              abs(confirmation.x - evidence.write.requested.x) <= 0.5,
              abs(confirmation.y - evidence.write.requested.y) <= 0.5 else { return nil }
        var clamps: Set<ResidentMinimumAxis> = []
        for axis in [ResidentMinimumAxis.width, .height] {
            let before = axis == .width ? evidence.write.before.w : evidence.write.before.h
            let target = axis == .width ? evidence.write.requested.w : evidence.write.requested.h
            let actual = axis == .width ? confirmation.w : confirmation.h
            guard before.isFinite, target.isFinite, actual.isFinite, actual > 0 else { return nil }
            if abs(actual - target) <= 0.5 { continue }
            guard evidence.write.axes.contains(axis), before > target + 4,
                  actual > target + 4, actual < before - 4 else { return nil }
            clamps.insert(axis)
        }
        return clamps.isEmpty ? nil : clamps
    }
    static func refusal(_ evidence: ResidentMinimumEvidence, request: ResidentEffectRequest,
                        currentGeneration: UInt64, issuedNanos: UInt64, now: UInt64) -> String? {
        let write = evidence.write, id = write.windowID
        guard let numericID = Int64(id), numericID > 0,
              request.effectKind == .frame, write.requestID == request.requestID,
              let target = request.frameTargets[id] ?? (id == request.windowID ? request.frame : nil),
              Geometry.frameEq(target, write.requested, tol: 0.5),
              write.ownerPID > 0, request.windowPids[id] == write.ownerPID,
              write.windowGeneration > 0, request.windowGenerations[id] == write.windowGeneration,
              !write.observerEpoch.isEmpty, request.observerEpoch == write.observerEpoch,
              request.windowSpaceKeys[id] == write.spaceKey, request.windowDisplayIDs[id] == write.displayID,
              request.topologyRevision == write.topologyRevision,
              write.observerGeneration >= request.observerGeneration,
              evidence.observedGeneration >= write.observerGeneration,
              evidence.observedGeneration == currentGeneration else { return "minimum_write_identity_or_scope_changed" }
        guard !write.axes.isEmpty,
              write.axes.allSatisfy({ axis in
                  abs((axis == .width ? write.before.w : write.before.h)
                      - (axis == .width ? write.requested.w : write.requested.h)) > 0.5
              }), write.completedNanos >= issuedNanos,
              evidence.readCompletedNanos >= write.completedNanos,
              evidence.readCompletedNanos <= now else { return "minimum_write_or_read_provenance_invalid" }
        if !Geometry.frameEq(evidence.observed, write.requested, tol: 0.5) {
            guard let stamp = evidence.confirmationCompletedNanos, stamp <= now,
                  evidence.confirmationGeneration == currentGeneration,
                  settledClampAxes(evidence) != nil else { return "minimum_clamp_unproven" }
        }
        return nil
    }

    static func learnedStore(evidence: [ResidentMinimumEvidence], request: ResidentEffectRequest,
                             store: JSONValue, topology: JSONValue) -> JSONValue {
        var result = store
        for proof in evidence {
            let id = proof.write.windowID
            guard let numericID = Int64(id), numericID > 0,
                  let app = request.windowApplicationKeys[id], !app.isEmpty else { continue }
            let prior = result.objectValue?[app]?.objectValue ?? [:]
            let clampAxes = settledClampAxes(proof) ?? []
            var target = proof.observed
            // Only the axes actually written may self-heal an existing floor.
            if proof.write.axes.contains(.width), prior["w"]?.numberValue != nil || clampAxes.contains(.width) { target.w = proof.write.requested.w }
            if proof.write.axes.contains(.height), prior["h"]?.numberValue != nil || clampAxes.contains(.height) { target.h = proof.write.requested.h }
            let folded = Minsize.learnMinSizes(targets: .object([id: .object([
                "presented": .bool(true), "frame": target.json])]), observed: [.object([
                    "window_id": .int(numericID), "bundle_id": .string(app), "frame": proof.observed.json])],
                store: result, topo: topology)
            var allowed = prior
            for axis in proof.write.axes {
                guard let learnedAxis = folded.objectValue?[app]?.at(path: axis.rawValue),
                      let value = learnedAxis.numberValue,
                      value.isFinite, value > 0 else { continue }
                let old = prior[axis.rawValue]?.numberValue
                guard clampAxes.contains(axis) || old.map({ value < $0 }) == true else { continue }
                allowed[axis.rawValue] = learnedAxis
            }
            if !allowed.isEmpty {
                var table = result.objectValue ?? [:]; table[app] = .object(allowed); result = .object(table)
            }
        }
        return result
    }
}
