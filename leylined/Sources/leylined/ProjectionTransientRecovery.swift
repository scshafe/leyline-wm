import Foundation
import LeylineModel

/// DispatchWorkItem cancellation is thread-safe; the immutable holder lets the
/// cancellation callback cross lanes without relaxing Swift concurrency checks.
private final class ProjectionRecoveryCancellation: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ operation: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: operation) }
    func cancel() { item.cancel() }
}

/// @canonical projection_transient_recovery -- a fixed, finite backoff of fault-triggered baseline
/// attempts per external epoch. An application that has just launched answers AX with -25204 for
/// several hundred milliseconds after NSWorkspace reports the launch, and nothing announces when it
/// starts answering, so one 100ms attempt can land inside that window. Each attempt that still fails
/// transiently schedules the next delay; the schedule never rearms itself and is never an
/// ordinary-state poll. Only real external input (`rearm`) restores the budget.
final class ProjectionTransientRecovery: @unchecked Sendable {
    struct Context: Equatable, Sendable {
        let observerGeneration: UInt64
        let sessionGeneration: UInt64
        let observationEpoch: UInt64
    }
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Schedule = @Sendable (UInt64, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    /// The attempt's own transient failure, and the context it left, when the fresh baseline failed again.
    typealias FollowUp = (context: Context, failure: String)
    typealias Operation = @Sendable (Context, String) -> FollowUp?
    static let delaysMilliseconds: [UInt64] = [100, 500, 2_000]
    static var delayMilliseconds: UInt64 { delaysMilliseconds[0] }
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
    private var scheduledInEpoch = Int.max
    private var consumed: Bool { scheduledInEpoch >= Self.delaysMilliseconds.count }
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
        return components.contains("-25204")
            || components.first == "ax_read_deadline_exceeded"
    }
    /// Real lifecycle/start/recovery input arms a fresh budget. An attempted recovery never calls this.
    func rearm(_ context: Context) {
        lock.lock(); let cancel = pending?.cancel; pending = nil
        armed = context; scheduledInEpoch = 0; firstFailure = nil; lock.unlock(); cancel?()
    }
    func invalidate() {
        lock.lock(); let cancel = pending?.cancel; pending = nil; armed = nil; scheduledInEpoch = Int.max
        lock.unlock(); cancel?()
    }
    var requiredObservationEpoch: UInt64? { lock.lock(); defer { lock.unlock() }; return active?.observationEpoch }
    var snapshot: JSONValue {
        lock.lock(); defer { lock.unlock() }
        let context = active ?? pending?.context ?? armed
        return .object(["phase": .string(active != nil ? "running" : pending != nil ? "pending" : armed == nil ? "inactive" : consumed ? "exhausted" : "armed"),
            "delay_milliseconds": .int(Int64(Self.delayMilliseconds)),
            "delays_milliseconds": .array(Self.delaysMilliseconds.map { .int(Int64($0)) }),
            "scheduled_count": .int(schedules), "attempt_count": .int(attempts),
            "first_failure_code": firstFailure.map(JSONValue.string) ?? .null,
            "source_observer_generation": context.map { .int(Int64(clamping: $0.observerGeneration)) } ?? .null,
            "session_generation": context.map { .int(Int64(clamping: $0.sessionGeneration)) } ?? .null,
            "observation_epoch": context.map { .int(Int64(clamping: $0.observationEpoch)) } ?? .null])
    }
    /// Consumes one slot of the epoch budget before scheduling. Duplicate faults cannot start a
    /// parallel attempt, and a failure an attempt publishes while running cannot rearm the budget;
    /// it only returns as that attempt's follow-up. Stale queued work performs no external observation.
    @discardableResult
    func observeFailure(_ code: String, context: Context,
                        isCurrent: @escaping @Sendable (Context) -> Bool,
                        operation: @escaping Operation) -> Bool {
        guard Self.isTransient(code) else { return false }
        lock.lock()
        guard armed == context, !consumed, pending == nil, active == nil else { lock.unlock(); return false }
        firstFailure = code
        scheduleLocked(context: context, failure: code, isCurrent: isCurrent, operation: operation)
        return true
    }

    /// Caller holds the lock; this releases it before handing work to the scheduler.
    private func scheduleLocked(context: Context, failure: String,
                                isCurrent: @escaping @Sendable (Context) -> Bool, operation: @escaping Operation) {
        let delay = Self.delaysMilliseconds[scheduledInEpoch]
        scheduledInEpoch += 1; serial &+= 1; let ticket = serial
        pending = Pending(serial: ticket, context: context, failure: failure)
        schedules += 1; lock.unlock()
        let cancel = schedule(delay) { [weak self] in
            guard let self else { return }
            self.execute { [self] in
                self.lock.lock()
                guard let work = self.pending, work.serial == ticket, self.armed == work.context else { self.lock.unlock(); return }
                self.pending = nil; self.active = work.context; self.lock.unlock()
                var followUp: FollowUp?
                if isCurrent(work.context) {
                    self.lock.lock(); self.attempts += 1; self.lock.unlock()
                    followUp = operation(work.context, work.failure)
                }
                self.lock.lock(); self.active = nil
                // The attempt replaced the observer generation without rearming. Its own
                // transient failure may claim the next delay only while the epoch it serves
                // is still armed; external input rearmed or invalidated it otherwise.
                if let followUp, Self.isTransient(followUp.failure), self.armed == work.context, !self.consumed {
                    self.armed = followUp.context
                    self.scheduleLocked(context: followUp.context, failure: work.failure, isCurrent: isCurrent, operation: operation)
                } else {
                    self.lock.unlock()
                }
            }
        }
        lock.lock()
        if pending?.serial == ticket { pending?.cancel = cancel; lock.unlock() }
        else { lock.unlock(); cancel() }
    }
}
