import Foundation
import LeylineModel

/// @canonical resident_startup_seed_gate -- one event-driven native startup.
/// Pending or partial capture is not a failed reconciliation. Claims remain
/// blocked until a real baseline and the owner's reconciliation both complete.
final class ResidentStartupSeedGate: @unchecked Sendable {
    struct Scope: Equatable, Sendable {
        let generation: UInt64
        let observationEpoch: UInt64
    }
    private let lock = NSLock()
    private var awaiting = true
    private var scope: Scope?
    private var reconciling = false

    var blocksClaims: Bool { lock.withLock { awaiting } }

    func arm(generation: UInt64, observationEpoch: UInt64) -> Scope? {
        lock.withLock {
            guard awaiting, scope == nil else { return nil }
            let token = Scope(generation: generation, observationEpoch: observationEpoch)
            scope = token
            return token
        }
    }

    func isCurrent(_ token: Scope, generation: UInt64, observationEpoch: UInt64) -> Bool {
        lock.withLock { awaiting && scope == token && token.generation == generation && token.observationEpoch == observationEpoch }
    }

    func observe(_ snapshot: CoreCommittedSnapshot, generation: UInt64, observationEpoch: UInt64) -> Scope? {
        lock.withLock {
            guard awaiting, !reconciling, let token = scope,
                  token.generation == generation, token.observationEpoch == observationEpoch,
                  snapshot.world.managementEnabled,
                  snapshot.world.worldComplete == true else { return nil }
            let event = snapshot.world.worldEvent
            let baseline = WorldEvent.sweep.contains(event)
                || (event == "app_activated" && snapshot.world.at(path: "observation.world_recovered")?.boolValue == true)
            guard baseline else { return nil }
            reconciling = true
            return token
        }
    }

    /// A real source loss while initial reconciliation runs waits for a distinct
    /// complete recovery event. The failure itself cannot schedule another try.
    func waitForRecovery(_ token: Scope, generation: UInt64, observationEpoch: UInt64) -> Bool {
        lock.withLock {
            guard awaiting, scope == token, token.generation == generation, token.observationEpoch == observationEpoch else { return false }
            reconciling = false
            return true
        }
    }

    @discardableResult
    func finish(_ token: Scope, generation: UInt64, observationEpoch: UInt64) -> Bool {
        lock.withLock {
            guard awaiting, reconciling, scope == token,
                  token.generation == generation, token.observationEpoch == observationEpoch else { return false }
            awaiting = false; scope = nil; reconciling = false
            return true
        }
    }

    func cancel() { lock.withLock { awaiting = false; scope = nil; reconciling = false } }
}
