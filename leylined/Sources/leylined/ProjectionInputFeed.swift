// The pure projection-input coordinator. Workspace and AX adapters report
// lifecycle events here; the coordinator owns observer generations, captures
// a targeted snapshot for every accepted event, and funnels one typed world
// delta to the core. The executor is the observation lane; its legacy
// executeOnMain label remains source compatible. No timer or polling API.
import Foundation
import LeylineModel

struct ProjectionApplication: Equatable, Sendable {
    let pid: pid_t
    let name: String
}

struct ProjectionWorldSnapshot: Equatable, Sendable {
    let windowsOnscreen: Int64
    let focus: JSONValue
    let observation: JSONObject
    let windows: [JSONValue]
    let topology: [JSONValue]
    let activeContext: JSONValue
    let spaceContexts: [JSONValue]

    init(windowsOnscreen: Int64, focus: JSONValue, observation: JSONObject = [:],
         windows: [JSONValue] = [], topology: [JSONValue] = [],
         activeContext: JSONValue = .null, spaceContexts: [JSONValue] = []) {
        self.windowsOnscreen = windowsOnscreen
        self.focus = focus
        self.observation = observation
        self.windows = windows
        self.topology = topology
        self.activeContext = activeContext
        self.spaceContexts = spaceContexts
    }
}

/// The observation cause is explicit: only bootstrap/recovery/topology may
/// enumerate the window world; AX notification reads address their own element.
struct ProjectionSnapshotRequest: Sendable {
    let reason: String
    let application: ProjectionApplication?
    let observerGeneration: UInt64
    let accessibilityEvent: AccessibilityFocusEvent?
    var lifecyclePid: pid_t? = nil
}

typealias ProjectionSnapshotCapture = @Sendable (ProjectionApplication?) -> ProjectionWorldSnapshot
typealias TargetedProjectionSnapshotCapture = @Sendable (ProjectionSnapshotRequest) -> ProjectionWorldSnapshot
typealias ProjectionWorldDelivery = @Sendable (JSONObject) -> Void
typealias ProjectionMainExecutor = @Sendable (@escaping @Sendable () -> Void) -> Void
typealias ProjectionFeedHealthDelivery = @Sendable (AccessibilityObserverHealth) -> Void

/// @canonical projection_input_feed -- all event-driven focus projection
/// inputs cross this generation gate before they reach CoreServer/rendering.
final class ProjectionInputFeed: @unchecked Sendable {
    static let maximumPendingInputs = 64
    private enum PendingInput: Sendable {
        case accessibility(AccessibilityFocusEvent)
        case health(AccessibilityObserverHealth)
        var generation: UInt64 {
            switch self {
            case .accessibility(let value): return value.generation
            case .health(let value): return value.generation
            }
        }
    }
    private let observer: AccessibilityFocusObserving
    private let capture: TargetedProjectionSnapshotCapture
    private let deliver: ProjectionWorldDelivery
    private let executeOnMain: ProjectionMainExecutor
    private let onHealthChanged: ProjectionFeedHealthDelivery
    private let transientRecovery: ProjectionTransientRecovery?
    private let recoverySessionGeneration: @Sendable () -> UInt64
    private let recoveryObservationEpoch: @Sendable () -> UInt64
    private let recoveryPermitted: @Sendable () -> Bool
    private var cacheAudit: ProjectionCacheIntegrityAudit?
    private var makeAuditSeed: (@Sendable (UInt64) -> Result<ProjectionCacheAuditSeed, ProjectionObservationFailure>)?
    private var finishAudit: (@Sendable (ProjectionCacheAuditSeed, ProjectionCacheAuditProbe) -> JSONObject)?

