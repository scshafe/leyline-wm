import Foundation

enum ResidentInputFaultReason: String, Sendable {
    case callbackDeadline = "callback_deadline"
    case tapRunLoopDeadline = "tap_run_loop_deadline"
    case authorityDeadline = "authority_deadline"
    case actionDeadline = "action_deadline"
    case mailboxContention = "mailbox_contention"
    case mailboxOverflow = "mailbox_overflow"
    case pendingActionOverflow = "pending_action_overflow"
    case watchdogDeadline = "watchdog_deadline"

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
