import Foundation

enum ResidentInputFaultNoticeConstants {
    static let dismissalMilliseconds = 3_000
}

/// Pure projection of release evidence. It has no mode, claim, lifecycle or
/// actor port. Delayed delivery cannot revive a prior input epoch/generation.
struct ResidentInputFaultNoticeState: Sendable {
    private(set) var visibleEvent: ResidentInputFaultRelease?
    private(set) var dismissalUptimeNs: UInt64 = 0
    private var acceptedEpoch: String?
    private var highestReleasedGeneration: UInt64 = 0

    @discardableResult
    mutating func receive(_ event: ResidentInputFaultRelease, currentInputEpoch: String,
                          currentInputGeneration: UInt64, now: UInt64) -> Bool {
        let duration = UInt64(ResidentInputFaultNoticeConstants.dismissalMilliseconds) * 1_000_000
        guard !event.inputEpoch.isEmpty, event.inputEpoch == currentInputEpoch,
              event.originalGeneration < UInt64.max,
              event.releasedGeneration == event.originalGeneration + 1,
              event.releasedGeneration == currentInputGeneration,
              event.receiptUptimeNs > 0, event.receiptUptimeNs <= now,
              now - event.receiptUptimeNs < duration,
              event.receiptUptimeNs <= UInt64.max - duration else { return false }
        if acceptedEpoch == event.inputEpoch, event.releasedGeneration <= highestReleasedGeneration { return false }
        acceptedEpoch = event.inputEpoch
        highestReleasedGeneration = event.releasedGeneration
        visibleEvent = event
        dismissalUptimeNs = event.receiptUptimeNs + duration
        return true
    }

    @discardableResult
    mutating func dismiss(_ event: ResidentInputFaultRelease, now: UInt64) -> Bool {
        guard visibleEvent == event, now >= dismissalUptimeNs else { return false }
        visibleEvent = nil
        dismissalUptimeNs = 0
        return true
    }

    mutating func clear() { visibleEvent = nil; dismissalUptimeNs = 0 }
}
