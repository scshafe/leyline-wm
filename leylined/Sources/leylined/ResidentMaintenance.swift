import Foundation
import LeylineModel

/// Explicit maintenance failure; a stopped or timed-out resident never becomes ready through fallback.
struct MaintenanceFailure: Error, Sendable {
    let code: String
    let message: String
    let requestID: String
    let epoch: UInt64?
    let context: JSONValue

    init(code: String, message: String, requestID: String, epoch: UInt64? = nil,
         context: JSONValue = .object([:])) {
        self.code = code; self.message = message; self.requestID = requestID
        self.epoch = epoch; self.context = context
    }
    var json: JSONValue {
        .object(["code": .string(code), "message": .string(message), "request_id": .string(requestID),
            "maintenance_epoch": epoch.map { .int(Int64(clamping: $0)) } ?? .null, "context": context])
    }
}

/// @canonical resident_exclusive_maintenance -- acknowledgement barrier, one deadline and one reset worker.
/// Root must close management/admission and cancel interaction/effects before begin. This coordinator
/// never activates modules: only a verified success outcome permits Root to request a fresh baseline.
final class ResidentMaintenance: @unchecked Sendable {
    typealias StopParticipant = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Outcome = @Sendable (Result<JSONValue, MaintenanceFailure>) -> Void
    static let deadlineMilliseconds: UInt64 = 2_000
    private static let participantLimit = 32
    private static let recentRequestLimit = 64
    private static let requestIDByteLimit = 256
    private static let idleWaiterLimit = 8

    fileprivate final class PermitState: @unchecked Sendable {
        let lock = NSLock()
        var valid = true
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    }
    /// A reset must check this permit immediately before its destructive filesystem phase.
    /// Timeout/cancellation invalidates it; the coordinator retains exclusivity until reset returns.
    struct ResetPermit: Sendable {
        let requestID: String
        let epoch: UInt64
        fileprivate let state: PermitState
        var isValid: Bool { state.isValid }
        func check() throws {
            guard isValid else {
                throw MaintenanceFailure(code: "MAINTENANCE.PERMIT_INVALID",
                    message: "Reset authorization expired before the destructive phase", requestID: requestID, epoch: epoch)
            }
        }
    }
    private enum Phase { case waiting, resetting }
    private struct Job {
        let requestID: String
        let epoch: UInt64
        let participantCount: Int
        let expiresAt: UInt64
        let reset: @Sendable (ResetPermit) throws -> JSONValue
        let outcome: Outcome
        let permit: ResetPermit
        let deadline: DispatchWorkItem
        var acknowledged: Set<Int> = []
        var phase = Phase.waiting
        var published = false
    }

    private let lock = NSLock()
    private let stopping = DispatchQueue(label: "leylined.resident.maintenance.stop", attributes: .concurrent)
    private let worker = DispatchQueue(label: "leylined.resident.maintenance.io")
    private let deadlines = DispatchQueue(label: "leylined.resident.maintenance.deadline")
    private let outcomes = DispatchQueue(label: "leylined.resident.maintenance.outcome")
    private let deadlineBudget: UInt64
    private let now: @Sendable () -> UInt64
    private var nextEpoch: UInt64 = 0
    private var active: Job?
    private var recentRequests: [String] = []
    private var idleWaiters: [@Sendable () -> Void] = []

    /// Production uses the fixed two-second deadline; a shorter explicit budget is a hermetic test seam.
    init(deadlineMilliseconds: UInt64 = ResidentMaintenance.deadlineMilliseconds,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        precondition(deadlineMilliseconds > 0 && deadlineMilliseconds <= UInt64(Int.max / 1_000_000))
        deadlineBudget = deadlineMilliseconds * 1_000_000; self.now = now
    }

    /// Admits one exclusive maintenance epoch. Returns false on bounded duplicate/overlap rejection;
    /// every invocation receives exactly one outcome, asynchronously and outside the state lock.
    @discardableResult
    func begin(requestID: String, stopParticipants: [StopParticipant],
               reset: @escaping @Sendable () throws -> JSONValue, onOutcome: @escaping Outcome) -> Bool {
        begin(requestID: requestID, stopParticipants: stopParticipants, reset: { _ in try reset() }, onOutcome: onOutcome)
    }

