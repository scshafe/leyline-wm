import Foundation
import LeylineModel

struct ProjectionCacheAuditProbe: Sendable {
    let failure: ProjectionObservationFailure?
    let enumerations: Int64
    let reads: Int64
    let displayEnumerations: Int64
    init(failure: ProjectionObservationFailure?, enumerations: Int64, reads: Int64, displayEnumerations: Int64 = 0) {
        self.failure = failure; self.enumerations = enumerations; self.reads = reads; self.displayEnumerations = displayEnumerations
    }
}
struct ProjectionCacheAuditSeed: @unchecked Sendable {
    let observerGeneration: UInt64
    let sessionGeneration: UInt64
    let observationEpoch: UInt64
    let activityRevision: UInt64
    let isCurrent: @Sendable () -> Bool
    let collect: @Sendable (@escaping @Sendable () -> ProjectionObservationFailure?, @escaping @Sendable (Int64, Int64, Int64) -> Void) -> ProjectionCacheAuditProbe
    var key: String { "\(observerGeneration):\(sessionGeneration):\(observationEpoch):\(activityRevision)" }
}

/// @canonical projection_cache_integrity_audit -- explicit, nonrecurring validation-only utility work.
/// One worker and one coalesced pending seed. Foreground receipts cancel before the next external
/// call; an already blocked call retains the worker slot, never a second overlapping census.
final class ProjectionCacheIntegrityAudit: @unchecked Sendable {
    static let deadlineMilliseconds: UInt64 = 10_000
    typealias Execute = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Schedule = @Sendable (UInt64, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
    private final class Lease: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var cancellationCode = "cache_audit_superseded"
        var published = false
        var enumerations: Int64 = 0
        var reads: Int64 = 0
        var displays: Int64 = 0
        func cancel(_ code: String = "cache_audit_superseded") { lock.lock(); if !cancelled { cancellationCode = code }; cancelled = true; lock.unlock() }
        var invalid: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var failure: ProjectionObservationFailure? { lock.lock(); defer { lock.unlock() }; return cancelled ? .init(code: cancellationCode) : nil }
        func cost(_ enumerations: Int64, _ reads: Int64, _ displays: Int64) { lock.lock(); self.enumerations = enumerations; self.reads = reads; self.displays = displays; lock.unlock() }
        var counts: (Int64, Int64, Int64) { lock.lock(); defer { lock.unlock() }; return (enumerations, reads, displays) }
        func publishOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if published { return false }; published = true; return true }
    }
    /// One reusable source bounds both scheduled storage and idle work. A queued old source event
    /// cannot run a newer deadline early; an old cancellation cannot disarm its replacement.
    private final class DeadlineTimer: @unchecked Sendable {
        private let lock = NSLock()
        private let timer: DispatchSourceTimer
        private var nextIdentity: UInt64 = 0
        private var identity: UInt64?
        private var deadline: UInt64 = 0
        private var operation: (@Sendable () -> Void)?
        init() {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "leylined.observation.cache_integrity.deadline"))
            timer.schedule(deadline: .distantFuture, repeating: .never)
            timer.setEventHandler { [weak self] in self?.fire() }
            timer.resume()
        }
        func schedule(_ milliseconds: UInt64, operation: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            lock.lock()
            nextIdentity &+= 1; let token = nextIdentity
            identity = token; self.operation = operation
            let due = DispatchTime.now() + .milliseconds(Int(milliseconds))
            deadline = due.uptimeNanoseconds
            timer.schedule(deadline: due, repeating: .never)
            lock.unlock()
            return { [weak self] in self?.cancel(token) }
        }
        private func cancel(_ token: UInt64) {
            lock.lock(); defer { lock.unlock() }
            guard identity == token else { return }
            identity = nil; operation = nil
            timer.schedule(deadline: .distantFuture, repeating: .never)
        }
        private func fire() {
            lock.lock()
            guard identity != nil, DispatchTime.now().uptimeNanoseconds >= deadline else { lock.unlock(); return }
            let callback = operation; identity = nil; operation = nil
            timer.schedule(deadline: .distantFuture, repeating: .never)
            lock.unlock(); callback?()
        }
        deinit { timer.setEventHandler {}; timer.cancel() }
    }
    private struct Job: Sendable { let seed: ProjectionCacheAuditSeed; let reason: String; let lease: Lease }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "leylined.observation.cache_integrity", qos: .utility)
    private let execute: Execute
    private let schedule: Schedule
    private let permitted: @Sendable (ProjectionCacheAuditSeed) -> Bool
    private let now: @Sendable () -> UInt64
    private var active: Job?
    private var pending: Job?
    private var completed = 0
    private var superseded = 0
    private var stopped = false
    var onResult: (@Sendable (ProjectionCacheAuditSeed, ProjectionCacheAuditProbe, String) -> Void)?

    init(executeCompletion: @escaping Execute, permitted: @escaping @Sendable (ProjectionCacheAuditSeed) -> Bool = { _ in true },
         schedule: Schedule? = nil, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        execute = executeCompletion; self.permitted = permitted; self.now = now
        if let schedule { self.schedule = schedule }
        else {
            let deadline = DeadlineTimer()
            self.schedule = { milliseconds, operation in deadline.schedule(milliseconds, operation: operation) }
        }
    }
    func start() { lock.lock(); stopped = false; lock.unlock() }
    func stop() { lock.lock(); stopped = true; active?.lease.cancel(); pending = nil; lock.unlock() }
    func cancelForForeground() { lock.lock(); active?.lease.cancel(); pending = nil; lock.unlock() }
    @discardableResult
    func request(_ seed: ProjectionCacheAuditSeed, reason: String) -> Bool {
        guard seed.isCurrent(), permitted(seed) else { return false }
        let job = Job(seed: seed, reason: reason, lease: Lease())
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        if let active {
            guard active.seed.key != seed.key, pending?.seed.key != seed.key else { lock.unlock(); return false }
            active.lease.cancel(); pending = job; lock.unlock(); return true
        }
        active = job; lock.unlock(); launch(job); return true
    }
    var snapshot: JSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object(["active": .bool(active != nil), "pending_count": .int(pending == nil ? 0 : 1),
            "completed_count": .int(Int64(completed)), "superseded_count": .int(Int64(superseded)),
            "deadline_milliseconds": .int(Int64(Self.deadlineMilliseconds)), "recurring": .bool(false)])
    }
    private func launch(_ job: Job) {
        let started = now()
        let deadline = Self.deadlineMilliseconds * 1_000_000
        let cancelDeadline = schedule(Self.deadlineMilliseconds) { [weak self] in
            guard let self else { return }
            job.lease.cancel("cache_audit_deadline_exceeded")
            let counts = job.lease.counts
            self.publish(job, probe: .init(failure: job.lease.failure, enumerations: counts.0, reads: counts.1, displayEnumerations: counts.2))
        }
        worker.async { [self] in
            let probe = job.seed.collect({ [self] in
                if let failure = job.lease.failure { return failure }
                guard job.seed.isCurrent(), permitted(job.seed) else { return .init(code: "cache_audit_superseded") }
                let stamp = now()
                guard stamp >= started, stamp - started <= deadline - TargetedProjectionSnapshot.axMessageBudgetNs else {
                    return .init(code: "cache_audit_deadline_exceeded")
                }
                return nil
            }, { job.lease.cost($0, $1, $2) })
            cancelDeadline()
            publish(job, probe: probe)
            lock.lock()
            active = nil
            let next = stopped ? nil : pending; pending = nil
            if let next { active = next }
            lock.unlock()
            if let next { launch(next) }
        }
    }
    private func publish(_ job: Job, probe: ProjectionCacheAuditProbe) {
        guard job.lease.publishOnce() else { return }
        execute { [self] in
            let current = job.seed.isCurrent() && permitted(job.seed)
            let failure = current ? job.lease.failure ?? probe.failure : .init(code: "cache_audit_superseded")
            lock.lock(); if failure?.code == "cache_audit_superseded" { superseded += 1 } else { completed += 1 }; lock.unlock()
            let delivered = ProjectionCacheAuditProbe(failure: failure, enumerations: probe.enumerations, reads: probe.reads, displayEnumerations: probe.displayEnumerations)
            onResult?(job.seed, delivered, job.reason)
        }
    }
}