    private var application: ProjectionApplication?
    private(set) var currentGeneration: UInt64 = 0
    private var sequence: Int64 = 0
    private var admittedWindowGeneration: UInt64 = 0
    private var admittedWorldWindowGenerations: [Int64: UInt64] = [:]
    private let mailboxLock = NSLock()
    private var pendingInputs: [PendingInput] = []
    private var drainScheduled = false
    private var overflowGeneration: UInt64?
    private var maximumObservedPendingInputs = 0
    private var overflowCount: Int64 = 0
    private let healthLock = NSLock()
    private var observerHealth = AccessibilityObserverHealth.detached(
        generation: 0, reason: "not_started")

    convenience init(
        observer: AccessibilityFocusObserving,
        capture: @escaping ProjectionSnapshotCapture,
        executeOnMain: @escaping ProjectionMainExecutor,
        onHealthChanged: @escaping ProjectionFeedHealthDelivery = { _ in },
        deliver: @escaping ProjectionWorldDelivery
    ) {
        self.init(observer: observer, captureTargeted: { capture($0.application) },
                  executeOnMain: executeOnMain, onHealthChanged: onHealthChanged,
                  deliver: deliver)
    }

    init(
        observer: AccessibilityFocusObserving,
        captureTargeted: @escaping TargetedProjectionSnapshotCapture,
        executeOnMain: @escaping ProjectionMainExecutor,
        onHealthChanged: @escaping ProjectionFeedHealthDelivery = { _ in },
        transientRecovery: ProjectionTransientRecovery? = nil,
        recoverySessionGeneration: @escaping @Sendable () -> UInt64 = { 0 },
        recoveryObservationEpoch: @escaping @Sendable () -> UInt64 = { 0 },
        recoveryPermitted: @escaping @Sendable () -> Bool = { true },
        deliver: @escaping ProjectionWorldDelivery
    ) {
        self.observer = observer
        self.capture = captureTargeted
        self.executeOnMain = executeOnMain
        self.onHealthChanged = onHealthChanged
        self.transientRecovery = transientRecovery
        self.recoverySessionGeneration = recoverySessionGeneration
        self.recoveryObservationEpoch = recoveryObservationEpoch
        self.recoveryPermitted = recoveryPermitted
        self.deliver = deliver

        observer.onEvent = { [weak self] event in
            self?.receiveAccessibilityEvent(event)
        }
        observer.onHealthChanged = { [weak self] health in
            self?.receiveAccessibilityHealth(health)
        }
        onHealthChanged(observerHealth)
    }

    /// Attach the initial frontmost app and synchronously publish world_seed.
    /// The caller invokes this before CoreServer.start(requireWorldSeed:true),
    /// making revision >= 1 a mechanical precondition of socket visibility.
    func start(frontmost application: ProjectionApplication?) {
        rebind(to: application)
        emit(event: "world_seed", extra: [:])
    }

    func spaceChanged(frontmost application: ProjectionApplication?) {
        // Spaces can swap the focused window without changing the app PID;
        // always replace the generation and all AX registrations.
        rebind(to: application)
        emit(event: "space_changed", extra: [:])
    }

    func applicationActivated(_ application: ProjectionApplication?) {
        rebind(to: application)
        if let application {
            emit(event: "app_activated", extra: [
                "frontmost_pid": .int(Int64(application.pid)),
                "frontmost_app": .string(application.name),
            ])
        } else {
            emit(event: "app_activated", extra: [:])
        }
    }

    func applicationLaunched(frontmost application: ProjectionApplication?) {
        rebind(to: application)
        emit(event: "application_launch_recovery", extra: [:])
    }

    func applicationTerminated(
        pid terminatedPid: pid_t,
        frontmost application: ProjectionApplication?
    ) {
        rebind(to: application)
        emit(event: "app_terminated", extra: [
            "terminated_pid": .int(Int64(terminatedPid)),
        ])
    }

    func topologyChanged(frontmost application: ProjectionApplication?) {
        rebind(to: application)
        emit(event: "topology_changed", extra: [:])
    }

    func trustChanged(frontmost application: ProjectionApplication?) {
        rebind(to: application)
        emit(event: "trust_changed", extra: [:])
    }

