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
    /// The repair pass reissued the identical size write and it was refused again.
    let rewriteRefused: Bool

    init(write: ResidentSizeWriteReceipt, observed: Frame, observedGeneration: UInt64,
         readCompletedNanos: UInt64, confirmationFrame: Frame? = nil,
         confirmationGeneration: UInt64? = nil, confirmationCompletedNanos: UInt64? = nil,
         rewriteRefused: Bool = false) {
        self.write = write; self.observed = observed; self.observedGeneration = observedGeneration
        self.readCompletedNanos = readCompletedNanos; self.confirmationFrame = confirmationFrame
        self.confirmationGeneration = confirmationGeneration; self.confirmationCompletedNanos = confirmationCompletedNanos
        self.rewriteRefused = rewriteRefused
    }
}

/// @canonical resident_minimum_learning -- exact issued-write/read provenance
/// gates the existing pure minimum fold. A new floor additionally requires
/// a separate unchanged post-write confirmation and either actual shrink
/// progress or, for a window already at its floor, a refused identical rewrite.
/// A single ignored unchanged setter, batch ACK or repair candidate cannot learn.
enum ResidentMinimumLearning {
    /// The effector's frame-landing tolerance: a component this close to its target has landed.
    static let landedTolerance = ResidentEffector.landedTolerance
    /// A shrink smaller than this is app rounding, not progress toward a floor.
    static let shrinkProgressMinimum = 4.0

    /// Axes that shrank toward the issued target and stopped above it. Every
    /// other component must land on the target, so external geometry drift refuses.
    static func settledClampAxes(_ evidence: ResidentMinimumEvidence) -> Set<ResidentMinimumAxis>? {
        guard let confirmation = evidence.confirmationFrame,
              let stamp = evidence.confirmationCompletedNanos, stamp > evidence.readCompletedNanos,
              Geometry.frameEq(evidence.observed, confirmation, tol: ResidentEffector.unchangedTolerance),
              abs(confirmation.x - evidence.write.requested.x) <= landedTolerance,
              abs(confirmation.y - evidence.write.requested.y) <= landedTolerance else { return nil }
        var clamps: Set<ResidentMinimumAxis> = []
        for axis in [ResidentMinimumAxis.width, .height] {
            let before = axis == .width ? evidence.write.before.w : evidence.write.before.h
            let target = axis == .width ? evidence.write.requested.w : evidence.write.requested.h
            let actual = axis == .width ? confirmation.w : confirmation.h
            guard before.isFinite, target.isFinite, actual.isFinite, actual > 0 else { return nil }
            if abs(actual - target) <= landedTolerance { continue }
            let progressed = actual < before - shrinkProgressMinimum
            let refusedAtFloor = evidence.rewriteRefused && abs(actual - before) <= ResidentEffector.unchangedTolerance
            guard evidence.write.axes.contains(axis), before > target + shrinkProgressMinimum,
                  actual > target + shrinkProgressMinimum, progressed || refusedAtFloor else { return nil }
            clamps.insert(axis)
        }
        return clamps.isEmpty ? nil : clamps
    }
    /// A window that holds its own shape: after a refused identical rewrite it
    /// stays above the target on one written axis and below it on the other
    /// (the iOS Simulator's fixed-aspect device window). No floor explains a
    /// short axis, and terminal cell rounding only ever falls short, so both
    /// directions are required. The app's windows then stay untiled.
    static func settledShapeRefusal(_ evidence: ResidentMinimumEvidence) -> Bool {
        guard evidence.rewriteRefused, let confirmation = evidence.confirmationFrame,
              let stamp = evidence.confirmationCompletedNanos, stamp > evidence.readCompletedNanos,
              Geometry.frameEq(evidence.observed, confirmation, tol: ResidentEffector.unchangedTolerance),
              abs(confirmation.x - evidence.write.requested.x) <= landedTolerance,
              abs(confirmation.y - evidence.write.requested.y) <= landedTolerance,
              evidence.write.axes == [.width, .height] else { return false }
        let misses = [confirmation.w - evidence.write.requested.w, confirmation.h - evidence.write.requested.h]
        guard misses.allSatisfy(\.isFinite), confirmation.w > 0, confirmation.h > 0 else { return false }
        return misses.contains { $0 > shrinkProgressMinimum } && misses.contains { $0 < -shrinkProgressMinimum }
    }

    /// Settled evidence the effector may complete on: a learned floor or a refused shape.
    static func settledConstraint(_ evidence: ResidentMinimumEvidence) -> Bool {
        settledClampAxes(evidence) != nil || settledShapeRefusal(evidence)
    }

    /// A window already at its floor does not shrink at all. When the repair pass's identical
    /// rewrite leaves it unchanged at the requested position too, the rewrite's readback
    /// confirms the first write's evidence.
    static func repeatedRefusal(_ first: ResidentMinimumEvidence, rewriteRead: Frame,
                                generation: UInt64, completedNanos: UInt64) -> ResidentMinimumEvidence? {
        guard Geometry.frameEq(first.observed, rewriteRead, tol: ResidentEffector.unchangedTolerance), completedNanos > first.readCompletedNanos else { return nil }
        let confirmed = ResidentMinimumEvidence(write: first.write, observed: first.observed,
            observedGeneration: first.observedGeneration, readCompletedNanos: first.readCompletedNanos,
            confirmationFrame: rewriteRead, confirmationGeneration: generation,
            confirmationCompletedNanos: completedNanos, rewriteRefused: true)
        return settledConstraint(confirmed) ? confirmed : nil
    }

    /// Applications whose shape refusal is proven, added to the durable set.
    static func learnedFixedAspect(evidence: [ResidentMinimumEvidence], request: ResidentEffectRequest,
                                   store: JSONValue) -> JSONValue {
        var apps = Set((store.arrayValue ?? []).compactMap(\.stringValue))
        for proof in evidence where settledShapeRefusal(proof) {
            if let app = request.windowApplicationKeys[proof.write.windowID], !app.isEmpty { apps.insert(app) }
        }
        return .array(apps.sorted().map(JSONValue.string))
    }

    static func refusal(_ evidence: ResidentMinimumEvidence, request: ResidentEffectRequest,
                        currentGeneration: UInt64, issuedNanos: UInt64, now: UInt64) -> String? {
        let write = evidence.write, id = write.windowID
        guard let numericID = Int64(id), numericID > 0,
              request.effectKind == .frame, write.requestID == request.requestID,
              let target = request.frameTargets[id] ?? (id == request.windowID ? request.frame : nil),
              Geometry.frameEq(target, write.requested, tol: ResidentEffector.unchangedTolerance),
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
                      - (axis == .width ? write.requested.w : write.requested.h)) > ResidentEffector.unchangedTolerance
              }), write.completedNanos >= issuedNanos,
              evidence.readCompletedNanos >= write.completedNanos,
              evidence.readCompletedNanos <= now else { return "minimum_write_or_read_provenance_invalid" }
        if !Geometry.frameEq(evidence.observed, write.requested, tol: ResidentEffector.unchangedTolerance) {
            guard let stamp = evidence.confirmationCompletedNanos, stamp <= now,
                  evidence.confirmationGeneration == currentGeneration,
                  settledConstraint(evidence) else { return "minimum_clamp_unproven" }
        }
        return nil
    }

    static func learnedStore(evidence: [ResidentMinimumEvidence], request: ResidentEffectRequest,
                             store: JSONValue, topology: JSONValue) -> JSONValue {
        var result = store
        for proof in evidence where !settledShapeRefusal(proof) {
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
