// The resident framed local socket: read, mutation, control and revision subscription.
// All publication and factual health share one lock. Slow subscribers use bounded
// independent queues; they never hold keyboard or authority execution.
import Foundation
import LeylineModel

/// Same-user credentials are mandatory; an unreadable identity fails closed.
enum PeerDecision: String {
    case allow
    case deny
}

func peerGateDecision(peerUid: uid_t?, ourUid: uid_t) -> PeerDecision {
    guard let peerUid else { return .deny }
    return peerUid == ourUid ? .allow : .deny
}

// One ordered writer per subscriber. Replay frames seed the queue before the
// subscriber is published under CoreServer.lock, so later live frames cannot
// overtake replay. Slow or abandoned readers block only this writer and are
// disconnected on timeout/backlog overflow; they never hold the core lock.
private final class CoreSubscriber: @unchecked Sendable {
    private let fd: Int32
    private let condition = NSCondition()
    private var frames: [Data]
    private var stopped = false
    private var readerFinished = false
    private var writerFinished = false
    private var transportClosed = false
    private let maximumQueuedFrames: Int
    private let onStop: @Sendable (CoreSubscriber) -> Void
    private let onClosed: @Sendable () -> Void

    init(
        fd: Int32,
        replay: [Data],
        maximumQueuedFrames: Int,
        onStop: @escaping @Sendable (CoreSubscriber) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.frames = replay
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.onStop = onStop
        self.onClosed = onClosed
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
    }

    func start() {
        // The writer is the transport's lifetime owner. Retain the subscriber
        // until it has observed stop and participated in the single close.
        let thread = Thread { [self] in writerLoop() }
        thread.name = "leylined-core-subscriber-writer"
        thread.start()
    }

    @discardableResult
    func enqueue(_ frame: Data) -> Bool {
        condition.lock()
        guard !stopped, frames.count < maximumQueuedFrames else {
            condition.unlock()
            stop()
            return false
        }
        frames.append(frame)
        condition.signal()
        condition.unlock()
        return true
    }

    func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        condition.broadcast()
        condition.unlock()
        _ = shutdown(fd, SHUT_RDWR)
        onStop(self)
    }

    /// The subscribed connection is push-only. EOF, an error, or any client
    /// byte ends it. This reader and the writer rendezvous before exactly one
    /// close, so neither can use a descriptor number after OS reuse.
    func monitorPushOnlyProtocol() {
        var byte: UInt8 = 0
        _ = read(fd, &byte, 1)
        finishIOOwner(reader: true)
        stop()
    }

    private func writerLoop() {
        defer { finishIOOwner(reader: false) }
        while true {
            condition.lock()
            while frames.isEmpty, !stopped { condition.wait() }
            if stopped {
                condition.unlock()
                return
            }
            let frame = frames.removeFirst()
            condition.unlock()
            guard FramedJSONSocket.writeAll(fd, frame) else {
                stop()
                return
            }
        }
    }

    private func finishIOOwner(reader: Bool) {
        condition.lock()
        if reader {
            readerFinished = true
        } else {
            writerFinished = true
        }
        let shouldClose = readerFinished && writerFinished && !transportClosed
        if shouldClose { transportClosed = true }
        condition.unlock()
        if shouldClose { onClosed() }
    }
}

final class CoreServer: @unchecked Sendable {
    let socketPath: String
    let epochMs: Int64
    let observerEpoch = UUID().uuidString
    private let startedMs: Int64

    private let lock = NSLock()
    private let transitionLock = NSLock()
    private var timeline: Timeline<JSONValue>
    private var ring: [(revision: UInt64, frame: Data)] = []
    private let ringCap = 1024
    private let maximumSubscribers: Int
    private let maximumSubscriberQueuedFrames: Int
    private var subscribers: [ObjectIdentifier: CoreSubscriber] = [:]
    private var connections: Set<Int32> = []
    private let maximumConnections: Int
    private var modeCursor = ModeFrameCursor()
    private var snapshotHandler: (@Sendable (CoreCommittedSnapshot) -> Void)?
    private var commandHandler: (@Sendable (JSONObject) -> JSONValue)?
    private var residentControlHandler: (@Sendable (JSONObject) -> JSONValue)?
    private var registeredActionIDs: [String] = []
    private var residentHealth: JSONObject = [:]
    private var health = CoreHealthSnapshot.initial
    private var listenFd: Int32 = -1
    private var running = false
    private var observationEpochValue: UInt64 = 0
    private var committedReceiptUptimeNs: UInt64 = 0