    func wake(frontmost application: ProjectionApplication?) {
        rebind(to: application)
        emit(event: "wake_recovery", extra: [:])
    }

    func stop() {
        cacheAudit?.stop()
        transientRecovery?.invalidate()
        currentGeneration &+= 1
        admittedWindowGeneration = 0
        admittedWorldWindowGenerations.removeAll()
        setHealth(.detached(
            generation: currentGeneration, reason: "feed_stopping"))
        observer.detach(generation: currentGeneration)
        resetMailbox()
        application = nil
        setHealth(.detached(generation: currentGeneration, reason: "feed_stopped"))
    }

    private func rebind(to application: ProjectionApplication?, rearmRecovery: Bool = true) {
        cacheAudit?.cancelForForeground()
        currentGeneration &+= 1
        if rearmRecovery { cacheAudit?.start() }
        if rearmRecovery { transientRecovery?.rearm(recoveryContext()) }
        admittedWindowGeneration = 0
        admittedWorldWindowGenerations.removeAll()
        resetMailbox()
        // Fail closed before touching registrations: status must not retain a
        // prior generation's positive health during a synchronous rebind.
        setHealth(.detached(
            generation: currentGeneration, reason: "observer_rebinding"))
        observer.detach(generation: currentGeneration)
        self.application = application
        guard let application else {
            setHealth(.detached(
                generation: currentGeneration, reason: "no_frontmost_application"))
            return
        }
        setHealth(observer.attach(to: application.pid, generation: currentGeneration))
    }

    private func receiveAccessibilityEvent(_ event: AccessibilityFocusEvent) {
        cacheAudit?.cancelForForeground()
        enqueue(.accessibility(event))
    }

    /// Background lifecycle events cross the same generation/admission gate as
    /// focused events; the adapter never edits the core or renderer directly.
    func worldAccessibilityEvent(_ event: AccessibilityFocusEvent) {
        receiveAccessibilityEvent(event)
    }

    private func receiveAccessibilityHealth(_ candidate: AccessibilityObserverHealth) {
        cacheAudit?.cancelForForeground()
        enqueue(.health(candidate))
    }

    private func resetMailbox() {
        mailboxLock.lock()
        pendingInputs.removeAll()
        overflowGeneration = nil
        mailboxLock.unlock()
    }

    private func enqueue(_ input: PendingInput) {
        mailboxLock.lock()
        guard overflowGeneration == nil else { mailboxLock.unlock(); return }
        if pendingInputs.count >= Self.maximumPendingInputs {
            // Every queued input loses authority as one explicit failed batch.
            // Recovery replaces observer generations before work can resume.
            overflowGeneration = input.generation
            pendingInputs.removeAll()
            overflowCount += 1
        } else {
            pendingInputs.append(input)
            maximumObservedPendingInputs = max(maximumObservedPendingInputs, pendingInputs.count)
        }
        let schedule = !drainScheduled
        drainScheduled = true
        mailboxLock.unlock()
        if schedule {
            executeOnMain { [weak self] in self?.drainMailbox() }
        }
    }

