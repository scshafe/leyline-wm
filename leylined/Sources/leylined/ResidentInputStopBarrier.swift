import Foundation

/// One teardown request and one latest resume intent. All state is confined to
/// the lifecycle queue; late acknowledgments cannot resurrect an older intent.
final class ResidentInputStopBarrier: @unchecked Sendable {
    private let queue: DispatchQueue
    private let stopPort: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let didStop: @Sendable () -> Void
    private let overflow: @Sendable () -> Void
    private var pending = false
    private var stopGeneration: UInt64 = 0
    private var resume: (@Sendable () -> Void)?
    private var waiters: [@Sendable () -> Void] = []

    init(queue: DispatchQueue,
         stopPort: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         didStop: @escaping @Sendable () -> Void = {},
         overflow: @escaping @Sendable () -> Void = {}) {
        self.queue = queue; self.stopPort = stopPort; self.didStop = didStop; self.overflow = overflow
    }

    func stop(resume: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            self.resume = resume
            beginStop()
        }
    }

    /// Maintenance waits for actual teardown. Overflow leaves the participant
    /// unacknowledged, so the exclusive reset deadline refuses destructive I/O.
    func whenStopped(_ acknowledge: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard waiters.count < 8 else { overflow(); return }
            waiters.append(acknowledge)
            beginStop()
        }
    }

    private func beginStop() {
        guard !pending else { return }
        pending = true
        stopGeneration += 1
        let generation = stopGeneration
        stopPort { [weak self] in
            guard let self else { return }
            self.queue.async { [self] in
                guard pending, stopGeneration == generation else { return }
                pending = false
                let next = resume; resume = nil
                let acknowledged = waiters; waiters.removeAll()
                didStop()
                acknowledged.forEach { $0() }
                next?()
            }
        }
    }
}
