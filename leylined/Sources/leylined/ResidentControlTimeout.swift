import Foundation
import LeylineModel

/// @canonical resident_control_timeout -- one terminal record and scoped stop.
/// Capability release stays off the lifecycle lane; the queued stop can never
/// acquire a fresh epoch, supersede another request or certify readiness.
enum ResidentControlTimeout {
    /// Serializes native input start and claim mutation, never timeline or
    /// request-store callbacks. A new start cannot complete inside an old release.
    final class CapabilityGate: @unchecked Sendable {
        private let lock = NSLock()
        func perform<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }
    }

    static func isCurrent(_ timeout: ResidentControlTimeoutResolution, requests: ResidentControlRequests,
                          lifecycleGeneration: ResidentAtomic<UInt64>) -> Bool {
        guard let generation = timeout.generation else { return false }
        return lifecycleGeneration.load(ordering: .acquiring) == generation && requests.isCurrentTimeout(timeout)
    }

    static func expire(requestID: String, expectedAdmissionSequence: UInt64, revision: UInt64, requests: ResidentControlRequests,
                       lifecycleGeneration: ResidentAtomic<UInt64>,
                       capabilityGate: CapabilityGate,
                       onTerminal: @Sendable () -> Void,
                       releaseClaims: @Sendable () -> Void,
                       cancelMaintenance: @Sendable () -> Void,
                       enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void,
                       continueStopping: @escaping @Sendable (ResidentControlTimeoutResolution) -> Void) {
        guard let timeout = requests.expire(requestID: requestID, expectedAdmissionSequence: expectedAdmissionSequence,
            revision: revision, allocateGeneration: {
            lifecycleGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
        }) else { return }
        onTerminal()
        let released = capabilityGate.perform {
            guard isCurrent(timeout, requests: requests, lifecycleGeneration: lifecycleGeneration) else { return false }
            releaseClaims()
            return true
        }
        guard released else { return }
        guard isCurrent(timeout, requests: requests, lifecycleGeneration: lifecycleGeneration) else { return }
        cancelMaintenance()
        enqueue {
            guard isCurrent(timeout, requests: requests, lifecycleGeneration: lifecycleGeneration) else { return }
            continueStopping(timeout)
        }
    }
}