    private func drainMailbox() {
        while true {
            mailboxLock.lock()
            if let overflowGeneration {
                drainScheduled = false
                mailboxLock.unlock()
                if overflowGeneration == currentGeneration {
                    let failure = "projection_feed_input_overflow"
                    setHealth(.degraded(pid: application?.pid, generation: currentGeneration, reason: failure))
                    emit(event: failure, extra: [:], accessibilityEvent: AccessibilityFocusEvent(
                        kind: .worldObserverDegraded, pid: application?.pid ?? 0,
                        generation: currentGeneration, isWorldObservation: true, degradedReason: failure))
                }
                return
            }
            guard !pendingInputs.isEmpty else {
                drainScheduled = false
                mailboxLock.unlock()
                return
            }
            let input = pendingInputs.removeFirst()
            mailboxLock.unlock()
            guard input.generation == currentGeneration else { continue }
            switch input {
            case .accessibility(let event):
                guard event.isWorldObservation || event.pid == application?.pid,
                      event.isWorldObservation || event.windowGeneration >= admittedWindowGeneration else { continue }
                if event.isWorldObservation, let id = event.windowId {
                    guard event.windowGeneration >= (admittedWorldWindowGenerations[id] ?? 0) else { continue }
                    admittedWorldWindowGenerations[id] = event.windowGeneration
                    if event.kind == .focusedWindowDestroyed { admittedWorldWindowGenerations.removeValue(forKey: id) }
                } else if !event.isWorldObservation { admittedWindowGeneration = event.windowGeneration }
                emit(event: event.kind.rawValue, extra: ["frontmost_pid": .int(Int64(event.pid))], accessibilityEvent: event)
            case .health(let health):
                setHealth(health)
                if health.degradedReason != nil { emit(event: "ax_observer_degraded", extra: [:]) }
            }
        }
    }

    private func emit(event: String, extra: JSONObject,
                      accessibilityEvent: AccessibilityFocusEvent? = nil) {
        cacheAudit?.cancelForForeground()
        let snapshot = capture(ProjectionSnapshotRequest(
            reason: event, application: application,
            observerGeneration: currentGeneration,
            accessibilityEvent: accessibilityEvent,
            lifecyclePid: extra["terminated_pid"]?.intValue.map { pid_t($0) }))
        let health = healthSnapshot()
        sequence += 1
        var delta = extra
        delta["cache_audit_recovery"] = extra["cache_audit_recovery"] ?? .bool(false)
        delta["cache_audit_requires_recovery"] = .bool(false)
        delta["event"] = .string(event)
        delta["seq"] = .int(sequence)
        delta["windows_onscreen"] = .int(snapshot.windowsOnscreen)
        delta["focus"] = snapshot.focus
        delta["observer_generation"] = .int(Int64(currentGeneration))
        delta["window_generation"] = .int(Int64(admittedWindowGeneration))
        delta["observation"] = .object(snapshot.observation)
        delta["observation_window_id"] = snapshot.observation["target_window_id"] ?? .null
        delta["observation_receipt_uptime_ns"] = snapshot.observation["target_receipt_uptime_ns"] ?? .null
        delta["observation_completed_uptime_ns"] = snapshot.observation["target_read_completed_uptime_ns"] ?? .null
        delta["observation_kind"] = snapshot.observation["target_kind"] ?? .null
        delta["observation_window_generation"] = snapshot.observation["target_window_generation"] ?? .null
        mailboxLock.lock()
        delta["feed_queue_capacity"] = .int(Int64(Self.maximumPendingInputs))
        delta["feed_queue_max_depth"] = .int(Int64(maximumObservedPendingInputs))
        delta["feed_queue_overflow_count"] = .int(overflowCount)
        mailboxLock.unlock()
        delta["windows"] = .array(snapshot.windows)
        delta["topology"] = .array(snapshot.topology)
        delta["active_context"] = snapshot.activeContext
        delta["space_contexts"] = .array(snapshot.spaceContexts)
        if let accessibilityEvent {
            delta["notification_window_id"] = accessibilityEvent.windowId.map(JSONValue.int) ?? .null
            delta["notification_receipt_uptime_ns"] = .int(Int64(clamping: accessibilityEvent.receiptUptimeNs))
        }
        delta["focus_observer_ready"] = .bool(health.ready)
        delta["focus_observer_window_ready"] = .bool(health.windowNotificationsReady)
        if let reason = health.degradedReason {
            delta["focus_observer_degraded_reason"] = .string(reason)
        } else {
            delta["focus_observer_degraded_reason"] = .null
        }
        if let application {
            delta["frontmost_pid"] = .int(Int64(application.pid))
            delta["frontmost_app"] = .string(application.name)
        } else {
            delta["frontmost_pid"] = .null
            delta["frontmost_app"] = .null
        }
        if let transientRecovery {
            // A failed focused registration cannot authorize keyboard claims through a cached
            // positive focused read. Preserve valid world identities while focus remains unavailable.
            if !health.ready { delta["focus"] = .null }
            if event == "explicit_recovery", extra["transient_recovery_attempt"]?.boolValue == true {
                var observation = snapshot.observation
                observation["world_recovered"] = .bool(health.ready && observation["world_complete"]?.boolValue == true
                    && (observation["failure_code"] == nil || observation["failure_code"] == .null))
                delta["observation"] = .object(observation)
            }
            delta["transient_recovery"] = transientRecovery.snapshot
        }
        deliver(delta)
        let failures = [snapshot.observation["world_failure_code"]?.stringValue,
                        snapshot.observation["failure_code"]?.stringValue, health.degradedReason].compactMap { $0 }
        if let code = failures.first(where: ProjectionTransientRecovery.isTransient), let transientRecovery {
            transientRecovery.observeFailure(code, context: recoveryContext(), isCurrent: { [weak self] context in
                guard let self else { return false }
                return recoveryPermitted() && recoveryContext() == context
            }, operation: { [weak self] context, firstFailure in
                guard let self else { return }
                rebind(to: application, rearmRecovery: false)
                emit(event: "explicit_recovery", extra: ["transient_recovery_attempt": .bool(true),
                    "transient_recovery_first_failure": .string(firstFailure),
                    "transient_recovery_source_generation": .int(Int64(clamping: context.observerGeneration))])
            })
        }
    }