    /// Permit-aware variant for journal quarantine/rename. All participant ACKs precede reset IO.
    @discardableResult
    func begin(requestID: String, stopParticipants: [StopParticipant],
               reset: @escaping @Sendable (ResetPermit) throws -> JSONValue, onOutcome: @escaping Outcome) -> Bool {
        func reject(_ code: String, _ message: String, epoch: UInt64? = nil) -> Bool {
            let failure = MaintenanceFailure(code: code, message: message, requestID: requestID, epoch: epoch)
            outcomes.async { onOutcome(.failure(failure)) }; return false
        }
        guard !requestID.isEmpty, requestID.utf8.count <= Self.requestIDByteLimit else {
            return reject("MAINTENANCE.REQUEST_INVALID", "Maintenance request identity is missing or too long")
        }
        guard stopParticipants.count <= Self.participantLimit else {
            return reject("MAINTENANCE.PARTICIPANT_LIMIT", "Maintenance participant count exceeds the bounded barrier")
        }
        lock.lock()
        if recentRequests.contains(requestID) {
            let epoch = active?.requestID == requestID ? active?.epoch : nil
            lock.unlock(); return reject("MAINTENANCE.DUPLICATE_REQUEST", "Maintenance request has already been admitted", epoch: epoch)
        }
        if let current = active {
            lock.unlock(); return reject("MAINTENANCE.ALREADY_ACTIVE", "Another maintenance epoch still owns reset authority", epoch: current.epoch)
        }
        guard !stopParticipants.isEmpty else {
            lock.unlock(); return reject("MAINTENANCE.PARTICIPANTS_MISSING", "Maintenance requires a nonempty participant acknowledgement barrier")
        }
        guard nextEpoch < UInt64.max else {
            lock.unlock(); return reject("MAINTENANCE.EPOCH_EXHAUSTED", "Maintenance epoch counter cannot advance safely")
        }
        nextEpoch += 1
        let epoch = nextEpoch, started = now()
        let permit = ResetPermit(requestID: requestID, epoch: epoch, state: PermitState())
        let deadline = DispatchWorkItem { [weak self] in self?.expire(epoch: epoch) }
        active = Job(requestID: requestID, epoch: epoch, participantCount: stopParticipants.count,
            expiresAt: started.addingReportingOverflow(deadlineBudget).partialValue,
            reset: reset, outcome: onOutcome, permit: permit, deadline: deadline)
        recentRequests.append(requestID)
        if recentRequests.count > Self.recentRequestLimit { recentRequests.removeFirst() }
        lock.unlock()
        deadlines.asyncAfter(deadline: .now() + .nanoseconds(Int(deadlineBudget)), execute: deadline)
        for (index, participant) in stopParticipants.enumerated() {
            stopping.async { [weak self] in participant { [weak self] in self?.acknowledge(epoch: epoch, participant: index) } }
        }
        return true
    }

    /// Cancellation reports one stopped failure and fences reset immediately. An already running
    /// reset keeps the exclusive epoch until IO unwinds; cancellation cannot admit overlapping reset.
    @discardableResult
    func cancel(requestID: String) -> Bool {
        lock.lock()
        guard let job = active, job.requestID == requestID, !job.published else { lock.unlock(); return false }
        let failure = MaintenanceFailure(code: "MAINTENANCE.CANCELLED", message: "Maintenance was cancelled while the resident remains stopped",
            requestID: requestID, epoch: job.epoch)
        let callback = failLocked(job: job)
        lock.unlock(); publish(callback, result: .failure(failure)); return true
    }

