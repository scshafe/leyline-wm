import Foundation

/// Every reason the safety lane can record for a claim release. Declaration
/// order is the wire code: `health()["last_release_reason"]` stores the index
/// and decodes it, so neither the spellings nor the order may move.
enum ResidentInputReleaseReason: String, CaseIterable, Sendable {
    case none
    case callbackDeadline = "callback_deadline"
    case tapRunLoopDeadline = "tap_run_loop_deadline"
    case authorityDeadline = "authority_deadline"
    case actionDeadline = "action_deadline"
    case mailboxContention = "mailbox_contention"
    case mailboxOverflow = "mailbox_overflow"
    case pendingActionOverflow = "pending_action_overflow"
    case globalStop = "global_stop"
    case externalContextInvalidated = "external_context_invalidated"
    case committedInteractionContextInvalidated = "committed_interaction_context_invalidated"
    case worldOrFocusedSpaceUnavailable = "world_or_focused_space_unavailable"
    case worldUnavailable = "world_unavailable"
    case settingsFailure = "settings-failure"
    case residentControlTimeout = "resident_control_timeout"
    case sessionLocked = "session_locked"
    case watchdogDeadline = "watchdog_deadline"
    /// Unreachable now that reasons are typed; kept so the code table and the
    /// health vocabulary stay exactly what they were.
    case unknownRelease = "unknown_release"

    /// Position in declaration order: the only value the release atomic stores.
    var code: Int { Self.allCases.firstIndex(of: self)! }
}

enum ResidentInputFaultReason: String, Sendable {
    case callbackDeadline = "callback_deadline"
    case tapRunLoopDeadline = "tap_run_loop_deadline"
    case authorityDeadline = "authority_deadline"
    case actionDeadline = "action_deadline"
    case mailboxContention = "mailbox_contention"
    case mailboxOverflow = "mailbox_overflow"
    case pendingActionOverflow = "pending_action_overflow"
    case watchdogDeadline = "watchdog_deadline"

    /// Only deadline and overflow releases are faults the user is told about.
    init?(_ reason: ResidentInputReleaseReason) { self.init(rawValue: reason.rawValue) }

    var humanMessage: String {
        switch self {
        case .mailboxContention, .mailboxOverflow, .pendingActionOverflow:
            return "Leyline released keyboard shortcuts because input was busy."
        case .callbackDeadline, .tapRunLoopDeadline, .authorityDeadline, .actionDeadline, .watchdogDeadline:
            return "Leyline released keyboard shortcuts after a delay."
        }
    }
}

/// Immutable evidence from a successful local safety release. The receipt is
/// the release receipt, not a later health sample or a reconstructed action.
struct ResidentInputFaultRelease: Equatable, Sendable {
    let inputEpoch: String
    let reason: ResidentInputFaultReason
    let originalGeneration: UInt64
    let releasedGeneration: UInt64
    let receiptUptimeNs: UInt64
}
