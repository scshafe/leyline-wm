// self-test socket — the read-only surface, hermetic: a CoreServer on a temp
// socket with world deltas injected directly (no AppKit, no live world). Each
// scenario below names what it pins, from the frame protocol and peer gate to
// health schema, replay ordering, slow subscribers and the subscriber cap.
import Foundation
import LeylineModel

private func sockConnect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    let fit = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
        pathPtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dest in
            path.withCString { src in
                if strlen(src) >= maxPath { return false }
                strcpy(dest, src)
                return true
            }
        }
    }
    guard fit else { close(fd); return nil }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    _ = withUnsafePointer(to: &tv) {
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
}

private func sockRequest(_ fd: Int32, _ body: JSONObject) -> JSONObject? {
    guard FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(body))),
          let reply = FramedJSONSocket.readFrame(fd),
          let obj = (try? JSONValue.parse(reply))?.objectValue else { return nil }
    return obj
}

private func sockWaitForSubscriberCount(_ path: String, _ expected: Int64) -> Bool {
    for _ in 0..<500 {
        if let fd = sockConnect(path) {
            let status = sockRequest(fd, ["op": .string("status")])
            close(fd)
            if status?["subscribers"]?.intValue == expected { return true }
        }
        usleep(1_000)
    }
    return false
}

private func sockHasExactKeys(_ value: JSONValue?, _ expected: Set<String>) -> Bool {
    guard let object = value?.objectValue else { return false }
    return Set(object.keys) == expected
}

private final class SocketHealthOverlapFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var writerActive = false
    private var writerUpdates = 0
    private var statusReads = 0
    private var readsWhileWriterActive = 0
    private var snapshotsAreWhole = true

    func writerStarted() {
        lock.lock()
        writerActive = true
        lock.unlock()
    }

    func recordedWriterUpdate() {
        lock.lock()
        writerUpdates += 1
        lock.unlock()
    }

    func recordedStatusRead(expected: Int64, status: JSONObject?) {
        let pid = status?["health"]?.at(path: "focus_observer.pid")?.intValue
        let generation = status?["health"]?.at(
            path: "focus_observer.generation")?.intValue
        lock.lock()
        statusReads += 1
        if writerActive { readsWhileWriterActive += 1 }
        if pid != expected || generation != expected {
            snapshotsAreWhole = false
        }
        lock.unlock()
    }

    func failedSynchronization() {
        lock.lock()
        snapshotsAreWhole = false
        lock.unlock()
    }

    func writerFinished() {
        lock.lock()
        writerActive = false
        lock.unlock()
    }

    var result: (
        writerUpdates: Int,
        statusReads: Int,
        readsWhileWriterActive: Int,
        snapshotsAreWhole: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            writerUpdates, statusReads, readsWhileWriterActive,
            snapshotsAreWhole)
    }
}

