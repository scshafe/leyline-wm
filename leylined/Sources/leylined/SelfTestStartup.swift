import Darwin
import Foundation
import LeylineModel

private final class StartupTestRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var commands = 0
    private var captures = 0
    private var discarded = 0
    private var results: [WmResult] = []

    func command(_ body: JSONObject) -> JSONValue {
        lock.withLock { commands += 1 }
        return .object(["ok": .bool(true), "request_id": body["request_id"] ?? .null])
    }
    func captured() { lock.withLock { captures += 1 } }
    func discard() { lock.withLock { discarded += 1 } }
    func record(_ result: WmResult) { lock.withLock { results.append(result) } }
    var counts: (commands: Int, captures: Int, discarded: Int) {
        lock.withLock { (commands, captures, discarded) }
    }
    var lastResult: WmResult? { lock.withLock { results.last } }
}

/// Holding the executor models a blocked AppKit presentation lane without
/// creating panels or entering an application event loop.
private func startupReadFrame(_ descriptor: Int32) -> JSONValue? {
    guard let data = FramedJSONSocket.readFrame(descriptor) else { return nil }
    return try? JSONValue.parse(data)
}

/// Injected workers drive the production startup coordinator and real socket.
/// No live AX, event tap, renderer, control, or subprocess is constructed.
func runStartupSelfTest() -> Int32 {
    var test = SelfTest()
    func check(_ name: String, _ passed: Bool) { test.check(passed, name) }
    runResidentStartupSeedGateScenarios(check: check)
    let fixtureURL = SelfTestFixtures.url("startup/bootstrap-worlds.json")
    do {
        let fixture = try JSONValue.parse(Data(contentsOf: fixtureURL))
        guard let blockedWorlds = fixture.at(path: "blocked_worlds")?.arrayValue, !blockedWorlds.isEmpty,
              let command = fixture.at(path: "command")?.objectValue,
              let fresh = fixture.at(path: "fresh_delta")?.objectValue,
              let stop = fixture.at(path: "stop_delta")?.objectValue,
              let restart = fixture.at(path: "restart_delta")?.objectValue,
              let resume = fixture.at(path: "resume_delta")?.objectValue,
              let empty = fixture.at(path: "empty_complete_world")?.objectValue,
              let incomplete = fixture.at(path: "incomplete_world")?.objectValue,
              let journalFailure = fixture.at(path: "journal_failure_world"),
              let actionID = command["action_id"]?.stringValue else {
            throw NSError(domain: "startup_fixture_invalid", code: 1)
        }
        let publicationURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("cache-audit-publication.json")
        let publication = try JSONValue.parse(Data(contentsOf: publicationURL))
        guard let publicationSession = publication.at(path: "session_generation")?.intValue, publicationSession >= 0,
              let publicationRows = publication.at(path: "rows")?.arrayValue, !publicationRows.isEmpty else {
            throw NSError(domain: "startup_publication_fixture_invalid", code: 1)
        }
        for row in publicationRows {
            guard let name = row.at(path: "name")?.stringValue,
                  let delta = row.at(path: "delta")?.objectValue,
                  let admitted = row.at(path: "admitted")?.boolValue else {
                throw NSError(domain: "startup_publication_fixture_invalid", code: 2)
            }
            let scope = CoreObservationPublicationScope.admit(delta, sessionGeneration: UInt64(publicationSession))
            check(name + ": production session/audit token gate", (scope != nil) == admitted)
            if let scope, let expectedEpoch = row.at(path: "required_epoch")?.intValue {
                check(name + ": audit retains required global epoch", scope.requiredEpoch == UInt64(expectedEpoch))
                let publicationServer = CoreServer(socketPath: selfTestSocketPath("leylined-audit-publication"))
                let stopped = row.at(path: "stop_before_publish")?.boolValue == true
                if stopped { _ = publicationServer.applyWorldDelta(stop) }
                let before = publicationServer.committedSnapshot
                let result = publicationServer.applyWorldDelta(delta, requiredObservationEpoch: scope.requiredEpoch)
                check(name + ": authority fences final publication", stopped
                    ? result.status == .refused && publicationServer.committedSnapshot.revision == before.revision
                        && publicationServer.worldState == before.world
                    : result.status == .accepted)
            }
        }
        for (index, row) in blockedWorlds.enumerated() {
            guard let world = row.at(path: "world")?.objectValue,
                  let name = row.at(path: "name")?.stringValue else {
                throw NSError(domain: "startup_fixture_invalid", code: 2)
            }
            let path = "/tmp/leyline-tests-\(getpid())/leylined-startup-\(getpid())-\(index).sock"
            let server = CoreServer(socketPath: path)
            let record = StartupTestRecord()
            let presentation = ManualPresenter()
            let mailbox = CorePresentationMailbox(execute: { presentation.enqueue($0) },
                present: { presentation.present($0) })
            server.configureCommands(actionIDs: [actionID], handler: { record.command($0) })
            server.setCommittedSnapshotHandler { mailbox.submit($0) }
            _ = server.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
            guard server.start(requireWorldSeed: false) else {
                check("\(name): pending socket binds", false); continue
            }
            defer { server.stop() }
            let bootstrap = CoreStartupBootstrap(server: server)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let worker = DispatchQueue(label: "startup.fixture.\(name)")
            bootstrap.schedule(execute: { worker.async(execute: $0) }, capture: {
                record.captured(); entered.signal()
                release.wait()
                record.record(server.applyWorldDelta(world,
                    requiredObservationEpoch: bootstrap.requiredObservationEpoch))
                finished.signal()
            }, discard: { record.discard() })
            let workerEntered = entered.wait(timeout: .now() + 2) == .success
            check("\(name): queued capture begins without holding caller", workerEntered)

            let hello = ServeClient.request(socketPath: path, body: ["op": .string("hello")], timeoutSeconds: 1)
            let status = ServeClient.request(socketPath: path, body: ["op": .string("status")], timeoutSeconds: 1)
            let health = ServeClient.request(socketPath: path, body: ["op": .string("health")], timeoutSeconds: 1)
            let snapshot = ServeClient.request(socketPath: path, body: ["op": .string("snapshot")], timeoutSeconds: 1)
            let refused = ServeClient.request(socketPath: path, body: command, timeoutSeconds: 1)
            check("\(name): hello remains alive with typed pending readiness",
                hello?.at(path: "ok") == .bool(true) && hello?.at(path: "ready") == .bool(false))
            check("\(name): status remains unknown rather than empty while capture blocks",
                status?.at(path: "ok") == .bool(true)
                    && status?.at(path: "world.event") == .string("bootstrap_pending")
                    && status?.at(path: "world.focus") == .null
                    && status?.at(path: "world.windows") == .null
                    && status?.at(path: "world.windows_onscreen") == .null
                    && status?.at(path: "world.observation.world_complete") == .bool(false))
            check("\(name): health never manufactures a seed or rendered revision",
                health?.at(path: "health.world_seed.ready") == .bool(false)
                    && health?.at(path: "health.world_seed.revision") == .null
                    && health?.at(path: "health.projection.last_rendered_revision") == .null)
            check("\(name): pending snapshot refuses a ready-world claim",
                snapshot?.at(path: "ok") == .bool(false)
                    && snapshot?.at(path: "error") == .string("world_seed_pending")
                    && snapshot?.at(path: "world") == .null)
            check("\(name): no action enters the handler before an actual seed",
                refused?.at(path: "error") == .string("world_seed_pending") && record.counts.commands == 0)

            var subscribed: Int32?
            if let descriptor = FramedJSONSocket.connect(path: path, timeoutSeconds: 1) {
                subscribed = descriptor
                _ = FramedJSONSocket.writeAll(descriptor, FramedJSONSocket.encode(.object([
                    "op": .string("subscribe"), "from_revision": .int(0),
                ])))
                let pending = startupReadFrame(descriptor)
                check("\(name): subscriber baseline is explicitly pending",
                    pending?.at(path: "type") == .string("revision")
                        && pending?.at(path: "delta.event") == .string("bootstrap_pending")
                        && pending?.at(path: "delta.observation.world_complete") == .bool(false))
            } else { check("\(name): subscriber connects during blocked capture", false) }
            release.signal()
            let captureFinished = finished.wait(timeout: .now() + 2) == .success
            check("\(name): real seed is admitted only after fake AX returns",
                captureFinished && server.worldSeedReady && record.lastResult?.status == .accepted)
            if let descriptor = subscribed {
                let seeded = startupReadFrame(descriptor)
                check("\(name): seed follows pending baseline in commit order",
                    seeded?.at(path: "delta.event") == .string("world_seed")
                        && seeded?.at(path: "revision")?.intValue == 2)
                _ = shutdown(descriptor, SHUT_RDWR); close(descriptor)
            }
            _ = server.applyWorldDelta(fresh)
            let actual = ServeClient.request(socketPath: path, body: ["op": .string("snapshot")], timeoutSeconds: 1)
            let acted = ServeClient.request(socketPath: path, body: command, timeoutSeconds: 1)
            check("\(name): blocked rendering leaves read and command authority independent",
                actual?.at(path: "ok") == .bool(true)
                    && actual?.at(path: "world.windows_onscreen") == world["windows_onscreen"]
                    && acted?.at(path: "ok") == .bool(true) && record.counts.commands == 1
                    && presentation.presented.isEmpty && presentation.pending == 1)
            let committed = server.committedSnapshot
            presentation.drain()
            check("\(name): presentation resumes with the latest immutable snapshot",
                presentation.presented == [committed] && mailbox.health["visible_frame_evidence"] == .null)
        }

        let emptyServer = CoreServer(socketPath: selfTestSocketPath("leylined-startup-empty-unused"))
        _ = emptyServer.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
        let pending = emptyServer.committedSnapshot
        _ = emptyServer.applyWorldDelta(empty)
        let measuredEmpty = emptyServer.committedSnapshot
        let incompleteServer = CoreServer(socketPath: selfTestSocketPath("leylined-startup-incomplete-unused"))
        _ = incompleteServer.applyWorldDelta(incomplete)
        check("pending inventory and measured empty inventory have distinct completeness",
            pending.world.at(path: "windows") == .null && pending.world.at(path: "windows_onscreen") == .null
                && pending.world.at(path: "observation.world_complete") == .bool(false)
                && measuredEmpty.world.at(path: "windows") == .array([])
                && measuredEmpty.world.at(path: "windows_onscreen") == .int(0)
                && measuredEmpty.world.at(path: "observation.world_complete") == .bool(true))
        check("actual incomplete seed retains its failure instead of becoming an empty complete world",
            incompleteServer.worldSeedReady
                && incompleteServer.worldState.at(path: "observation.world_complete") == .bool(false)
                && incompleteServer.worldState.at(path: "observation.world_failure_code") == incomplete["observation"]?.at(path: "world_failure_code"))
        let faultServer = CoreServer(socketPath: selfTestSocketPath("leylined-startup-journal-unused"), initialState: journalFailure)
        _ = faultServer.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
        check("pending startup preserves journal fault recovery facts",
            faultServer.worldState.at(path: "persistence_available") == .bool(false)
                && faultServer.worldState.at(path: "resident_status") == journalFailure.at(path: "resident_status")
                && faultServer.worldState.at(path: "resident_unavailable_reason") == journalFailure.at(path: "resident_unavailable_reason"))

        for (index, lifecycle) in [stop, restart].enumerated() {
            let server = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/leylined-startup-retired-unused-\(getpid())-\(index).sock")
            _ = server.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
            let bootstrap = CoreStartupBootstrap(server: server)
            let record = StartupTestRecord()
            let queued = ManualPresenter()
            bootstrap.schedule(execute: { queued.enqueue($0) }, capture: {
                record.captured()
                record.record(server.applyWorldDelta(empty, requiredObservationEpoch: bootstrap.requiredObservationEpoch))
            }, discard: { record.discard() })
            _ = server.applyWorldDelta(lifecycle)
            _ = server.applyWorldDelta(resume)
            queued.drain()
            check("\(lifecycle["event"]?.stringValue ?? "lifecycle"): queued startup cannot revive a retired epoch",
                record.counts.captures == 0 && !server.worldSeedReady)

            let blocked = CoreStartupBootstrap(server: server)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let completed = DispatchSemaphore(value: 0)
            let worker = DispatchQueue(label: "startup.fixture.retired.\(index)")
            blocked.schedule(execute: { worker.async(execute: $0) }, capture: {
                record.captured(); entered.signal(); release.wait()
                record.record(server.applyWorldDelta(empty, requiredObservationEpoch: blocked.requiredObservationEpoch))
            }, discard: { record.discard() })
            let captured = entered.wait(timeout: .now() + 2) == .success
            _ = server.applyWorldDelta(lifecycle)
            _ = server.applyWorldDelta(resume)
            release.signal()
            worker.async { completed.signal() }
            let done = completed.wait(timeout: .now() + 2) == .success
            check("\(lifecycle["event"]?.stringValue ?? "lifecycle"): returning stale seed is refused even after management resumes",
                captured && done && record.lastResult?.status == .refused
                    && record.lastResult?.reason == "observation_epoch_retired" && !server.worldSeedReady
                    && record.counts.discarded == 1 && blocked.requiredObservationEpoch == nil)
        }
    } catch { check("fixture: \(error)", false) }
    return test.finish("startup")
}