    init(
        socketPath: String,
        maximumSubscribers: Int = 64,
        maximumConnections: Int = 128,
        maximumSubscriberQueuedFrames: Int = 2_048,
        initialRevision: UInt64 = 0,
        initialState: JSONValue = .object([:])
    ) {
        self.socketPath = socketPath
        self.maximumSubscribers = max(1, maximumSubscribers)
        self.maximumConnections = max(1, maximumConnections)
        self.maximumSubscriberQueuedFrames = max(1, maximumSubscriberQueuedFrames)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        self.epochMs = now
        self.startedMs = now
        self.timeline = Timeline(state: initialState, revision: Revision(initialRevision))
    }

    // ── lifecycle ────────────────────────────────────────────────────────

    func start(requireWorldSeed: Bool = false) -> Bool {
        lock.lock()
        let seedReady = health.worldSeed.ready
        lock.unlock()
        guard !requireWorldSeed || seedReady else { return false }
        let parentPath = (socketPath as NSString).deletingLastPathComponent
        let name = (socketPath as NSString).lastPathComponent
        let parent: Int32
        do { parent = try ResidentPrivateFiles.openDirectory(at: parentPath, create: true) }
        catch {
            FileHandle.standardError.write(Data("leylined: SOCKET.DIRECTORY_UNSAFE \(error)\n".utf8))
            return false
        }
        defer { close(parent) }
        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == geteuid() else { return false }
            if let alive = FramedJSONSocket.connect(path: socketPath, timeoutSeconds: 1) { close(alive); return false }
            guard unlinkat(parent, name, 0) == 0 else { return false }
        } else if errno != ENOENT { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return false }
        guard let bound = FramedJSONSocket.withSocketAddress(path: socketPath, { bind(fd, $0, $1) }), bound == 0 else {
            close(fd); return false
        }
        guard fchmodat(parent, name, mode_t(0o600), 0) == 0, listen(fd, 16) == 0 else {
            close(fd); _ = unlinkat(parent, name, 0); return false
        }
        lock.lock()
        listenFd = fd
        running = true
        lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "leylined-core-accept"
        t.start()
        return true
    }

    func stop() {
        lock.lock()
        running = false
        let descriptor = listenFd
        listenFd = -1
        let currentSubscribers = Array(subscribers.values)
        for connection in connections { _ = shutdown(connection, SHUT_RDWR) }
        subscribers.removeAll()
        lock.unlock()
        for subscriber in currentSubscribers { subscriber.stop() }
        if descriptor >= 0 {
            _ = shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            unlink(socketPath)
        }
    }

    // ── the world feed (process-internal; never a wire op) ───────────────

    /// End the interaction: default mode, no held context, no model interaction record.
    private static func exitInteraction(_ s: inout JSONObject) {
        s["mode"] = .string("default"); s["interaction_invalidated"] = .bool(true)
        s["mode_context_window_id"] = .null
        s["mode_context_space_key"] = .null
        if var model = s["model_state"]?.objectValue { model.removeValue(forKey: "interaction"); s["model_state"] = .object(model) }
    }

    /// The one entry world events funnel through: a synchronous transition on
    /// the single-actor timeline. The observation lane delivers here in
    /// production; the self-tests call it directly.
    @discardableResult
    func applyWorldDelta(_ delta: JSONObject, expectedRevision: UInt64? = nil, requiredObservationEpoch: UInt64? = nil,
                         commitGuard: (@Sendable () -> String?)? = nil) -> WmResult {
        // Publication is part of the single-actor transition order. Core
        // writes remain off `lock`, but a second in-process caller cannot
        // enqueue revision N+1 before N has reached every subscriber queue.
        transitionLock.lock()
        defer { transitionLock.unlock() }
        lock.lock()
        if let requiredObservationEpoch,
           (requiredObservationEpoch != observationEpochValue || timeline.state.at(path: "management_enabled")?.boolValue == false) {
            let result = WmResult(status: .refused, revision: timeline.revision, reason: "observation_epoch_retired")
            lock.unlock(); return result
        }
        if let expectedRevision, expectedRevision != timeline.revision.value {
            let result = WmResult(status: .refused, revision: timeline.revision,
                                  reason: "expected_revision_mismatch")
            lock.unlock()
            return result
        }
        // Pure admission check at the authority boundary, after any wait for
        // this transition. It must not re-enter the server or perform IO.
        if let reason = commitGuard?() {
            let result = WmResult(status: .refused, revision: timeline.revision, reason: reason)
            lock.unlock(); return result
        }
        if WorldEvent.epochRetiring.contains(delta["event"]?.stringValue ?? "") {
            observationEpochValue &+= 1
        }
        if delta["event"]?.stringValue == "space_activation_changed",
           let key = delta["target_space_key"]?.stringValue,
           let enabled = delta["target_space_enabled"]?.boolValue,
           (timeline.state.at(path: "space_activation")?.objectValue?[key]?.boolValue ?? true) == enabled {
            let result = WmResult(status: .noop, revision: timeline.revision, reason: "space_activation_unchanged")
            lock.unlock()
            return result
        }
        let receipt = DispatchTime.now().uptimeNanoseconds
        let nextRevision = timeline.revision.value + 1
        let result = timeline.apply { state in
            var s = state.objectValue ?? [:]
            s["observer_epoch"] = .string(observerEpoch)
            let previousTopology = s["topology"]
            for (k, v) in delta { s[k] = v }
            s["interaction_invalidated"] = .bool(delta["mode"] == .string("default")
                && ["move", "resize"].contains(state.at(path: "mode")?.stringValue ?? "default"))
            if let topology = delta["topology"], topology != previousTopology {
                s["topology_revision"] = .int(Int64(clamping: nextRevision))
            }
            let event = delta["event"]?.stringValue ?? ""
            let isWindowLifecycle = AccessibilityFocusEventKind.isWindowLifecycle(event)
            if isWindowLifecycle {
                // A lifecycle receipt owns its target. Missing new source fields
                // cannot inherit a prior ignored window's identity or receipt.
                s["notification_window_id"] = delta["notification_window_id"] ?? .null
                s["notification_receipt_uptime_ns"] = delta["notification_receipt_uptime_ns"] ?? .null
            }
            let originSpaces = Self.interactionSpaceKeys(timelineStateBefore: state)
            var affectedSpaces = Set<String>()
            if event == "space_activation_changed", let key = delta["target_space_key"]?.stringValue {
                affectedSpaces.insert(key)
            } else if event == "settings_changed", let replacement = delta["space_activation"]?.objectValue {
                let old = state.at(path: "space_activation")?.objectValue ?? [:]
                let keys = Set(old.keys + replacement.keys)
                for key in keys where (old[key]?.boolValue ?? true) != (replacement[key]?.boolValue ?? true) { affectedSpaces.insert(key) }
            }
            if event == "space_activation_changed" || event == "settings_changed" {
                s["invalidation_space_keys"] = .array(affectedSpaces.sorted().map(JSONValue.string))
            } else { s["invalidation_space_keys"] = .array([]) }
            let activationTouchesInteraction = !originSpaces.isDisjoint(with: affectedSpaces)
            let windowLifecycleInvalidates = isWindowLifecycle
                && residentLifecycleInvalidatesInteraction(event: event, before: state, after: .object(s))
            if windowLifecycleInvalidates || WorldEvent.spaceOrLifetimeFence.contains(event)
                || ((event == "space_activation_changed" || event == "settings_changed") && activationTouchesInteraction) {
                CoreServer.exitInteraction(&s)
            }
            if delta["event"]?.stringValue == "space_activation_changed",
               let key = delta["target_space_key"]?.stringValue,
               let enabled = delta["target_space_enabled"]?.boolValue {
                var activation = s["space_activation"]?.objectValue ?? [:]
                activation[key] = .bool(enabled)
                s["space_activation"] = .object(activation)
                if var focus = s["focus"]?.objectValue,
                   focus["space_key"]?.stringValue == key {
                    focus["space_enabled"] = .bool(enabled)
                    s["focus"] = .object(focus)
                    if !enabled { s["mode"] = .string("default"); s["interaction_invalidated"] = .bool(true) }
                }
            }
            if var focus = s["focus"]?.objectValue,
               let key = focus["space_key"]?.stringValue,
               let activation = s["space_activation"]?.objectValue {
                focus["space_enabled"] = .bool(activation[key]?.boolValue ?? true)
                s["focus"] = .object(focus)
            }
            if let windows = s["windows"]?.arrayValue,
               let activation = s["space_activation"]?.objectValue {
                s["windows"] = .array(windows.map { window in
                    var record = window.objectValue ?? [:]
                    if let key = record["space_key"]?.stringValue {
                        record["space_enabled"] = .bool(activation[key]?.boolValue ?? true)
                    }
                    return .object(record)
                })
            }
            if let activation = s["space_activation"]?.objectValue {
                if var context = s["active_context"]?.objectValue, let key = context["space_key"]?.stringValue {
                    context["space_enabled"] = .bool(activation[key]?.boolValue ?? true)
                    s["active_context"] = .object(context)
                }
                if let contexts = s["space_contexts"]?.arrayValue {
                    s["space_contexts"] = .array(contexts.map { context in
                        var value = context.objectValue ?? [:]
                        if let key = value["space_key"]?.stringValue { value["space_enabled"] = .bool(activation[key]?.boolValue ?? true) }
                        return .object(value)
                    })
                }
            }
            let boundMoveOrigin = s["mode"]?.stringValue == "move"
                && s["mode_context_window_id"]?.intValue.map { origin in
                    (s["windows"]?.arrayValue ?? []).contains { window in
                        window.at(path: "window_id")?.intValue == origin
                            && window.at(path: "eligible")?.boolValue == true
                            && window.at(path: "managed")?.boolValue == true
                            && window.at(path: "space_visible")?.boolValue == true
                            && window.at(path: "space_enabled")?.boolValue == true
                            && window.at(path: "space_key")?.stringValue == s["mode_context_space_key"]?.stringValue
                            && window.at(path: "minimized")?.boolValue != true
                            && window.at(path: "destroyed")?.boolValue != true
                    }
                } == true
            if s["mode"]?.stringValue != "default", !boundMoveOrigin,
               let origin = s["mode_context_window_id"]?.intValue,
               (s["focus"]?.at(path: "window_id")?.intValue != origin
                || s["focus"]?.at(path: "space_key")?.stringValue != s["mode_context_space_key"]?.stringValue) {
                CoreServer.exitInteraction(&s)
            }
            if s["model_state"] != state.at(path: "model_state") {
                s["model_state_revision"] = .int(Int64(nextRevision))
            }
            s["last_delta_unix_ms"] = .int(Int64(Date().timeIntervalSince1970 * 1000))
            state = .object(s)
            return .accepted
        }
        if delta["event"]?.stringValue == "world_seed",
           result.status == .accepted {
            mutateHealthLocked { health in
                health.worldSeed = CoreWorldSeedHealth(
                    ready: true, revision: result.revision.value)
            }
        }
        if result.status == .accepted { committedReceiptUptimeNs = receipt }
        let publication = preparePublicationLocked(delta: delta, result: result, receipt: receipt)
        lock.unlock()
        publish(publication)
        return result
    }

    /// Fold one admitted in-process mode frame into the authoritative world.
    /// Duplicate/stale sequences, retired epochs, and non-snapshot epoch
    /// baselines are true noops: they mint no revision and publish no frame.
    @discardableResult
    func applyModeFrame(_ modeFrame: ModeFrame, commitGuard: (@Sendable () -> String?)? = nil) -> WmResult {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        lock.lock()
        if let reason = commitGuard?() {
            let result = WmResult(status: .refused, revision: timeline.revision, reason: reason)
            lock.unlock(); return result
        }
        var candidateCursor = modeCursor
        guard candidateCursor.admit(modeFrame) == .accepted else {
            let result = WmResult(
                status: .noop, revision: timeline.revision,
                reason: "stale_or_duplicate_mode_frame")
            lock.unlock()
            return result
        }
        let receipt = DispatchTime.now().uptimeNanoseconds
        let nextRevision = timeline.revision.value + 1
        let delta: JSONObject = [
            "event": .string("mode_changed"),
            "mode": .string(modeFrame.mode),
            "mode_epoch": .string(modeFrame.epoch),
            "mode_sequence": .int(modeFrame.sequence),
            "resets_interaction": .bool(modeFrame.resetsInteraction),
            "mode_input_generation": modeFrame.inputGeneration.map { .int(Int64(clamping: $0)) } ?? .null,
            "interaction_invalidated": .bool(modeFrame.resetsInteraction && modeFrame.mode == "default"),
        ]
        let result = timeline.apply { state in
            var world = state.objectValue ?? [:]
            let previousMode = world["mode"]?.stringValue
            for (key, value) in delta { world[key] = value }
            world["observer_epoch"] = .string(observerEpoch)
            if modeFrame.resetsInteraction, var model = world["model_state"]?.objectValue {
                model.removeValue(forKey: "interaction")
                world["model_state"] = .object(model)
                world["model_state_revision"] = .int(Int64(nextRevision))
            }
            if modeFrame.mode == "default" {
                world["mode_context_window_id"] = .null
                world["mode_context_space_key"] = .null
            } else if previousMode != modeFrame.mode || modeFrame.resetsInteraction {
                world["mode_context_window_id"] = world["focus"]?.at(path: "window_id") ?? .null
                world["mode_context_space_key"] = world["focus"]?.at(path: "space_key") ?? .null
            }
            world["last_delta_unix_ms"] = .int(
                Int64(Date().timeIntervalSince1970 * 1000))
            state = .object(world)
            return .accepted
        }
        modeCursor = candidateCursor
        if result.status == .accepted { committedReceiptUptimeNs = receipt }
        let publication = preparePublicationLocked(delta: delta, result: result, receipt: receipt)
        lock.unlock()
        publish(publication)
        return result
    }

    private func preparePublicationLocked(
        delta: JSONObject,
        result: WmResult,
        receipt: UInt64
    ) -> (frame: Data, subscribers: [CoreSubscriber], snapshot: CoreCommittedSnapshot, handler: (@Sendable (CoreCommittedSnapshot) -> Void)?)? {
        guard result.status == .accepted else { return nil }
        var frameObj: JSONObject = [:]
        frameObj["type"] = .string("revision")
        frameObj["revision"] = .int(Int64(result.revision.value))
        frameObj["delta"] = .object(delta)
        let frame = FramedJSONSocket.encode(.object(frameObj))
        ring.append((result.revision.value, frame))
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        return (frame, Array(subscribers.values),
                CoreCommittedSnapshot(revision: result.revision.value,
                                      world: timeline.state, receiptUptimeNs: receipt),
                snapshotHandler)
    }

    private func publish(_ publication: (frame: Data, subscribers: [CoreSubscriber], snapshot: CoreCommittedSnapshot, handler: (@Sendable (CoreCommittedSnapshot) -> Void)?)?) {
        guard let publication else { return }
        publication.handler?(publication.snapshot)
        for subscriber in publication.subscribers {
            _ = subscriber.enqueue(publication.frame)
        }
    }

    /// Called in commit order; handlers must only enqueue bounded work.
    func setCommittedSnapshotHandler(_ handler: (@Sendable (CoreCommittedSnapshot) -> Void)?) {
        transitionLock.lock()
        lock.lock()
        snapshotHandler = handler
        lock.unlock()
        transitionLock.unlock()
    }

    var committedSnapshot: CoreCommittedSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CoreCommittedSnapshot(revision: timeline.revision.value,
                                     world: timeline.state,
                                     receiptUptimeNs: committedReceiptUptimeNs)
    }

    /// A newly independently identified Space defaults ON, only within this
    /// process epoch. Persisting across login remains an unresolved preference.
    func spaceIsEnabled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeline.state.at(path: "space_activation")?.objectValue?[key]?.boolValue ?? true
    }

    private static func interactionSpaceKeys(timelineStateBefore world: JSONValue) -> Set<String> {
        let interaction = world.at(path: "model_state.interaction")
        var ids = Set<Int64>()
        for field in ["source_window_id", "cursor_window_id"] {
            if let id = interaction?.at(path: field)?.intValue { ids.insert(id) }
        }
        for id in interaction?.at(path: "span_window_ids")?.arrayValue ?? [] { if let value = id.intValue { ids.insert(value) } }
        if let id = world.at(path: "mode_context_window_id")?.intValue { ids.insert(id) }
        var spaces = Set((world.at(path: "windows")?.arrayValue ?? []).filter {
            $0.at(path: "window_id")?.intValue.map(ids.contains) == true
        }.compactMap { $0.at(path: "space_key")?.stringValue })
        if let key = world.at(path: "mode_context_space_key")?.stringValue { spaces.insert(key) }
        return spaces
    }

    func setSpaceEnabled(_ key: String, enabled: Bool) -> WmResult {
        guard !key.isEmpty, !key.contains("runtime:") else {
            return WmResult(status: .refused, revision: Revision(currentRevision),
                            reason: "space_identity_unavailable")
        }
        return applyWorldDelta([
            "event": .string("space_activation_changed"),
            "target_space_key": .string(key), "target_space_enabled": .bool(enabled),
        ])
    }

    /// A mutation surface exists only after a resident dispatcher is installed.
    /// Requests never fall back to the legacy shell or one-shot actuation.
    /// Integrity-only liveness proof: never waits for a blocked transition,
    /// reads no external world, and mints no state or revision.
    func probeAuthority() -> Bool {
        guard transitionLock.try() else { return false }
        lock.lock()
        let responsive = running
        lock.unlock()
        transitionLock.unlock()
        return responsive
    }

    func configureCommands(actionIDs: [String], handler: @escaping @Sendable (JSONObject) -> JSONValue) {
        lock.lock()
        registeredActionIDs = actionIDs.sorted()
        commandHandler = handler
        lock.unlock()
    }

    /// Lifecycle controls remain available while ordinary management is OFF.
    /// Their handler is the same in-process maintenance owner used by the menu.
    func configureResidentControls(handler: @escaping @Sendable (JSONObject) -> JSONValue) {
        lock.lock(); residentControlHandler = handler; lock.unlock()
    }

    var worldSeedReady: Bool {
        lock.lock(); defer { lock.unlock() }; return health.worldSeed.ready
    }
    var observationEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return observationEpochValue
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return timeline.revision.value
    }

    /// The committed world state, for in-process projection subscribers
    /// (read-only: projections consume revisions, they never write).
    var worldState: JSONValue {
        lock.lock()
        defer { lock.unlock() }
        return timeline.state
    }

    // ── factual health (process-internal; never timeline revisions) ───────

    func updateFocusObserverHealth(_ observerHealth: AccessibilityObserverHealth) {
        lock.lock()
        mutateHealthLocked { health in
            health.focusObserver = CoreFocusObserverHealth(observerHealth)
        }
        lock.unlock()
    }

    func updateModeSubscriptionHealth(_ subscriberHealth: ModeHealth) {
        lock.lock()
        mutateHealthLocked { health in
            health.modeSubscription = CoreModeSubscriptionHealth(subscriberHealth)
        }
        lock.unlock()
    }

    func updateResidentHealth(_ componentHealth: JSONObject) {
        lock.lock()
        residentHealth = residentHealth.merging(componentHealth)
        lock.unlock()
    }

    func updateProjectionHealth(_ projectionHealth: CoreProjectionHealth) {
        lock.lock()
        mutateHealthLocked { health in
            health.projection = projectionHealth
        }
        lock.unlock()
    }

    /// All component assignments pass through one canonical lock-held helper;
    /// health never uses the transition/publish path and cannot mint a revision.
    private func mutateHealthLocked(
        _ mutation: (inout CoreHealthSnapshot) -> Void
    ) {
        mutation(&health)
    }

    // ── accept + per-connection handling ─────────────────────────────────

    private func acceptLoop() {
        while true {
            lock.lock()
            let listening = running && listenFd >= 0 ? dup(listenFd) : -1
            lock.unlock()
            guard listening >= 0 else { return }
            _ = fcntl(listening, F_SETFD, FD_CLOEXEC)
            let fd = accept(listening, nil, nil)
            close(listening)
            lock.lock()
            let alive = running
            lock.unlock()
            guard alive else {
                if fd >= 0 { close(fd) }
                return
            }
            guard fd >= 0 else { continue }
            var uid: uid_t = 0
            var gid: gid_t = 0
            let credRc = getpeereid(fd, &uid, &gid)
            let decision = peerGateDecision(peerUid: credRc == 0 ? uid : nil, ourUid: geteuid())
            if decision == .deny {
                FileHandle.standardError.write(Data("leylined: SOCKET.PEER_REJECTED\n".utf8))
                close(fd)
                continue
            }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                close(fd); continue
            }
            lock.lock()
            let admitted = running && connections.count < maximumConnections
            if admitted { connections.insert(fd) }
            lock.unlock()
            guard admitted else { close(fd); continue }
            let t = Thread { [self] in handle(fd: fd) }
            t.name = "leylined-core-conn"
            t.start()
        }
    }

    private func handle(fd: Int32) {
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred { connectionClosed(fd) }
        }
        while true {
            guard let req = FramedJSONSocket.readFrame(fd, maximumBytes: 65_536, timeoutMilliseconds: 2_000) else { return }
            guard let obj = (try? JSONValue.parse(req))?.objectValue,
                  let op = obj["op"]?.stringValue else {
                _ = FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(["ok": .bool(false), "error": .string("bad_frame")])))
                return
            }
            switch op {
            case "hello":
                var r: JSONObject = [:]
                r["ok"] = .bool(true)
                r["op"] = .string("hello")
                r["epoch_ms"] = .int(epochMs)
                r["revision"] = .int(Int64(currentRevision))
                r["ready"] = .bool(worldSeedReady)
                r["pid"] = .int(Int64(ProcessInfo.processInfo.processIdentifier))
                lock.lock()
                let actions = registeredActionIDs
                let hasControls = residentControlHandler != nil
                lock.unlock()
                r["surface"] = .string(actions.isEmpty ? "read-only" : "resident-actions")
                r["capabilities"] = .array(actions.map(JSONValue.string))
                r["resident_control_capabilities"] = .array(hasControls ? ResidentControlAction.allCases.map { JSONValue.string($0.rawValue) } : [])
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(r))) else { return }
            case "status", "snapshot", "health":
                if op == "snapshot", !worldSeedReady {
                    guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(["ok": .bool(false), "error": .string("world_seed_pending"),
                        "op": .string(op), "world": .null, "ready": .bool(false)]))) else { return }
                    continue
                }
                lock.lock()
                let state = timeline.state
                let rev = timeline.revision.value
                let subs = subscribers.count
                let clients = connections.count
                let healthSnapshot = health
                let supplemental = residentHealth
                lock.unlock()
                var r: JSONObject = [:]
                r["ok"] = .bool(true)
                r["op"] = .string("status")
                r["epoch_ms"] = .int(epochMs)
                r["pid"] = .int(Int64(ProcessInfo.processInfo.processIdentifier))
                r["revision"] = .int(Int64(rev))
                r["uptime_ms"] = .int(Int64(Date().timeIntervalSince1970 * 1000) - startedMs)
                r["world"] = state
                r["subscribers"] = .int(Int64(subs))
                r["connections"] = .int(Int64(clients))
                r["connection_limit"] = .int(Int64(maximumConnections))
                var facts = healthSnapshot.json.objectValue ?? [:]
                if !supplemental.isEmpty { facts["resident"] = .object(supplemental) }
                r["health"] = .object(facts)
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(r))) else { return }
            case "trace":
                let arguments = obj["args"] ?? .object([:])
                let from = arguments.at(path: "from_sequence")?.intValue ?? 0
                let limit = arguments.at(path: "limit")?.intValue ?? 128
                guard let fields = arguments.objectValue,
                      Set(fields.keys).isSubset(of: ["from_sequence", "limit"]),
                      fields["from_sequence"] == nil || fields["from_sequence"]?.intValue != nil,
                      fields["limit"] == nil || fields["limit"]?.intValue != nil,
                      from >= 0, limit > 0, limit <= 128 else {
                    _ = FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(["ok": .bool(false), "reason": .string("trace_arguments_invalid")]))); continue
                }
                var trace = ResidentPerformanceTrace.shared.snapshot(from: UInt64(from), limit: Int(limit)).objectValue!
                trace["ok"] = .bool(true); trace["pid"] = .int(Int64(ProcessInfo.processInfo.processIdentifier))
                trace["revision"] = .int(Int64(currentRevision))
                trace["epoch_ms"] = .int(epochMs)
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(trace))) else { return }
            case "control", "control-result":
                lock.lock()
                let control = residentControlHandler
                lock.unlock()
                let response: JSONValue
                if let control { response = control(obj) }
                else {
                    response = ResidentReply.refused(requestID: obj["request_id"] ?? .null, reason: "resident_control_unavailable")
                }
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(response)) else { return }
            case "act", "result":
                lock.lock()
                let handler = commandHandler
                let actions = registeredActionIDs
                lock.unlock()
                let response: JSONValue
                if !worldSeedReady {
                    response = .object(["ok": .bool(false), "status": .string(WmStatus.refused.rawValue), "error": .string("world_seed_pending")])
                } else if op == "result", let handler,
                          let requestID = obj["request_id"]?.stringValue, !requestID.isEmpty {
                    response = handler(obj)
                } else if let action = obj["action_id"]?.stringValue,
                          actions.contains(action), let handler,
                          let requestID = obj["request_id"]?.stringValue, !requestID.isEmpty {
                    response = handler(obj)
                } else {
                    response = .object(["ok": .bool(false), "status": .string(WmStatus.refused.rawValue), "error": .string("unregistered_action_or_missing_request_id")])
                }
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(response)) else { return }
            case "subscribe":
                let rawFrom = obj["from_revision"]?.intValue ?? 0
                let from = rawFrom > 0 ? UInt64(rawFrom) : 0
                lock.lock()
                guard subscribers.count < maximumSubscribers else {
                    lock.unlock()
                    let refusal: JSONObject = [
                        "ok": .bool(false),
                        "error": .string("subscriber_limit_reached"),
                        "surface": .string("read-only"),
                    ]
                    guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(refusal))) else {
                        return
                    }
                    continue
                }
                let replay = ring.filter { $0.revision > from }.map(\.frame)
                var receiveTimeout = timeval(tv_sec: 0, tv_usec: 0)
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { lock.unlock(); return }
                let subscriber = CoreSubscriber(
                    fd: fd, replay: replay,
                    maximumQueuedFrames: maximumSubscriberQueuedFrames,
                    onStop: { [weak self] subscriber in
                        self?.removeSubscriber(subscriber)
                    }, onClosed: { [weak self] in self?.connectionClosed(fd) })
                subscribers[ObjectIdentifier(subscriber)] = subscriber
                lock.unlock()
                ownershipTransferred = true
                subscriber.start()
                // The connection is now push-only. EOF is normal; any byte is
                // a protocol violation and tears down this subscriber rather
                // than being silently consumed as an unbounded side channel.
                subscriber.monitorPushOnlyProtocol()
                return
            default:
                var r: JSONObject = [:]
                r["ok"] = .bool(false)
                r["error"] = .string("unknown_op")
                r["op"] = .string(op)
                r["surface"] = .string("resident (hello|status|snapshot|health|subscribe|act|result|control|control-result|trace)")
                guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(r))) else { return }
            }
        }
    }

    private func connectionClosed(_ fd: Int32) {
        lock.lock()
        if connections.remove(fd) != nil { close(fd) }
        lock.unlock()
    }

    private func removeSubscriber(_ subscriber: CoreSubscriber) {
        lock.lock()
        subscribers.removeValue(forKey: ObjectIdentifier(subscriber))
        lock.unlock()
    }

    // ── frame IO ─────────────────────────────────────────────────────────

}
