// Stable, factual health state exposed by the resident core's read-only
// status operation. Health is not a timeline: updates never mint revisions,
// and CoreServer stores this value under the same lock as its world snapshot.
import Foundation
import LeylineModel

struct CoreWorldSeedHealth: Equatable, Sendable {
    let ready: Bool
    let revision: UInt64?

    static let notReady = Self(ready: false, revision: nil)

    var json: JSONValue {
        .object([
            "ready": .bool(ready),
            "revision": revision.map { .int(Int64($0)) } ?? .null,
        ])
    }
}

struct CoreFocusObserverHealth: Equatable, Sendable {
    let ready: Bool
    let windowNotificationsReady: Bool
    let pid: pid_t?
    let generation: UInt64?
    let degradedReason: String?

    static let notStarted = Self(
        ready: false, windowNotificationsReady: false, pid: nil,
        generation: nil, degradedReason: "not_started")

    init(_ health: AccessibilityObserverHealth) {
        ready = health.ready
        windowNotificationsReady = health.windowNotificationsReady
        pid = health.pid
        generation = health.generation
        degradedReason = health.degradedReason
    }

    private init(
        ready: Bool,
        windowNotificationsReady: Bool,
        pid: pid_t?,
        generation: UInt64?,
        degradedReason: String?
    ) {
        self.ready = ready
        self.windowNotificationsReady = windowNotificationsReady
        self.pid = pid
        self.generation = generation
        self.degradedReason = degradedReason
    }

    var json: JSONValue {
        .object([
            "ready": .bool(ready),
            "window_notifications_ready": .bool(windowNotificationsReady),
            "pid": pid.map { .int(Int64($0)) } ?? .null,
            "generation": generation.map { .int(Int64($0)) } ?? .null,
            "degraded_reason": degradedReason.map(JSONValue.string) ?? .null,
        ])
    }
}

struct CoreModeSubscriptionHealth: Equatable, Sendable {
    let connected: Bool
    let ready: Bool
    let epoch: String?
    let sequence: Int64?
    let degradedReason: String?

    static let notStarted = Self(
        connected: false, ready: false, epoch: nil, sequence: nil,
        degradedReason: "not_started")

    init(_ health: ModeHealth) {
        connected = health.connected
        ready = health.ready
        epoch = health.epoch
        sequence = health.sequence
        degradedReason = health.degradedReason
    }

    private init(
        connected: Bool,
        ready: Bool,
        epoch: String?,
        sequence: Int64?,
        degradedReason: String?
    ) {
        self.connected = connected
        self.ready = ready
        self.epoch = epoch
        self.sequence = sequence
        self.degradedReason = degradedReason
    }

    var json: JSONValue {
        .object([
            "connected": .bool(connected),
            "ready": .bool(ready),
            "epoch": epoch.map(JSONValue.string) ?? .null,
            "sequence": sequence.map(JSONValue.int) ?? .null,
            "degraded_reason": degradedReason.map(JSONValue.string) ?? .null,
        ])
    }
}

/// Factual projection state. Unknown readiness is explicit until configuration.
struct CoreProjectionHealth: Equatable, Sendable {
    let required: Bool?
    let mounted: Bool
    let degraded: Bool
    let degradedReason: String?
    let lastRenderedRevision: UInt64?

    static let notConfigured = Self(
        required: nil, mounted: false, degraded: true,
        degradedReason: "projection_not_configured",
        lastRenderedRevision: nil)

    var json: JSONValue {
        .object([
            "required": required.map(JSONValue.bool) ?? .null,
            "mounted": .bool(mounted),
            "degraded": .bool(degraded),
            "degraded_reason": degradedReason.map(JSONValue.string) ?? .null,
            "last_rendered_revision": lastRenderedRevision.map {
                .int(Int64($0))
            } ?? .null,
        ])
    }
}

/// @canonical core_health_snapshot -- the only status health schema.
struct CoreHealthSnapshot: Equatable, Sendable {
    static let schema = 2

    var worldSeed: CoreWorldSeedHealth
    var focusObserver: CoreFocusObserverHealth
    var modeSubscription: CoreModeSubscriptionHealth
    var projection: CoreProjectionHealth

    static let initial = Self(
        worldSeed: .notReady,
        focusObserver: .notStarted,
        modeSubscription: .notStarted,
        projection: .notConfigured)

    var json: JSONValue {
        .object([
            "schema": .int(Int64(Self.schema)),
            "owner": .string("resident"),
            "world_seed": worldSeed.json,
            "focus_observer": focusObserver.json,
            "mode_subscription": modeSubscription.json,
            "projection": projection.json,
        ])
    }
}
