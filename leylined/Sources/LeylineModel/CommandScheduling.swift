import Foundation

/// @canonical resident_command_scheduling -- desired states coalesce, semantic commands retain order.
/// Calls are serialized by ResidentEffector; no clocks, observation or actuation run here.
public struct CommandScheduling: Sendable {
    public struct Intent: Sendable, Equatable {
        public let requestID: String
        public let lane: String
        public let generation: UInt64
        public let receiptNanos: UInt64
        public let desiredFrame: Frame?
        public let ordered: Bool
        public init(requestID: String, lane: String, generation: UInt64,
                    receiptNanos: UInt64, desiredFrame: Frame?, ordered: Bool) {
            self.requestID = requestID; self.lane = lane; self.generation = generation
            self.receiptNanos = receiptNanos; self.desiredFrame = desiredFrame; self.ordered = ordered
        }
    }
    public struct Admission: Sendable {
        public let accepted: Bool
        public let reason: String?
        public let supersededRequestID: String?
    }
    public struct GenerationCause: Sendable {
        public let generation: UInt64
        public let cause: String
        public let eventID: String
        public let receiptNanos: UInt64
    }
    public private(set) var generation: UInt64
    public private(set) var inFlight: Intent?
    public private(set) var pending: [Intent] = []
    public private(set) var causes: [GenerationCause] = []
    public private(set) var requestedFrames: [String: Frame] = [:]
    public private(set) var coalescedCount: Int = 0
    public private(set) var refusedCount: Int = 0
    public private(set) var maximumObservedQueueDepth: Int = 0
    public let maximumOrderedPending: Int
    public let maximumCauseCount: Int

    public init(generation: UInt64, maximumOrderedPending: Int = 32, maximumCauseCount: Int = 128) {
        precondition(maximumOrderedPending > 0 && maximumCauseCount > 0)
        self.generation = generation; self.maximumOrderedPending = maximumOrderedPending
        self.maximumCauseCount = maximumCauseCount
    }

    /// Relative repeats accumulate against requested state, including an unlanded pending frame.
    /// The accumulation commits only when admission succeeds, so overflow cannot alter intent.
    public mutating func admitRelativeResize(requestID: String, lane: String, generation: UInt64,
                                             receiptNanos: UInt64, baseline: Frame,
                                             widthDelta: Double, heightDelta: Double) -> Admission {
        let base = requestedFrames[lane] ?? baseline
        let desired = Frame(x: base.x, y: base.y, w: base.w + widthDelta, h: base.h + heightDelta)
        guard desired.w.isFinite, desired.h.isFinite, desired.w > 0, desired.h > 0 else {
            refusedCount += 1
            return Admission(accepted: false, reason: "invalid_resize_frame", supersededRequestID: nil)
        }
        return admit(Intent(requestID: requestID, lane: lane, generation: generation,
                            receiptNanos: receiptNanos, desiredFrame: desired, ordered: false))
    }

    /// A pending desired frame may only replace the tail. Crossing an ordered barrier refuses,
    /// preserving navigation/commit ordering while keeping at most one desired state per lane.
    public mutating func admit(_ intent: Intent) -> Admission {
        guard intent.generation == generation else {
            refusedCount += 1
            return Admission(accepted: false, reason: "observer_generation_mismatch", supersededRequestID: nil)
        }
        var superseded: String?
        if !intent.ordered, let index = pending.firstIndex(where: { !$0.ordered && $0.lane == intent.lane }) {
            guard index == pending.count - 1 else {
                refusedCount += 1
                return Admission(accepted: false, reason: "ordered_command_barrier", supersededRequestID: nil)
            }
            superseded = pending[index].requestID
            pending[index] = intent
            coalescedCount += 1
        } else {
            guard pending.count < maximumOrderedPending else {
                refusedCount += 1
                return Admission(accepted: false, reason: "command_queue_full", supersededRequestID: nil)
            }
            pending.append(intent)
        }
        if let frame = intent.desiredFrame { requestedFrames[intent.lane] = frame }
        maximumObservedQueueDepth = max(maximumObservedQueueDepth, pending.count)
        return Admission(accepted: true, reason: nil, supersededRequestID: superseded)
    }

    public mutating func beginNext() -> Intent? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        inFlight = next
        return next
    }

    /// A key-up is an ordered barrier, not cancellation of the final requested resize state.
    public mutating func keyUp(eventID: String, receiptNanos: UInt64) {
        recordCause(cause: "key-up", eventID: eventID, receiptNanos: receiptNanos)
    }

    public mutating func finish(requestID: String, generation: UInt64) -> Bool {
        guard let flight = inFlight, flight.requestID == requestID,
              flight.generation == generation, self.generation == generation else { return false }
        inFlight = nil
        if !pending.contains(where: { $0.lane == flight.lane }) { requestedFrames.removeValue(forKey: flight.lane) }
        return true
    }

    /// Escape/OFF/trust/topology invalidation precedes further effects and rejects late completion.
    @discardableResult
    public mutating func invalidate(generation: UInt64, cause: String, eventID: String,
                                    receiptNanos: UInt64) -> [String] {
        let cancelled = (inFlight.map { [$0.requestID] } ?? []) + pending.map(\.requestID)
        self.generation = generation; inFlight = nil; pending.removeAll(); requestedFrames.removeAll()
        recordCause(cause: cause, eventID: eventID, receiptNanos: receiptNanos)
        return cancelled
    }

    public mutating func recordCause(cause: String, eventID: String, receiptNanos: UInt64) {
        causes.append(GenerationCause(generation: generation, cause: cause,
                                      eventID: eventID, receiptNanos: receiptNanos))
        if causes.count > maximumCauseCount { causes.removeFirst(causes.count - maximumCauseCount) }
    }
}