func runSocketSelfTest() -> Int32 {
    var test = SelfTest()
    func check(_ name: String, _ ok: Bool) { test.check(ok, name) }
    runResidentLifecycleScopeScenarios(check: check)
    runSocketBoundaryScenarios(check: check)

    // Exercise the production transport under the default signal disposition;
    // a global ignore would hide a resident-killing closed-peer bug.
    signal(SIGPIPE, SIG_DFL)
    var closedPair: [Int32] = [-1, -1]
    if socketpair(AF_UNIX, SOCK_STREAM, 0, &closedPair) == 0 {
        close(closedPair[1])
        check("closed peer returns transport failure without terminating the owner",
            !FramedJSONSocket.writeAll(closedPair[0], Data([1])))
        close(closedPair[0])
    } else { check("closed-peer fixture creates actual Unix sockets", false) }

    // Socket visibility is mechanically gated on the synchronous seed, not
    // just ordered that way by CoreMain call sites.
    let seedGatePath = selfTestSocketPath("leylined-seed-gate")
    defer { unlink(seedGatePath) }
    let seedGateServer = CoreServer(socketPath: seedGatePath)
    let refusedBeforeSeed = !seedGateServer.start(requireWorldSeed: true)
    _ = seedGateServer.applyWorldDelta(["event": .string("world_seed")])
    let servedAfterSeed = seedGateServer.start(requireWorldSeed: true)
    check("world seed is a mechanical socket-visibility precondition",
          refusedBeforeSeed && servedAfterSeed && seedGateServer.currentRevision == 1)
    seedGateServer.stop()

    // Row 1 — the pure peer gate matrix.
    let me = geteuid()
    check("peer gate: same euid allows",
          peerGateDecision(peerUid: me, ourUid: me) == .allow)
    check("peer gate: cross uid denies",
          peerGateDecision(peerUid: me &+ 1, ourUid: me) == .deny)
    check("peer gate: unreadable credentials fail closed",
          peerGateDecision(peerUid: nil, ourUid: me) == .deny)

    // A short socket path: sockaddr_un caps at ~104 bytes.
    let path = selfTestSocketPath("leylined-st")
    defer { unlink(path) }
    let server = CoreServer(socketPath: path)
    guard server.start() else {
        check("socket/server-bind \(path)", false)
        return test.finish("socket")
    }
    defer { server.stop() }

    // Row 2 — 0600 perms on the bound socket.
    var st = stat()
    check("socket file mode is 0600",
          stat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)

    // Row 3 — hello: epoch echo + revision 0 before any transition.
    if let fd = sockConnect(path) {
        let hello = sockRequest(fd, ["op": .string("hello")])
        check("hello: ok + epoch echo + revision 0",
              hello?["ok"]?.boolValue == true
                && hello?["epoch_ms"]?.intValue == server.epochMs
                && hello?["revision"]?.intValue == 0)
        // Row 4 — table-prove common mutation spellings all refuse.
        let mutationOps = [
            "act", "apply", "focus", "mode", "move", "mutate",
            "publish", "resize", "set", "world_delta",
        ]
        let refusals = mutationOps.map { operation -> Bool in
            let reply = sockRequest(fd, ["op": .string(operation)])
            if operation == "act" {
                return reply?["ok"]?.boolValue == false
                    && reply?["status"]?.stringValue == "refused"
                    && reply?["error"]?.stringValue == "world_seed_pending"
            }
            return reply?["ok"]?.boolValue == false
                && reply?["error"]?.stringValue == "unknown_op"
                && reply?["op"]?.stringValue == operation
        }
        check("mutation matrix: all common ops refuse on read-only surface",
              refusals.count == mutationOps.count && refusals.allSatisfy { $0 })
        close(fd)
    } else {
        check("hello connection", false)
        check("unknown op connection", false)
    }


    // Health has one stable, complete schema even before daemon adapters have
    // configured their facts. Every unavailable value is explicit/null or a
    // typed degradation; no key disappears from the real socket response.
    // The shape is the CLI fixture `ley doctor` is tested against, so that
    // fixture is proven here rather than authored: every key, nested schemas
    // exact. `resident` is the one conditional key — CoreServer adds it only
    // when supplemental facts exist, and this hermetic server has none.
    let cliFixture = (try? Data(contentsOf: URL(fileURLWithPath:
        SelfTestFixtures.repositoryRoot() + "/tests/native-cli/fixtures/status.json")))
        .flatMap { try? JSONValue.parse($0) }?.at(path: "health")?.objectValue ?? [:]
    let cliKeys = Set(cliFixture.keys).subtracting(["resident"])
    check("cli status fixture names the health keys", cliKeys.count >= 6)
    if let fd = sockConnect(path) {
        let status = sockRequest(fd, ["op": .string("status")])
        let health = status?["health"]
        check("status health schema is exact and null-complete over real socket, as the cli fixture spells it",
              status?["pid"]?.intValue == Int64(getpid())
                && sockHasExactKeys(health, cliKeys)
                && cliKeys.allSatisfy { key in
                    guard let nested = cliFixture[key]?.objectValue else { return true }
                    return sockHasExactKeys(health?.at(path: key), Set(nested.keys))
                }
                && health?.at(path: "schema")?.intValue == 2
                && health?.at(path: "owner") == .string("resident")
                && health?.at(path: "world_seed.revision") == .null
                && health?.at(path: "focus_observer.pid") == .null
                && health?.at(path: "mode_subscription.epoch") == .null
                && health?.at(path: "projection.required") == .null)
        close(fd)
    } else {
        check("status health schema connection", false)
    }

    // Each component mutation is factual-only, while world_seed records its
    // accepted revision under the same lock used by status.
    let healthPath = selfTestSocketPath("leylined-health")
    defer { unlink(healthPath) }
    let healthServer = CoreServer(socketPath: healthPath)
    healthServer.updateFocusObserverHealth(AccessibilityObserverHealth(
        ready: true, pid: 44, generation: 44,
        windowNotificationsReady: true, degradedReason: nil))
    healthServer.updateModeSubscriptionHealth(ModeHealth(
        connected: true, ready: true, epoch: "health-e", sequence: 7,
        degradedReason: nil))
    healthServer.updateProjectionHealth(CoreProjectionHealth(
        required: true, mounted: true, degraded: false,
        degradedReason: nil, lastRenderedRevision: nil))
    let componentOnlyRevision = healthServer.currentRevision
    _ = healthServer.applyWorldDelta(["event": .string("world_seed")])
    healthServer.updateProjectionHealth(CoreProjectionHealth(
        required: true, mounted: true, degraded: false,
        degradedReason: nil, lastRenderedRevision: 1))
    if healthServer.start(requireWorldSeed: true), let fd = sockConnect(healthPath) {
        let status = sockRequest(fd, ["op": .string("status")])
        let health = status?["health"]
        check("component health mutations are revision-free and world seed is atomic",
              componentOnlyRevision == 0
                && status?["revision"]?.intValue == 1
                && status?["world"]?.at(path: "event")?.stringValue == "world_seed"
                && health?.at(path: "owner") == .string("resident")
                && health?.at(path: "world_seed.ready")?.boolValue == true
                && health?.at(path: "world_seed.revision")?.intValue == 1
                && health?.at(path: "focus_observer.ready")?.boolValue == true
                && health?.at(path: "focus_observer.pid")?.intValue == 44
                && health?.at(path: "mode_subscription.connected")?.boolValue == true
                && health?.at(path: "mode_subscription.epoch")?.stringValue
                    == "health-e"
                && health?.at(path: "mode_subscription.sequence")?.intValue == 7
                && health?.at(path: "projection.required")?.boolValue == true
                && health?.at(path: "projection.mounted")?.boolValue == true
                && health?.at(path: "projection.degraded")?.boolValue == false
                && health?.at(path: "projection.last_rendered_revision")?.intValue == 1)

        healthServer.updateFocusObserverHealth(.degraded(
            pid: 44, generation: 45, reason: "ax_untrusted"))
        healthServer.updateModeSubscriptionHealth(ModeHealth(
            connected: false, ready: false, epoch: "health-e", sequence: 7,
            degradedReason: "stream_closed"))
        healthServer.updateProjectionHealth(CoreProjectionHealth(required: nil, mounted: false, degraded: true,
            degradedReason: "screen_height_unavailable", lastRenderedRevision: nil))
        let degradedStatus = sockRequest(fd, ["op": .string("status")])

        healthServer.updateFocusObserverHealth(AccessibilityObserverHealth(
            ready: true, pid: 100, generation: 100,
            windowNotificationsReady: true, degradedReason: nil))
        healthServer.updateModeSubscriptionHealth(ModeHealth(
            connected: true, ready: true, epoch: "health-e", sequence: 8,
            degradedReason: nil))
        healthServer.updateProjectionHealth(CoreProjectionHealth(
            required: true, mounted: true, degraded: false,
            degradedReason: nil, lastRenderedRevision: 1))
        let recoveredStatus = sockRequest(fd, ["op": .string("status")])
        check("all component degradations and recoveries remain explicit and revision-free",
              degradedStatus?["health"]?.at(path: "owner") == .string("resident")
                && degradedStatus?["health"]?.at(
                    path: "focus_observer.degraded_reason")?.stringValue == "ax_untrusted"
                && degradedStatus?["health"]?.at(
                    path: "mode_subscription.connected")?.boolValue == false
                && degradedStatus?["health"]?.at(
                    path: "mode_subscription.degraded_reason")?.stringValue
                    == "stream_closed"
                && degradedStatus?["health"]?.at(
                    path: "projection.degraded")?.boolValue == true
                && recoveredStatus?["health"]?.at(path: "owner") == .string("resident")
                && recoveredStatus?["health"]?.at(
                    path: "focus_observer.degraded_reason") == .null
                && recoveredStatus?["health"]?.at(
                    path: "mode_subscription.sequence")?.intValue == 8
                && recoveredStatus?["health"]?.at(
                    path: "projection.degraded")?.boolValue == false
                && healthServer.currentRevision == 1)

        // Force 300 writer/status overlaps. Both workers rendezvous at the
        // start barrier; then each health update must be observed over the
        // real socket before the writer may advance. Counters prove the reader
        // ran while the writer task was still active, not after it finished.
        let overlapIterations = 300
        let overlap = SocketHealthOverlapFixture()
        let writerReady = DispatchSemaphore(value: 0)
        let readerReady = DispatchSemaphore(value: 0)
        let beginOverlap = DispatchSemaphore(value: 0)
        let updateAvailable = DispatchSemaphore(value: 0)
        let statusObserved = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            overlap.writerStarted()
            writerReady.signal()
            guard beginOverlap.wait(
                timeout: .now() + .seconds(2)) == .success else {
                overlap.failedSynchronization()
                overlap.writerFinished()
                writerDone.signal()
                return
            }
            for offset in 0..<overlapIterations {
                let value = 1_000 + offset
                healthServer.updateFocusObserverHealth(AccessibilityObserverHealth(
                    ready: value.isMultiple(of: 2),
                    pid: pid_t(value), generation: UInt64(value),
                    windowNotificationsReady: value.isMultiple(of: 2),
                    degradedReason: value.isMultiple(of: 2)
                        ? nil : "test_degraded"))
                overlap.recordedWriterUpdate()
                updateAvailable.signal()
                guard statusObserved.wait(
                    timeout: .now() + .seconds(4)) == .success else {
                    overlap.failedSynchronization()
                    break
                }
            }
            overlap.writerFinished()
            writerDone.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            readerReady.signal()
            guard beginOverlap.wait(
                timeout: .now() + .seconds(2)) == .success else {
                overlap.failedSynchronization()
                readerDone.signal()
                return
            }
            for offset in 0..<overlapIterations {
                guard updateAvailable.wait(
                    timeout: .now() + .seconds(4)) == .success else {
                    overlap.failedSynchronization()
                    statusObserved.signal()
                    break
                }
                let expected = Int64(1_000 + offset)
                let concurrent = sockRequest(fd, ["op": .string("status")])
                overlap.recordedStatusRead(
                    expected: expected, status: concurrent)
                statusObserved.signal()
            }
            readerDone.signal()
        }
        let writerReachedBarrier = writerReady.wait(
            timeout: .now() + .seconds(2)) == .success
        let readerReachedBarrier = readerReady.wait(
            timeout: .now() + .seconds(2)) == .success
        beginOverlap.signal()
        beginOverlap.signal()
        let writerFinished = writerDone.wait(
            timeout: .now() + .seconds(10)) == .success
        let readerFinished = readerDone.wait(
            timeout: .now() + .seconds(10)) == .success
        let overlapResult = overlap.result
        check("concurrent health update/status reads force overlap and return whole snapshots",
              writerReachedBarrier && readerReachedBarrier
                && writerFinished && readerFinished
                && overlapResult.writerUpdates == overlapIterations
                && overlapResult.statusReads == overlapIterations
                && overlapResult.readsWhileWriterActive == overlapIterations
                && overlapResult.snapshotsAreWhole
                && healthServer.currentRevision == 1)
        close(fd)
    } else {
        check("component health mutation server/connection", false)
        check("concurrent health mutation server/connection", false)
    }
    healthServer.stop()

    // Rows 5-6 — transitions mint monotonic revisions; status reflects state.
    server.applyWorldDelta(["event": .string("t1"), "n": .int(1)])
    server.applyWorldDelta(["event": .string("t2"), "n": .int(2)])
    server.applyWorldDelta(["event": .string("t3"), "n": .int(3)])
    check("three deltas → revision 3", server.currentRevision == 3)
    if let fd = sockConnect(path) {
        let status = sockRequest(fd, ["op": .string("status")])
        check("status: revision 3 + folded world state",
              status?["revision"]?.intValue == 3
                && status?["world"]?.objectValue?["event"]?.stringValue == "t3"
                && status?["world"]?.objectValue?["n"]?.intValue == 3)
        close(fd)
    } else {
        check("status connection", false)
    }

    // Rows 7-8 — subscribe: replay strictly after from_revision, then live push.
    if let fd = sockConnect(path) {
        var sub: JSONObject = [:]
        sub["op"] = .string("subscribe")
        sub["from_revision"] = .int(1)
        if FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object(sub))) {
            let f2 = FramedJSONSocket.readFrame(fd).flatMap { try? JSONValue.parse($0) }?.objectValue
            let f3 = FramedJSONSocket.readFrame(fd).flatMap { try? JSONValue.parse($0) }?.objectValue
            check("subscribe from 1 replays exactly revisions 2, 3",
                  f2?["revision"]?.intValue == 2 && f3?["revision"]?.intValue == 3)
            server.applyWorldDelta(["event": .string("t4"), "n": .int(4)])
            let f4 = FramedJSONSocket.readFrame(fd).flatMap { try? JSONValue.parse($0) }?.objectValue
            check("live push after subscribe delivers revision 4 with its delta",
                  f4?["revision"]?.intValue == 4
                    && f4?["delta"]?.objectValue?["event"]?.stringValue == "t4")
        } else {
            check("subscribe write", false)
            check("live push", false)
        }
        close(fd)
    } else {
        check("subscribe connection", false)
        check("live push connection", false)
    }

    // Row 9 — an oversized length prefix closes the connection (no reply).
    if let fd = sockConnect(path) {
        var huge = UInt32(200 * 1024 * 1024).bigEndian
        let data = Data(bytes: &huge, count: 4)
        _ = FramedJSONSocket.writeAll(fd, data)
        let reply = FramedJSONSocket.readFrame(fd)
        check("oversized frame prefix → connection closed, no reply", reply == nil)
        close(fd)
    } else {
        check("oversized prefix connection", false)
    }

    // Regression: replay is queued before live publication and one writer
    // serializes both. Start the producer after reading replay revision 1 so
    // live frames race the still-pending replay queue.
    let orderPath = selfTestSocketPath("leylined-order")
    defer { unlink(orderPath) }
    let orderServer = CoreServer(socketPath: orderPath)
    if orderServer.start() {
        defer { orderServer.stop() }
        for revision in 1...256 {
            orderServer.applyWorldDelta([
                "event": .string("order"), "n": .int(Int64(revision)),
            ])
        }
        if let fd = sockConnect(orderPath),
           FramedJSONSocket.writeAll(fd, FramedJSONSocket.encode(.object([
                "op": .string("subscribe"), "from_revision": .int(0),
           ]))) {
            var revisions: [Int64] = []
            if let first = FramedJSONSocket.readFrame(fd)
                .flatMap({ try? JSONValue.parse($0) })?.at(path: "revision")?.intValue {
                revisions.append(first)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                for revision in 257...320 {
                    orderServer.applyWorldDelta([
                        "event": .string("order"), "n": .int(Int64(revision)),
                    ])
                }
            }
            while revisions.count < 320,
                  let revision = FramedJSONSocket.readFrame(fd)
                    .flatMap({ try? JSONValue.parse($0) })?.at(path: "revision")?.intValue {
                revisions.append(revision)
            }
            check("subscribe replay/live ordering is exact under concurrent publish",
                  revisions == Array(1...320).map(Int64.init))
            close(fd)
        } else {
            check("subscribe replay/live ordering connection", false)
        }
    } else {
        check("subscribe replay/live ordering server", false)
    }

    // A non-reading subscriber cannot hold the timeline/status lock. Its
    // bounded writer queue overflows/disconnects independently.
    let slowPath = selfTestSocketPath("leylined-slow")
    defer { unlink(slowPath) }
    let slowServer = CoreServer(
        socketPath: slowPath, maximumSubscriberQueuedFrames: 8)
    if slowServer.start(), let slowFd = sockConnect(slowPath),
       FramedJSONSocket.writeAll(slowFd, FramedJSONSocket.encode(.object([
            "op": .string("subscribe"), "from_revision": .int(0),
       ]))) {
        defer { slowServer.stop() }
        let slowSubscriberReady = sockWaitForSubscriberCount(slowPath, 1)
        let padding = String(repeating: "x", count: 2_048)
        let began = Date()
        for revision in 1...2_300 {
            slowServer.applyWorldDelta([
                "event": .string("slow_writer"),
                "n": .int(Int64(revision)), "padding": .string(padding),
            ])
        }
        let elapsed = Date().timeIntervalSince(began)
        let statusFd = sockConnect(slowPath)
        let status = statusFd.flatMap { sockRequest($0, ["op": .string("status")]) }
        if let statusFd { close(statusFd) }
        let slowSubscriberEvicted = sockWaitForSubscriberCount(slowPath, 0)
        check("slow subscriber never holds core transition/status lock",
              slowSubscriberReady && elapsed < 3
                && status?["revision"]?.intValue == 2_300
                && slowSubscriberEvicted)
        close(slowFd)
    } else {
        check("slow subscriber isolation server/connection", false)
        slowServer.stop()
    }

    // Same-UID clients are not an unbounded resource class: cap push streams,
    // return a typed refusal, and tear down a subscriber on post-subscribe input.
    let capPath = selfTestSocketPath("leylined-cap")
    defer { unlink(capPath) }
    let capServer = CoreServer(socketPath: capPath, maximumSubscribers: 2)
    if capServer.start(), let first = sockConnect(capPath), let second = sockConnect(capPath) {
        defer { capServer.stop() }
        let subscribe = FramedJSONSocket.encode(.object([
            "op": .string("subscribe"), "from_revision": .int(0),
        ]))
        _ = FramedJSONSocket.writeAll(first, subscribe)
        let firstReady = sockWaitForSubscriberCount(capPath, 1)
        _ = FramedJSONSocket.writeAll(second, subscribe)
        let secondReady = sockWaitForSubscriberCount(capPath, 2)
        if let third = sockConnect(capPath) {
            let refusal = sockRequest(third, [
                "op": .string("subscribe"), "from_revision": .int(0),
            ])
            check("subscriber cap returns typed refusal",
                  firstReady && secondReady
                    && refusal?["error"]?.stringValue == "subscriber_limit_reached")
            close(third)
        } else {
            check("subscriber cap refusal connection", false)
        }
        var violation: UInt8 = 1
        _ = write(first, &violation, 1)
        check("post-subscribe client byte tears down push stream",
              sockWaitForSubscriberCount(capPath, 1))
        close(first)
        close(second)
    } else {
        check("subscriber cap server/connections", false)
        capServer.stop()
    }

    return test.finish("socket")
}