    var isExclusive: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    /// Root rechecks this epoch before applying an outcome on another queue or requesting activation.
    /// A callback already delivered for a departed epoch cannot authorize a newer reset's baseline.
    func isCurrentEpoch(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return nextEpoch == epoch
    }
    /// Bounded event subscription for IO release after a timed-out reset. Idle is an observation,
    /// not permission to activate: Root still requires a verified reset and a fresh seed.
    @discardableResult
    func whenIdle(_ callback: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard idleWaiters.count < Self.idleWaiterLimit else { lock.unlock(); return false }
        if active == nil { lock.unlock(); outcomes.async(execute: callback) }
        else { idleWaiters.append(callback); lock.unlock() }
        return true
    }
    func snapshot() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let phase = active.map { $0.phase == .waiting ? "waiting_for_participants" : $0.published ? "resetting_after_failure" : "resetting" } ?? "idle"
        return .object(["maintenance_exclusive": .bool(active != nil), "maintenance_phase": .string(phase),
            "request_id": active.map { .string($0.requestID) } ?? .null,
            "maintenance_epoch": .int(Int64(clamping: active?.epoch ?? nextEpoch)),
            "participant_count": .int(Int64(active?.participantCount ?? 0)),
            "acknowledged_count": .int(Int64(active?.acknowledged.count ?? 0)),
            "outcome_published": .bool(active?.published ?? false), "deadline_milliseconds": .int(Int64(deadlineBudget / 1_000_000)),
            "recent_request_count": .int(Int64(recentRequests.count))])
    }

    private func acknowledge(epoch: UInt64, participant: Int?) {
        lock.lock()
        guard var job = active, job.epoch == epoch, job.phase == .waiting, !job.published else { lock.unlock(); return }
        if let participant { job.acknowledged.insert(participant) }
        if now() >= job.expiresAt {
            active = job; lock.unlock(); expire(epoch: epoch); return
        }
        guard job.acknowledged.count == job.participantCount else { active = job; lock.unlock(); return }
        job.phase = .resetting; active = job
        lock.unlock()
        let permit = job.permit, reset = job.reset, requestID = job.requestID, resetEpoch = job.epoch
        worker.async { [self] in
            let result: Result<JSONValue, MaintenanceFailure>
            do { try permit.check(); result = .success(try reset(permit)) }
            catch let failure as MaintenanceFailure { result = .failure(failure) }
            catch {
                result = .failure(MaintenanceFailure(code: "MAINTENANCE.RESET_FAILED",
                    message: "Exclusive reset IO failed: \(error)", requestID: requestID, epoch: resetEpoch,
                    context: .object(["operation": .string("reset"), "cause": .string(String(describing: error))])))
            }
            completeIO(epoch: resetEpoch, result: result)
        }
    }

    private func expire(epoch: UInt64) {
        lock.lock()
        guard let job = active, job.epoch == epoch, !job.published else { lock.unlock(); return }
        let code = job.phase == .waiting ? "MAINTENANCE.PARTICIPANTS_TIMEOUT" : "MAINTENANCE.RESET_TIMEOUT"
        let failure = MaintenanceFailure(code: code, message: "Maintenance deadline expired; resident remains stopped",
            requestID: job.requestID, epoch: epoch,
            context: .object(["participant_count": .int(Int64(job.participantCount)), "acknowledged_count": .int(Int64(job.acknowledged.count))]))
        let callback = failLocked(job: job)
        lock.unlock(); publish(callback, result: .failure(failure))
    }

    /// Called with state lock held; timeout/cancel may release only a barrier that never started IO.
    private func failLocked(job: Job) -> Outcome {
        job.permit.state.invalidate(); job.deadline.cancel()
        if job.phase == .waiting { active = nil }
        else { var failed = job; failed.published = true; active = failed }
        return job.outcome
    }
    private func completeIO(epoch: UInt64, result: Result<JSONValue, MaintenanceFailure>) {
        lock.lock()
        guard let job = active, job.epoch == epoch, job.phase == .resetting else { lock.unlock(); return }
        if job.published { active = nil; lock.unlock(); publishIdle(); return }
        if now() >= job.expiresAt {
            lock.unlock(); expire(epoch: epoch)
            // expire retains a resetting epoch. This IO is already finished, so release it now.
            lock.lock(); if active?.epoch == epoch { active = nil }; lock.unlock(); publishIdle(); return
        }
        job.permit.state.invalidate(); job.deadline.cancel(); active = nil
        lock.unlock()
        let stamped = result.map { value -> JSONValue in
            var object = value.objectValue ?? ["reset_result": value]
            object["maintenance_request_id"] = .string(job.requestID)
            object["maintenance_epoch"] = .int(Int64(clamping: epoch))
            return .object(object)
        }
        publish(job.outcome, result: stamped)
    }
    private func publish(_ callback: @escaping Outcome, result: Result<JSONValue, MaintenanceFailure>) {
        outcomes.async { callback(result) }; publishIdle()
    }
    private func publishIdle() {
        lock.lock()
        guard active == nil else { lock.unlock(); return }
        let callbacks = idleWaiters; idleWaiters.removeAll(); lock.unlock()
        for callback in callbacks { outcomes.async(execute: callback) }
    }
}
