// Native in-process mode facts and epoch/sequence admission. No transport owner.
import Foundation
import LeylineModel

enum ModeFrameType: String, Sendable {
    case snapshot = "mode_snapshot"
    case changed = "mode_changed"
}

struct ModeFrame: Equatable, Sendable {
    let type: ModeFrameType
    let epoch: String
    let sequence: Int64
    let mode: String
    let inputGeneration: UInt64?
    let resetsInteraction: Bool

    init(type: ModeFrameType, epoch: String, sequence: Int64, mode: String, resetsInteraction: Bool = false, inputGeneration: UInt64? = nil) {
        self.type = type; self.epoch = epoch; self.sequence = sequence; self.mode = mode
        self.resetsInteraction = resetsInteraction; self.inputGeneration = inputGeneration
    }
}

/// Pure epoch/sequence admission. A new authority epoch is established only
/// by its locked snapshot baseline; once superseded, an epoch can never return.
struct ModeFrameCursor: Sendable {
    private(set) var activeEpoch: String?
    private(set) var activeSequence: Int64?
    private(set) var activeMode: String?
    private var retiredEpochs: Set<String> = []

    mutating func admit(_ frame: ModeFrame) -> ModeFrameAdmission {
        guard let activeEpoch, let activeSequence else {
            guard frame.type == .snapshot else { return .missingEpochBaseline }
            self.activeEpoch = frame.epoch
            self.activeSequence = frame.sequence
            self.activeMode = frame.mode
            return .accepted
        }
        if frame.epoch == activeEpoch {
            if frame.type == .snapshot, frame.sequence == activeSequence {
                return frame.mode == activeMode
                    ? .confirmedCurrentSnapshot
                    : .snapshotConflict
            }
            guard frame.sequence > activeSequence else { return .ignoredStaleOrDuplicate }
            if frame.type == .changed, frame.sequence != activeSequence + 1 {
                return .sequenceGap
            }
            self.activeSequence = frame.sequence
            self.activeMode = frame.mode
            return .accepted
        }
        guard !retiredEpochs.contains(frame.epoch) else { return .ignoredRetiredEpoch }
        guard frame.type == .snapshot else { return .missingEpochBaseline }
        retiredEpochs.insert(activeEpoch)
        self.activeEpoch = frame.epoch
        self.activeSequence = frame.sequence
        self.activeMode = frame.mode
        return .accepted
    }
}

enum ModeFrameAdmission: Equatable, Sendable {
    case accepted
    /// An equal same-epoch snapshot proves a reconnected transport is caught
    /// up, but does not represent a new authoritative mode transition.
    case confirmedCurrentSnapshot
    case ignoredStaleOrDuplicate
    case ignoredRetiredEpoch
    case sequenceGap
    case missingEpochBaseline
    case snapshotConflict
}

struct ModeHealth: Equatable, Sendable {
    let connected: Bool
    let ready: Bool
    let epoch: String?
    let sequence: Int64?
    let degradedReason: String?
}
