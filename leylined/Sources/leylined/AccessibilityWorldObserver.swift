// @canonical accessibility_world_observation -- all background app/window
// lifecycle registrations reuse AccessibilityFocusObserver on dedicated loops.
// Related: TargetedProjectionSnapshot. No second notification implementation.
import ApplicationServices
import Foundation

protocol ProjectionWorldObserving: AnyObject, Sendable {
    var onEvent: (@Sendable (AccessibilityFocusEvent) -> Void)? { get set }
    func begin(ownerPids: Set<pid_t>, generation: UInt64) -> Result<Void, ProjectionObservationFailure>
    func replace(inventory: ProjectionWindowInventory, generation: UInt64) -> Result<Void, ProjectionObservationFailure>
    func stop(generation: UInt64)
}

final class AccessibilityWorldObserver: ProjectionWorldObserving, @unchecked Sendable {
    private let trustedProvider: @Sendable () -> Bool
    private var observers: [pid_t: AccessibilityFocusObserver] = [:]
    private var generation: UInt64 = 0
    var onEvent: (@Sendable (AccessibilityFocusEvent) -> Void)?

    init(trustedProvider: @escaping @Sendable () -> Bool) { self.trustedProvider = trustedProvider }

    /// A complete inventory is observed before it becomes authoritative. Any
    /// unsupported required registration explicitly refuses completeness.
    func begin(ownerPids: Set<pid_t>, generation: UInt64)
        -> Result<Void, ProjectionObservationFailure> {
        stop(generation: generation)
        self.generation = generation
        for pid in ownerPids.sorted() {
            let observer = AccessibilityFocusObserver(trustedProvider: trustedProvider)
            observer.onEvent = { [weak self] in self?.onEvent?($0) }
            observer.onHealthChanged = { [weak self] health in
                guard !health.ready else { return }
                self?.onEvent?(AccessibilityFocusEvent(
                    kind: .worldObserverDegraded, pid: pid, generation: generation,
                    isWorldObservation: true, degradedReason: health.degradedReason))
            }
            let health = observer.attachWorld(to: pid, generation: generation, windows: [])
            observers[pid] = observer
            guard health.ready else {
                stop(generation: generation)
                return .failure(.init(code: health.degradedReason ?? "ax_world_observer_registration_failed"))
            }
        }
        return .success(())
    }

    func replace(inventory: ProjectionWindowInventory, generation: UInt64)
        -> Result<Void, ProjectionObservationFailure> {
        if self.generation != generation || Set(observers.keys) != inventory.ownerPids {
            if case .failure(let failure) = begin(ownerPids: inventory.ownerPids, generation: generation) {
                return .failure(failure)
            }
        }
        let grouped = Dictionary(grouping: inventory.handles, by: \.pid)
        for pid in inventory.ownerPids.sorted() {
            guard let observer = observers[pid] else {
                return .failure(.init(code: "ax_world_owner_observer_missing"))
            }
            let health = observer.registerWorldWindows(grouped[pid] ?? [], generation: generation)
            guard health.ready else {
                stop(generation: generation)
                return .failure(.init(code: health.degradedReason ?? "ax_world_registration_failed"))
            }
        }
        return .success(())
    }

    func stop(generation: UInt64) {
        for observer in observers.values { observer.detach(generation: generation) }
        observers.removeAll()
    }
}
