// Canonical transition vocabulary: accepted changes state; noop/refused/failed
// preserve the revision. Degradation is factual and independent of status.
public enum WmStatus: String, Codable, Sendable {
    case accepted
    case noop
    case refused
    case failed

    /// The request succeeded: it changed state or correctly had nothing to change.
    public var isOK: Bool { self == .accepted || self == .noop }
}

public struct WmResult: Codable, Sendable {
    public let status: WmStatus
    /// The revision AFTER this transition: advanced iff `accepted` — noop,
    /// refused, and failed never mint a revision (they change no state).
    public let revision: Revision
    public let degraded: Bool
    public let reason: String?

    public init(status: WmStatus, revision: Revision, degraded: Bool = false, reason: String? = nil) {
        self.status = status
        self.revision = revision
        self.degraded = degraded
        self.reason = reason
    }
}