    private func recoveryContext() -> ProjectionTransientRecovery.Context {
        .init(observerGeneration: currentGeneration, sessionGeneration: recoverySessionGeneration(), observationEpoch: recoveryObservationEpoch())
    }

    /// Root configures this once on the observation lane. The coordinator's completion executor
    /// must be that same lane; its utility worker never calls this feed or mutates snapshot state.
    func configureCacheAudit(_ coordinator: ProjectionCacheIntegrityAudit,
                             makeSeed: @escaping @Sendable (UInt64) -> Result<ProjectionCacheAuditSeed, ProjectionObservationFailure>,
                             finish: @escaping @Sendable (ProjectionCacheAuditSeed, ProjectionCacheAuditProbe) -> JSONObject) {
        cacheAudit = coordinator; makeAuditSeed = makeSeed; finishAudit = finish
        coordinator.onResult = { [weak self] seed, probe, reason in
            guard let self else { return }
            var delta = finish(seed, probe); delta["cache_audit_reason"] = .string(reason)
            deliver(delta)
            if delta["cache_audit_requires_recovery"]?.boolValue == true {
                rebind(to: application, rearmRecovery: false)
                emit(event: "explicit_recovery", extra: ["cache_audit_recovery": .bool(true)])
            }
        }
        coordinator.start()
    }
    /// Explicit one-shot validation request; no ordinary event schedules a recurring census.
    @discardableResult
    func requestCacheAudit(reason: String) -> Bool {
        guard recoveryPermitted(), let cacheAudit, let makeAuditSeed else { return false }
        switch makeAuditSeed(currentGeneration) {
        case .failure(let failure):
            deliver(["event": .string("cache_audit_refused"), "cache_audit_requires_recovery": .bool(false), "cache_integrity": .object([
                "status": .string("refused"), "failure_code": .string(failure.code),
                "session_generation": .int(Int64(clamping: recoverySessionGeneration())),
                "observation_epoch": .int(Int64(clamping: recoveryObservationEpoch()))])]); return false
        case .success(let seed): return cacheAudit.request(seed, reason: reason)
        }
    }
    func cancelCacheAudit() { cacheAudit?.cancelForForeground() }

    private func setHealth(_ health: AccessibilityObserverHealth) {
        healthLock.lock()
        observerHealth = health
        healthLock.unlock()
        onHealthChanged(health)
    }

    private func healthSnapshot() -> AccessibilityObserverHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return observerHealth
    }
}
