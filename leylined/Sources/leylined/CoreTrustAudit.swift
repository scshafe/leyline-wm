import Foundation

/// The explicit one-call-per-second AX grant audit observes only permission
/// transitions. It never discovers windows, reads focus, or drives settling.
final class CoreTrustAudit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "leylined.trust.audit")
    private let read: @Sendable () -> Bool
    private let changed: @Sendable (Bool) -> Void
    private var last: Bool
    private var timer: DispatchSourceTimer?

    init(read: @escaping @Sendable () -> Bool, changed: @escaping @Sendable (Bool) -> Void) {
        self.read = read; self.changed = changed; last = read()
    }
    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let current = read()
            guard current != last else { return }
            last = current
            changed(current)
        }
        timer = source; source.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
}
