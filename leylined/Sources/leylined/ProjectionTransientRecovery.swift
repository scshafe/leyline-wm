import Foundation
import LeylineModel

/// DispatchWorkItem cancellation is thread-safe; the immutable holder lets the
/// cancellation callback cross lanes without relaxing Swift concurrency checks.
private final class ProjectionRecoveryCancellation: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ operation: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: operation) }
    func cancel() { item.cancel() }
}

/// @canonical projection_transient_recovery -- one fault-triggered baseline attempt per external epoch.
/// The single 100ms backoff is recovery work, never an ordinary-state poll or a self-rearming retry.
final class ProjectionTransientRecovery: @unchecked Sendable {
    struct Context: Equatable, Sendable {
        let observerGeneration: UInt64
        let sessionGeneration: UInt64
        let observationEpoch: UInt64
    }
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Schedule = @Sendable (UInt64, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    static let delayMilliseconds: UInt64 = 100
    private struct Pending {
        let serial: UInt64
        let context: Context
        let failure: String
        var cancel: (@Sendable () -> Void)?
    }
    private let lock = NSLock()
    private let execute: Execute
    private let schedule: Schedule
    private var armed: Context?
    private var consumed = true
    private var pending: Pending?
    private var active: Context?
    private var serial: UInt64 = 0
    private var schedules: Int64 = 0
    private var attempts: Int64 = 0
    private var firstFailure: String?

    init(execute: @escaping Execute, schedule: Schedule? = nil) {
        self.execute = execute
        let deadlines = DispatchQueue(label: "leylined.projection.transient_recovery.deadline")
        self.schedule = schedule ?? { milliseconds, operation in
            let cancellation = ProjectionRecoveryCancellation(operation)
            deadlines.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: cancellation.item)
            return { cancellation.cancel() }
        }
    }
    static func isTransient(_ code: String) -> Bool {
        // Context such as an owning PID can follow the external AX error.
        let components = code.split(separator: ":")
        return components.contains("-25204") || components.contains("cannotComplete")
            || components.first == "ax_read_deadline_exceeded"
    }
    /// Real lifecycle/start/recovery input arms a fresh budget. An attempted recovery never calls this.
    func rearm(_ context: Context) {
        lock.lock(); let cancel = pending?.cancel; pending = nil
        armed = context; consumed = false; firstFailure = nil; lock.unlock(); cancel?()
    }
    func invalidate() {
        lock.lock(); let cancel = pending?.cancel; pending = nil; armed = nil; consumed = true
        lock.unlock(); cancel?()
    }
    var requiredObservationEpoch: UInt64? { lock.lock(); defer { lock.unlock() }; return active?.observationEpoch }
    var snapshot: JSONValue {
        lock.lock(); defer { lock.unlock() }
        let context = active ?? pending?.context ?? armed
        return .object(["phase": .string(active != nil ? "running" : pending != nil ? "pending" : armed == nil ? "inactive" : consumed ? "exhausted" : "armed"),
            "delay_milliseconds": .int(Int64(Self.delayMilliseconds)), "scheduled_count": .int(schedules), "attempt_count": .int(attempts),
            "first_failure_code": firstFailure.map(JSONValue.string) ?? .null,
            "source_observer_generation": context.map { .int(Int64(clamping: $0.observerGeneration)) } ?? .null,
            "session_generation": context.map { .int(Int64(clamping: $0.sessionGeneration)) } ?? .null,
            "observation_epoch": context.map { .int(Int64(clamping: $0.observationEpoch)) } ?? .null])
    }
    /// Consumes the epoch budget before scheduling. Duplicate faults and a failure returned by
    /// operation cannot start another attempt; stale queued work performs no external observation.
    @discardableResult
    func observeFailure(_ code: String, context: Context,
                        isCurrent: @escaping @Sendable (Context) -> Bool,
                        operation: @escaping @Sendable (Context, String) -> Void) -> Bool {
        guard Self.isTransient(code) else { return false }
        lock.lock()
        guard armed == context, !consumed, pending == nil, active == nil else { lock.unlock(); return false }
        consumed = true; serial &+= 1; let ticket = serial
        pending = Pending(serial: ticket, context: context, failure: code)
        firstFailure = code; schedules += 1; lock.unlock()
        let cancel = schedule(Self.delayMilliseconds) { [weak self] in
            guard let self else { return }
            self.execute { [self] in
                self.lock.lock()
                guard let work = self.pending, work.serial == ticket, self.armed == work.context else { self.lock.unlock(); return }
                self.pending = nil; self.active = work.context; self.lock.unlock()
                if isCurrent(work.context) {
                    self.lock.lock(); self.attempts += 1; self.lock.unlock()
                    operation(work.context, work.failure)
                }
                self.lock.lock(); self.active = nil; self.lock.unlock()
            }
        }
        lock.lock()
        if pending?.serial == ticket { pending?.cancel = cancel; lock.unlock() }
        else { lock.unlock(); cancel() }
        return true
    }
}
