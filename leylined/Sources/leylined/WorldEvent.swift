import Foundation

/// One home for the world-event names the resident classifies. Each set is its
/// own predicate: the events overlap by coincidence, not by rule, so only
/// `hardInvalidating` derives from another set. Membership is unchanged from the
/// literal lists these replaced; see the event × list matrix in
/// `.claude/plans/2026-10-12-dry-audit-findings.md`.
enum WorldEvent {
    /// A capture for one of these reasons rebaselines the whole world (Space
    /// identity and inventory). The same observations are the only complete
    /// baselines the startup seed gate accepts.
    static let sweep: Set<String> = [
        "world_seed", "space_changed", "window_space_changed", "topology_changed",
        "wake_recovery", "trust_changed", "explicit_recovery", "application_launch_recovery",
    ]

    /// An explicit fresh baseline lifts the controller's observation-overflow fence.
    static let fullRecovery: Set<String> = ["world_seed", "wake_recovery", "explicit_recovery"]

    /// Observations that schedule a world reconcile by themselves.
    static let reconcileTriggers: Set<String> = [
        "world_seed", "space_changed", "window_space_changed", "space_activation_changed",
        "topology_changed", "wake_recovery", "explicit_recovery", "app_terminated",
    ]

    /// Complete baselines followed by a validation-only cache audit.
    static let cacheAuditTriggers: Set<String> = [
        "world_seed", "global_start", "wake_recovery", "topology_changed",
        "application_launch_recovery", "explicit_recovery",
    ]

    /// Only a fresh targeted focus/app read proves the snapshot's focus.
    static let focusProof: Set<String> = ["world_seed", "app_activated", "ax_focus_changed"]

    /// A changed observer generation on one of these is a foreground rebind,
    /// not a world change; in-flight effects stay continuous.
    static let foregroundRebind: Set<String> = ["app_activated", "ax_focus_changed"]

    /// Space or lifetime changes that end an interaction at the server.
    static let spaceOrLifetimeFence: Set<String> = [
        "app_terminated", "space_changed", "window_space_changed", "topology_changed",
    ]

    /// The controller additionally cancels every in-flight effect on lifecycle
    /// control, trust loss and observer degradation.
    static let hardInvalidating: Set<String> = spaceOrLifetimeFence.union([
        "global_stop", "global_restart", "trust_changed", "ax_observer_degraded", "ax_world_observer_degraded",
    ])

    /// Lifecycle control retires the observation epoch.
    static let epochRetiring: Set<String> = ["global_stop", "global_restart", "global_reset", "maintenance_started"]
}
