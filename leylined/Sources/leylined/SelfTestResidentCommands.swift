import ApplicationServices
import Foundation
import LeylineModel

private struct ResidentCommandsUnusedReader: TargetedProjectionWindowReading {
    func focusedElement(pid: pid_t) -> Result<AXUIElement?, ProjectionObservationFailure> { .failure(.init(code: "fixture_live_read_forbidden")) }
    func read(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?) -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        .failure(.init(code: "fixture_live_read_forbidden"))
    }
}

private struct ResidentCommandsUnusedSpaces: ProjectionSpaceObserving {
    func rebaseline() -> Result<Void, ProjectionObservationFailure> { .failure(.init(code: "fixture_live_space_read_forbidden")) }
    func context(windowId: Int64) -> Result<ProjectionSpaceContext, ProjectionObservationFailure> { .failure(.init(code: "fixture_live_space_read_forbidden")) }
}

/// Controllable external AX boundary. Every landing re-enters the actual CoreServer notification
/// path; no fake planner, scheduler, journal or successful setter-as-visible approximation exists.
private final class ResidentCommandsPort: ResidentMinimumEvidencePort, @unchecked Sendable {
    private let condition = NSCondition()
    private let publisher = DispatchQueue(label: "leylined.test.resident.commands.external_observation")
    weak var server: CoreServer?
    var health: (@Sendable () -> JSONValue)?
    var mayIssue: (@Sendable (ResidentEffectRequest) -> Bool)?
    var observationGeneration: (@Sendable (ResidentEffectRequest) -> UInt64?)?
    var onMinimumEvidence: (@Sendable (ResidentMinimumEvidence) -> Void)?
    var emitMinimumEvidence = false
    var confirmMinimumClamps = false
    var onDeadline: (@Sendable (UInt64) -> Void)?
    var evidenceTimeoutNanos: UInt64?
    var landingOverrides: [String: Frame] = [:]
    var minimumWidthOverrides: [String: Double] = [:]
    var minimumHeightOverrides: [String: Double] = [:]
    var focusGenerationBump: UInt64 = 0
    private var held = false
    private var requests: [ResidentEffectRequest] = []
    private var callbacks: [String: @Sendable (String?) -> Void] = [:]
    private var acknowledged: Set<String> = []
    private var cancelled: Set<String> = []
    private var writes = 0
    private var evidenceTimers: [String: DispatchSourceTimer] = [:]
    private var firedDeadlines: Set<String> = []

    func hold(_ value: Bool) { condition.lock(); held = value; condition.unlock() }
    func issue(request: ResidentEffectRequest, frame: Frame, completion: @escaping @Sendable (String?) -> Void) {
        condition.lock()
        requests.append(request); callbacks[request.requestID] = completion
        var timer: DispatchSourceTimer?
        if let timeout = evidenceTimeoutNanos {
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "leylined.test.resident.commands.deadline"))
            source.schedule(deadline: .now() + .nanoseconds(Int(clamping: timeout)))
            source.setEventHandler { [weak self] in self?.fireDeadline(request.requestID) }
            evidenceTimers[request.requestID] = source; timer = source
        }
        let shouldPublish = !held
        condition.broadcast(); condition.unlock()
        timer?.resume()
        if shouldPublish { release(request.requestID) }
    }
    func cancel(requestID: String) {
        condition.lock(); cancelled.insert(requestID); let timer = evidenceTimers.removeValue(forKey: requestID)
        condition.broadcast(); condition.unlock(); timer?.cancel()
    }
    private func fireDeadline(_ id: String) {
        condition.lock(); let timer = evidenceTimers.removeValue(forKey: id)
        let active = !cancelled.contains(id)
        if active { firedDeadlines.insert(id) }
        let callback = onDeadline
        condition.unlock(); timer?.cancel()
        if active { callback?(DispatchTime.now().uptimeNanoseconds) }
    }
    func deadlineIsArmed(_ id: String) -> Bool {
        condition.lock(); defer { condition.unlock() }; return evidenceTimers[id] != nil && !cancelled.contains(id)
    }
    var firedDeadlineIDs: Set<String> { condition.lock(); defer { condition.unlock() }; return firedDeadlines }
    deinit { for timer in evidenceTimers.values { timer.cancel() } }
    func acknowledgeOnly(_ id: String) {
        condition.lock(); let callback = callbacks.removeValue(forKey: id)
        if callback != nil { acknowledged.insert(id) }
        condition.unlock(); callback?(nil)
    }
    /// A size-minimum app honors each issued position and can grow above its
    /// floor. Full-frame overrides remain separate hostile-drift fixtures.
    private func landedFrame(windowID: String, target: Frame) -> Frame {
        if let override = landingOverrides[windowID] { return override }
        var observed = target
        if let width = minimumWidthOverrides[windowID] { observed.w = max(target.w, width) }
        if let height = minimumHeightOverrides[windowID] { observed.h = max(target.h, height) }
        return observed
    }
    func release(_ id: String) {
        condition.lock()
        let request = requests.first { $0.requestID == id }, callback = callbacks.removeValue(forKey: id)
        let wasAcknowledged = acknowledged.remove(id) != nil
        let obsolete = cancelled.contains(id)
        condition.unlock()
        guard let request, callback != nil || wasAcknowledged else { return }
        publisher.async { [self] in
            if obsolete { callback?("effect_cancelled"); return }
            if mayIssue?(request) == false { callback?("effect_cancelled"); return }
            guard let server else { callback?("fixture_server_missing"); return }
            // Deliberately acknowledge first: a matching notification can complete on the server
            // publication path, exposing recursive-transition deadlocks in the real wiring.
            callback?(nil)
            if request.effectKind == .focus {
                guard let focus = (server.worldState.at(path: "windows")?.arrayValue ?? []).first(where: {
                    $0.at(path: "window_id")?.intValue.map(String.init) == request.windowID
                }) else { return }
                publish(server, request: request, event: "ax_focus_changed", windowID: request.windowID,
                    delta: ["focus": focus])
            } else {
                let targets = request.frameTargets.isEmpty ? [request.windowID: request.frame] : request.frameTargets
                for id in targets.keys.sorted() {
                    condition.lock(); let isObsolete = cancelled.contains(request.requestID); condition.unlock()
                    if isObsolete || mayIssue?(request) == false { return }
                    var minimumProof: ResidentMinimumEvidence?
                    if emitMinimumEvidence, let target = targets[id], let epoch = request.observerEpoch,
                       let pid = request.windowPids[id], let lifetime = request.windowGenerations[id],
                       let space = request.windowSpaceKeys[id], let display = request.windowDisplayIDs[id],
                       let before = (server.worldState.at(path: "windows")?.arrayValue ?? []).first(where: {
                           $0.at(path: "window_id")?.intValue.map(String.init) == id
                       }).flatMap({ Frame.from($0.at(path: "frame")) }) {
                        var axes: Set<ResidentMinimumAxis> = []
                        if abs(before.w-target.w) > 0.5 { axes.insert(.width) }
                        if abs(before.h-target.h) > 0.5 { axes.insert(.height) }
                        let write = DispatchTime.now().uptimeNanoseconds
                        let proof = ResidentMinimumEvidence(write: .init(requestID: request.requestID,
                            windowID: id, ownerPID: pid, windowGeneration: lifetime, observerEpoch: epoch,
                            observerGeneration: request.observerGeneration, spaceKey: space, displayID: display,
                            topologyRevision: request.topologyRevision, before: before, requested: target,
                            axes: axes, completedNanos: write), observed: landedFrame(windowID: id, target: target),
                            observedGeneration: request.observerGeneration, readCompletedNanos: DispatchTime.now().uptimeNanoseconds)
                        minimumProof = proof
                        onMinimumEvidence?(proof)
                    }
                    let windows = (server.worldState.at(path: "windows")?.arrayValue ?? []).map { value -> JSONValue in
                        var object = value.objectValue ?? [:]
                        if value.at(path: "window_id")?.intValue.map(String.init) == id { object["frame"] = landedFrame(windowID: id, target: targets[id]!).json }
                        return .object(object)
                    }
                    var delta: JSONObject = ["windows": .array(windows)]
                    if server.worldState.at(path: "focus.window_id")?.intValue.map(String.init) == id {
                        delta["focus"] = windows.first { $0.at(path: "window_id")?.intValue.map(String.init) == id }
                    }
                    condition.lock(); writes += 1; condition.unlock()
                    publish(server, request: request, event: "ax_window_resized", windowID: id, delta: delta)
                    if confirmMinimumClamps, let proof = minimumProof,
                       !Geometry.frameEq(proof.observed, proof.write.requested, tol: 0.5) {
                        onMinimumEvidence?(ResidentMinimumEvidence(write: proof.write, observed: proof.observed,
                            observedGeneration: proof.observedGeneration, readCompletedNanos: proof.readCompletedNanos,
                            confirmationFrame: proof.observed, confirmationGeneration: proof.observedGeneration,
                            confirmationCompletedNanos: DispatchTime.now().uptimeNanoseconds))
                    }
                }
                if request.requiresFocus, mayIssue?(request) != false,
                   let focus = server.worldState.at(path: "windows")?.arrayValue?.first(where: {
                       $0.at(path: "window_id")?.intValue.map(String.init) == request.windowID
                   }) {
                    publish(server, request: request, event: "ax_focus_changed", windowID: request.windowID,
                        delta: ["focus": focus])
                }
            }
        }
    }
    private func publish(_ server: CoreServer, request: ResidentEffectRequest, event: String,
                         windowID: String, delta: JSONObject) {
        let previousReads = health?().at(path: "evidence_reads")?.intValue ?? 0
        var body = delta
        body["event"] = .string(event)
        let generation = request.effectKind == .frame ? observationGeneration?(request)
            : request.observerGeneration + (event == "ax_focus_changed" ? focusGenerationBump : 0)
        guard let generation else { return }
        body["observer_generation"] = .int(Int64(generation))
        body["notification_window_id"] = Int64(windowID).map(JSONValue.int)
        let stamp = DispatchTime.now().uptimeNanoseconds
        if event == "ax_focus_changed", var focus = body["focus"]?.objectValue {
            focus["observed_uptime_ns"] = .int(Int64(stamp)); body["focus"] = .object(focus)
            body["frontmost_pid"] = focus["pid"]
        }
        body["notification_receipt_uptime_ns"] = .int(Int64(stamp))
        body["observation_window_id"] = Int64(windowID).map(JSONValue.int)
        body["observation_window_generation"] = .int(Int64(request.windowGenerations[windowID] ?? 1))
        body["observation_completed_uptime_ns"] = .int(Int64(stamp))
        body["observation"] = .object(["ready": .bool(true), "world_complete": .bool(true),
            "failure_code": .null, "read_started_uptime_ns": .int(Int64(stamp)),
            "read_completed_uptime_ns": .int(Int64(stamp)), "reason": .string(event),
            "target_read_performed": .bool(true), "target_window_id": Int64(windowID).map(JSONValue.int) ?? .null,
            "target_kind": .string(event)])
        _ = server.applyWorldDelta(body)
        // Fixture delivery waits for admission, not a production settle timer. Each independent
        // per-window observation remains available even with a latest presentation mailbox.
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if (health?().at(path: "evidence_reads")?.intValue ?? 0) > previousReads { return }
            usleep(500)
        }
    }
    func waitForIssues(_ count: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 3)
        while requests.count < count { if !condition.wait(until: deadline) { return false } }
        return true
    }
    var issued: [ResidentEffectRequest] { condition.lock(); defer { condition.unlock() }; return requests }
    var writeCount: Int { condition.lock(); defer { condition.unlock() }; return writes }
    var cancelledIDs: Set<String> { condition.lock(); defer { condition.unlock() }; return cancelled }
    func drainPublications() { publisher.sync {} }
}

private final class ResidentCommandsPublicationBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var results: [JSONValue] = []
    private var snapshotReceipts: [UInt64: UInt64] = [:]
    private var heldID: String?
    private var heldPublicationEntered = false
    private var heldPublicationPermit: DispatchSemaphore?
    func holdResult(_ id: String) {
        condition.lock()
        heldID = id; heldPublicationEntered = false; heldPublicationPermit = DispatchSemaphore(value: 0)
        condition.unlock()
    }
    func record(_ snapshot: CoreCommittedSnapshot) {
        condition.lock()
        snapshotReceipts[snapshot.revision] = snapshot.receiptUptimeNs
        if snapshotReceipts.count > 64, let oldest = snapshotReceipts.keys.min() { snapshotReceipts.removeValue(forKey: oldest) }
        condition.unlock()
        guard snapshot.world.at(path: "event")?.stringValue == "action_result",
              let result = snapshot.world.at(path: "last_result"),
              let id = result.at(path: "request_id")?.stringValue else { return }
        condition.lock()
        let permit = heldID == id ? heldPublicationPermit : nil
        if permit != nil { heldPublicationEntered = true; condition.broadcast() }
        condition.unlock()
        if let permit { _ = permit.wait(timeout: .now() + .seconds(3)) }
        condition.lock(); results.append(result); condition.broadcast(); condition.unlock()
    }
    func waitForHeldResult(_ id: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while heldID != id || !heldPublicationEntered {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
    func releaseHeldResult(_ id: String) {
        condition.lock()
        let permit = heldID == id ? heldPublicationPermit : nil
        if heldID == id { heldID = nil; heldPublicationPermit = nil }
        condition.unlock(); permit?.signal()
    }
    func waitForResult(_ id: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 3)
        while !results.contains(where: { $0.at(path: "request_id")?.stringValue == id }) {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
    func results(for id: String) -> [JSONValue] {
        condition.lock(); defer { condition.unlock() }
        return results.filter { $0.at(path: "request_id")?.stringValue == id }
    }
    func receipt(for revision: UInt64) -> UInt64? {
        condition.lock(); defer { condition.unlock() }; return snapshotReceipts[revision]
    }
    func waitForInternalReconcile(after receipt: UInt64) -> JSONValue? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 3)
        while true {
            if let result = results.last(where: {
                $0.at(path: "origin")?.stringValue == "internal_reconcile"
                    && $0.at(path: "action_id")?.stringValue == "world.reconcile"
                    && ($0.at(path: "source_receipt_uptime_ns")?.intValue ?? 0) > Int64(clamping: receipt)
            }) { return result }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}

private final class ResidentCommandsRig: @unchecked Sendable {
    let directory: URL
    let server: CoreServer
    let controller: ResidentActionController
    let port = ResidentCommandsPort()
    let publications = ResidentCommandsPublicationBox()
    let journal: ResidentEffectorFileJournal
    let initialWorld: JSONValue
    let socketPath: String
    private(set) var bootstrapResult: JSONValue?

    init(fixture: JSONValue, complete: Bool = true, failJournal: Bool = false,
         initialRevision: UInt64 = 0, checkpoint: JSONValue? = nil, normalizeBootstrap: Bool = true, outerGap: Int? = 0,
         stateOnlyAppend: @escaping @Sendable (JSONValue, ResidentEffectorFileJournal) throws -> Void = { try $1.append($0) }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ley-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketPath = "/tmp/leyline-tests-\(getpid())/lcmd-\(UUID().uuidString.prefix(12)).sock"
        journal = ResidentEffectorFileJournal(path: directory.appendingPathComponent(failJournal ? "missing/journal.jsonl" : "journal.jsonl").path)
        var raw = fixture.at(path: "world")!.objectValue!
        let displays = (raw["topology"]?.arrayValue ?? []).map { value -> JSONValue in
            var object = value.objectValue ?? [:]; object["usable"] = object["usable_frame"]; return .object(object)
        }
        let topology: JSONValue = .object(["displays": .array(displays), "gap": fixture.at(path: "gap")!, "outer_gap": fixture.at(path: "outer_gap")!])
        let arrangement = Arrangement.bridgeArrangementNative(store: fixture.at(path: "store")!, topo: topology)
        raw["model_state"] = checkpoint ?? .object(["arrangement": arrangement])
        raw["observation"] = .object(["ready": .bool(complete), "world_complete": .bool(complete),
            "failure_code": .null, "world_failure_code": complete ? .null : .string("world_lifecycle_observer_unavailable")])
        initialWorld = .object(raw)
        server = CoreServer(socketPath: socketPath, initialRevision: initialRevision, initialState: initialWorld)
        _ = server.applyWorldDelta(["event": .string("world_seed")])
        let snapshots = TargetedProjectionSnapshot(trusted: { true }, reader: ResidentCommandsUnusedReader(),
            spaces: ResidentCommandsUnusedSpaces())
        controller = ResidentActionController(server: server, snapshots: snapshots,
            observationQueue: DispatchQueue(label: "leylined.test.resident.commands.observation"),
            journal: journal, gap: Int(fixture.at(path: "gap")!.intValue!), outerGap: outerGap, effectPort: port, stateOnlyAppend: stateOnlyAppend)
        port.server = server
        port.health = { [weak controller] in controller?.health ?? .object([:]) }
        port.mayIssue = { [weak controller] request in controller?.mayIssueEffect(request) == true }
        port.observationGeneration = { [weak controller] request in controller?.observationGeneration(for: request) }
        port.onDeadline = { [weak controller] stamp in controller?.expireEvidence(at: stamp) }
        let publications = self.publications
        server.setCommittedSnapshotHandler { [weak controller] snapshot in
            publications.record(snapshot); controller?.receive(snapshot)
        }
        server.configureCommands(actionIDs: Array(ResidentActionController.actionIDs)) { [weak controller] request in
            controller?.handle(request) ?? .object(["ok": .bool(false)])
        }
        guard server.start(requireWorldSeed: true) else { throw ResidentInputError(code: "TEST.SOCKET_START_FAILED", message: socketPath) }
        controller.reconcile(requestID: "fixture-bootstrap")
        guard let bootstrap = result("fixture-bootstrap") else {
            throw ResidentInputError(code: "TEST.BOOTSTRAP_COMPLETION_MISSING", message: socketPath)
        }
        bootstrapResult = bootstrap
        if normalizeBootstrap && bootstrap.at(path: "status")?.stringValue == "accepted" {
            controller.reconcile(requestID: "fixture-bootstrap-normalize")
            guard let normalized = result("fixture-bootstrap-normalize"),
                  ["accepted", "noop"].contains(normalized.at(path: "status")?.stringValue ?? "") else {
                throw ResidentInputError(code: "TEST.BOOTSTRAP_NORMALIZATION_FAILED", message: socketPath)
            }
        }
    }
    deinit { server.setCommittedSnapshotHandler(nil); server.stop(); try? FileManager.default.removeItem(at: directory) }
    func act(_ action: String, id: String, arguments: JSONValue = .object([:])) -> JSONValue? {
        ServeClient.request(socketPath: socketPath, body: ["op": .string("act"), "action_id": .string(action),
            "request_id": .string(id), "args": arguments])
    }
    func result(_ id: String, timeout: Double = 3) -> JSONValue? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let value = ServeClient.request(socketPath: socketPath, body: ["op": .string("result"), "request_id": .string(id)]),
               value.at(path: "phase")?.stringValue == "completed" { return value }
            usleep(500)
        }
        return nil
    }
    func waitForPending(_ count: Int64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if controller.health.at(path: "pending_count")?.intValue == count { return true }
            usleep(500)
        }
        return false
    }
    func waitForProcessed(_ revision: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if controller.health.at(path: "generation_causes")?.arrayValue?.contains(where: {
                $0.at(path: "event_id")?.stringValue == "revision:\(revision)"
            }) == true { return true }
            usleep(500)
        }
        return false
    }
}

/// @canonical resident_command_integration_self_test -- actual registry/socket/controller/model/
/// journal/effector path, with external AX observations supplied hermetically. No live writes/tap.
func runResidentCommandsSelfTest() -> Int32 {
    var test = SelfTest()
    runBorderSpacingScenarios(test: &test)
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/resident_commands/two_spaces.json"
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data) else {
        print("not ok resident-commands/fixture-missing"); return 1
    }
    let scenarios = (fixture.at(path: "scenarios")?.arrayValue ?? []).compactMap(\.stringValue)
    test.check(scenarios.count == 27 && Set(scenarios).count == 27, "resident-commands/nonempty-frozen-twenty-seven-scenario-inventory")
    runResidentGutterScenarios(fixture: fixture, test: &test)
    runResidentBorderWidthScenarios(fixture: fixture, test: &test)
    runResidentSpacePreferenceToggleScenarios(fixture: fixture, test: &test)
    runResidentCrossGenerationGoalScenarios(test: &test)
    runResidentStateOnlyScenarios(fixture: fixture, test: &test)
    runResidentSpaceSwitchScenarios(fixture: fixture, test: &test)
    runResidentStateOnlyModeEntryScenarios(fixture: fixture, test: &test)
    runResidentScopedActivationScenarios(fixture: fixture, test: &test)
    runResidentCachedLandingScenarios(fixture: fixture, test: &test)
    runResidentReleasedInputScenarios(fixture: fixture, test: &test)
    runResidentModeReleasePublicationScenarios(fixture: fixture, test: &test)
    runResidentKeyboardMoveContinuationScenarios(fixture: fixture, test: &test)
    runResidentFrameContinuityScenarios(fixture: fixture, test: &test)
    runResidentLifecycleDeadlineScenarios(fixture: fixture, test: &test)
    runResidentOwnFocusHandoffScenarios(fixture: fixture, test: &test)
    runResidentInputProgressScenarios(fixture: fixture, test: &test)
    runResidentStateOnlyCancellationScenarios(fixture: fixture, test: &test)
    runResidentEffectPublicationCancellationScenario(fixture: fixture, test: &test)
    runResidentMinimumCheckpointScenario(fixture: fixture, test: &test)
    runResidentProductCompletionScenarios(fixture: fixture, test: &test)
    runResidentStartupReconciliationScenarios(fixture: fixture, test: &test)
    runReactiveLifecycleRefocusScenarios(fixture: fixture, test: &test)
    do {
        let navigation = try ResidentCommandsRig(fixture: fixture)
        test.check(navigation.bootstrapResult?.at(path: "status")?.stringValue == "accepted"
            && navigation.server.worldState.at(path: "model_state.space_partitions.schema")?.stringValue == "leyline/resident-space-partitions/v1"
            && navigation.port.issued.isEmpty,
            "resident-commands/bootstrap-durably-partitions-world-before-first-command-with-zero-AX")
        let hello = ServeClient.request(socketPath: navigation.socketPath, body: ["op": .string("hello")])
        test.check(hello?.at(path: "capabilities")?.arrayValue?.contains(.string("nav.focus.east")) == true,
            "resident-commands/actual-socket-advertises-native-action-registry")
        _ = navigation.act("nav.focus.east", id: "navigation")
        let navResult = navigation.result("navigation")
        if navResult?.at(path: "status")?.stringValue != "accepted" {
            print("diagnostic navigation result=\((navResult ?? .null).canonical()) issued=\(navigation.port.issued.count) health=\(navigation.controller.health.canonical())")
        }
        test.check(navResult?.at(path: "status")?.stringValue == "accepted"
            && navResult?.at(path: "focus_confirmed")?.boolValue == true
            && navigation.server.worldState.at(path: "focus.window_id")?.intValue == 2,
            "resident-commands/navigation-plans-issues-and-confirms-own-targeted-focus")
        let same = navigation.act("nav.focus.east", id: "navigation")
        let conflict = navigation.act("nav.focus.west", id: "navigation")
        test.check(same?.at(path: "phase")?.stringValue == "completed"
            && conflict?.at(path: "reason")?.stringValue == "request_id_conflict" && navigation.port.issued.count == 1,
            "resident-commands/request-id-replay-idempotent-conflicting-payload-refuses")
        let checkpoint = try navigation.journal.recoverCheckpoint()
        let restored = try ResidentCommandsRig(fixture: fixture, initialRevision: checkpoint.highWaterRevision,
            checkpoint: checkpoint.state)
        test.check(checkpoint.state != nil && restored.server.currentRevision > checkpoint.highWaterRevision
            && restored.port.issued.isEmpty,
            "resident-commands/recovery-restores-committed-model-highwater-without-replaying-mutations")
        let crossApplication = try ResidentCommandsRig(fixture: fixture)
        crossApplication.port.focusGenerationBump = 1
        _ = crossApplication.act("nav.focus.east", id: "cross-app-navigation")
        let crossResult = crossApplication.result("cross-app-navigation")
        test.check(crossResult?.at(path: "status")?.stringValue == "accepted"
            && crossResult?.at(path: "requested_observer_generation")?.intValue == 8
            && crossResult?.at(path: "observed_observer_generation")?.intValue == 9
            && crossApplication.server.worldState.at(path: "observer_generation")?.intValue == 9,
            "resident-commands/cross-app-focus-landing-keeps-requested-and-observed-generations-distinct")

        let resize = try ResidentCommandsRig(fixture: fixture)
        _ = resize.act("resize.start", id: "resize-start"); _ = resize.result("resize-start")
        resize.port.hold(true)
        _ = resize.act("resize.adjust.east", id: "resize-first")
        let firstIssued = resize.port.waitForIssues(1)
        _ = resize.act("resize.adjust.east", id: "resize-middle")
        _ = resize.act("resize.adjust.east", id: "resize-final")
        let pending = resize.waitForPending(1)
        resize.controller.dispatch(.init(actionId: "resize.adjust.east", phase: .keyUp, mode: "resize",
            generation: 8, receiptUptimeNs: DispatchTime.now().uptimeNanoseconds)) { _ in }
        test.check(firstIssued && pending && resize.port.issued.count == 1,
            "resident-commands/held-resize-one-flight-latest-pending-through-real-dispatch")
        resize.port.hold(false); resize.port.release("resize-first")
        let finalResult = resize.result("resize-final")
        if finalResult?.at(path: "status")?.stringValue != "accepted" {
            print("diagnostic resize result=\((finalResult ?? .null).canonical()) first=\(firstIssued) pending=\(pending) issued=\(resize.port.issued.count) health=\(resize.controller.health.canonical())")
        }
        let finalState = resize.server.worldState.at(path: "model_state.arrangement") ?? .null
        let finalFrames = Arrangement.arrangementTargets(bridge: finalState, topo: .object([
            "displays": .array((fixture.at(path: "world.topology")?.arrayValue ?? []).map { value in
                var object = value.objectValue!; object["usable"] = object["usable_frame"]; return .object(object)
            }), "gap": fixture.at(path: "gap")!, "outer_gap": fixture.at(path: "outer_gap")!]))
        test.check(finalResult?.at(path: "status")?.stringValue == "accepted"
            && finalFrames.at(path: "1.frame.w") == fixture.at(path: "expected.three_resize_source_width"),
            "resident-commands/held-resize-final-request-accumulates-all-three-forty-point-steps")
        test.check(resize.controller.health.at(path: "generation_causes")?.arrayValue?.contains(where: {
            $0.at(path: "cause")?.stringValue == "key-up"
        }) == true && resize.server.worldState.at(path: "windows")?.arrayValue?.first?.at(path: "frame.y")?.intValue == 30,
            "resident-commands/keyup-is-preserved-and-usable-display-reservation-survives")

        let preview = try ResidentCommandsRig(fixture: fixture)
        let initialArrangement = preview.server.worldState.at(path: "model_state.arrangement")
        for (action, id) in [("move.start", "move-start"), ("move.cursor.east", "cursor"), ("move.drop", "stage"), ("move.cancel", "cancel-stage")] {
            _ = preview.act(action, id: id); let result = preview.result(id)
            if result?.at(path: "status")?.stringValue != "accepted" { print("diagnostic \(action) result=\((result ?? .null).canonical())") }
        }
        let previewPreserved = preview.port.issued.isEmpty && preview.server.worldState.at(path: "model_state.arrangement") == initialArrangement
            && preview.server.worldState.at(path: "model_state.interaction.staged_edge") == .null
        if !previewPreserved {
            print("diagnostic preview issued=\(preview.port.issued.count) initial=\((initialArrangement ?? .null).canonical()) final=\((preview.server.worldState.at(path: "model_state.arrangement") ?? .null).canonical()) interaction=\((preview.server.worldState.at(path: "model_state.interaction") ?? .null).canonical())")
        }
        test.check(previewPreserved,
            "resident-commands/move-preview-and-cancel-preserve-layout-with-zero-effects")
        _ = preview.act("move.cancel", id: "cancel-mode"); _ = preview.result("cancel-mode")
        test.check(preview.server.worldState.at(path: "model_state.interaction") == nil,
            "resident-commands/second-cancel-exits-interaction")

        let isolation = try ResidentCommandsRig(fixture: fixture)
        _ = isolation.server.setSpaceEnabled("display-B/space-B", enabled: false)
        _ = isolation.act("nav.focus.east", id: "A-navigation")
        test.check(isolation.result("A-navigation")?.at(path: "status")?.stringValue == "accepted"
            && isolation.server.spaceIsEnabled("display-A/space-A") && !isolation.server.spaceIsEnabled("display-B/space-B")
            && isolation.port.issued.allSatisfy { !$0.frameTargets.keys.contains("3") },
            "resident-commands/Space-A-ON-Space-B-OFF-never-actuates-disabled-window")

        let invalidation = try ResidentCommandsRig(fixture: fixture)
        _ = invalidation.act("resize.start", id: "invalid-start"); _ = invalidation.result("invalid-start")
        invalidation.port.hold(true)
        _ = invalidation.act("resize.adjust.east", id: "obsolete-resize"); _ = invalidation.port.waitForIssues(1)
        invalidation.publications.holdResult("obsolete-resize")
        defer { invalidation.publications.releaseHeldResult("obsolete-resize") }
        _ = invalidation.server.setSpaceEnabled("display-A/space-A", enabled: false)
        let terminalPublicationHeld = invalidation.publications.waitForHeldResult("obsolete-resize")
        let cancelled = invalidation.result("obsolete-resize")
        let completedBeforePublication = cancelled?.at(path: "phase")?.stringValue == "completed"
            && invalidation.publications.results(for: "obsolete-resize").isEmpty
        invalidation.port.release("obsolete-resize")
        if cancelled?.at(path: "status")?.stringValue != "failed" {
            print("diagnostic invalidation result=\((cancelled ?? .null).canonical()) issued=\(invalidation.port.issued.count) writes=\(invalidation.port.writeCount)")
        }
        test.check(cancelled?.at(path: "status")?.stringValue == "failed" && invalidation.port.writeCount == 0
            && cancelled?.at(path: "effect_issued_nanos")?.intValue != nil
            && cancelled?.at(path: "desired_state_committed_revision")?.intValue != nil
            && cancelled?.at(path: "requested_frames")?.objectValue?.isEmpty == false
            && cancelled?.at(path: "landed_frames")?.objectValue?.isEmpty == true
            && cancelled?.at(path: "verified_nanos") == .null,
            "resident-commands/Space-OFF-issued-cancellation-fails-with-honest-committed-and-unlanded-evidence")
        invalidation.controller.invalidate(cause: "cancel")
        invalidation.controller.invalidate(cause: "cancel")
        invalidation.port.release("obsolete-resize"); invalidation.port.drainPublications()
        invalidation.publications.releaseHeldResult("obsolete-resize")
        let terminalPublicationObserved = invalidation.publications.waitForResult("obsolete-resize")
        let quiescent = DispatchSemaphore(value: 0)
        invalidation.controller.whenIOQuiescent { quiescent.signal() }
        let terminalProducersQuiescent = quiescent.wait(timeout: .now() + .seconds(2)) == .success
        let terminalPublications = invalidation.publications.results(for: "obsolete-resize")
        let cachedTerminal = invalidation.result("obsolete-resize")
        let exactlyOneTerminal = terminalPublicationHeld && completedBeforePublication
            && terminalPublicationObserved && terminalProducersQuiescent
            && terminalPublications.map { $0.canonical() } == [(cancelled ?? .null).canonical()]
            && cachedTerminal?.canonical() == cancelled?.canonical() && invalidation.port.writeCount == 0
        if !exactlyOneTerminal {
            print("diagnostic repeated-cancel held=\(terminalPublicationHeld) cached_before_publication=\(completedBeforePublication) published=\(terminalPublicationObserved) io_quiescent=\(terminalProducersQuiescent) terminal_results=\(JSONValue.array(terminalPublications).canonical()) initial=\((cancelled ?? .null).canonical()) cached=\((cachedTerminal ?? .null).canonical()) writes=\(invalidation.port.writeCount)")
        }
        test.check(exactlyOneTerminal,
            "resident-commands/repeated-cancel-and-late-setter-callback-publish-exactly-one-terminal-result")

        let brokenJournal = try ResidentCommandsRig(fixture: fixture, failJournal: true)
        _ = brokenJournal.act("nav.focus.east", id: "journal-fail")
        let failure = brokenJournal.result("journal-fail")
        if brokenJournal.bootstrapResult?.at(path: "reason")?.stringValue != "journal_append_failed" {
            print("diagnostic journal-failure result=\((failure ?? .null).canonical())")
        }
        test.check(brokenJournal.bootstrapResult?.at(path: "status")?.stringValue == "failed"
            && brokenJournal.bootstrapResult?.at(path: "reason")?.stringValue == "journal_append_failed"
            && failure?.at(path: "status")?.stringValue == "refused"
            && failure?.at(path: "reason")?.stringValue == "planning_or_persistence_unavailable"
            && brokenJournal.server.worldState.at(path: "persistence_available")?.boolValue == false && brokenJournal.port.issued.isEmpty,
            "resident-commands/bootstrap-journal-failure-fences-future-commands-with-zero-AX-effects")
        let incomplete = try ResidentCommandsRig(fixture: fixture, complete: false)
        _ = incomplete.act("nav.focus.east", id: "incomplete")
        test.check(incomplete.result("incomplete")?.at(path: "reason")?.stringValue == "world_incomplete" && incomplete.port.issued.isEmpty,
            "resident-commands/incomplete-observer-world-cannot-author-model-or-effects")
    } catch { test.check(false, "resident-commands/fixture-runtime: \(error)") }
    return test.finish("resident-commands")
}

private func runResidentScopedActivationScenarios(fixture: JSONValue, test: inout SelfTest) {
    guard let specimen = fixture.at(path: "activation_regression"),
          let spaceA = specimen.at(path: "origin_space_key")?.stringValue,
          let spaceB = specimen.at(path: "independent_space_key")?.stringValue,
          let expectedScope = specimen.at(path: "origin_window_space_keys")?.objectValue else {
        test.check(false, "resident-commands/activation-regression-fixture-missing"); return
    }
    do {
        let noChange = try ResidentCommandsRig(fixture: fixture)
        _ = noChange.act("resize.start", id: "same-value-start"); _ = noChange.result("same-value-start")
        noChange.port.hold(true)
        _ = noChange.act("resize.adjust.east", id: "same-value-resize")
        let issued = noChange.port.waitForIssues(1)
        let previous = noChange.server.committedSnapshot
        let request = noChange.port.issued.first
        let unchanged = noChange.server.setSpaceEnabled(spaceB, enabled: false)
        test.check(issued && request != nil && unchanged.status == .noop
            && unchanged.reason == "space_activation_unchanged" && unchanged.revision.value == previous.revision
            && noChange.server.currentRevision == previous.revision
            && noChange.server.worldState == previous.world && noChange.port.cancelledIDs.isEmpty
            && request.map(noChange.controller.mayIssueEffect) == true,
            "resident-commands/same-value-independent-Space-OFF-mints-no-revision-and-preserves-issued-work")
        noChange.port.hold(false); noChange.port.release("same-value-resize")
        let noChangeResult = noChange.result("same-value-resize")
        if noChangeResult?.at(path: "status")?.stringValue != "accepted" {
            print("diagnostic same-value result=\((noChangeResult ?? .null).canonical()) health=\(noChange.controller.health.canonical())")
        }
        test.check(noChangeResult?.at(path: "status")?.stringValue == "accepted" && noChange.port.writeCount == 2,
            "resident-commands/same-value-independent-Space-OFF-command-still-lands-both-original-targets")

        let independent = try ResidentCommandsRig(fixture: fixture)
        _ = independent.act("resize.start", id: "independent-start"); _ = independent.result("independent-start")
        independent.port.hold(true)
        _ = independent.act("resize.adjust.east", id: "independent-resize")
        let flightIssued = independent.port.waitForIssues(1)
        let original = independent.server.committedSnapshot
        guard let flight = independent.port.issued.first else {
            test.check(false, "resident-commands/independent-Space-toggle-requires-issued-origin-request"); return
        }
        test.check(flightIssued && !flight.frameTargets.isEmpty
            && flight.windowSpaceKeys == Dictionary(uniqueKeysWithValues: expectedScope.map { ($0.key, $0.value.stringValue!) })
            && Set(flight.windowGenerations.keys) == Set(expectedScope.keys)
            && !flight.windowGenerations.keys.contains(String(fixture.at(path: "expected.disabled_space_window_id")!.intValue!)),
            "resident-commands/issued-resize-captures-only-real-origin-Space-window-lifetimes")
        var meaningfulTogglesPreservedOrigin = true
        var toggleDiagnostics: [JSONValue] = []
        for enabled in [true, false] {
            let transition = independent.server.setSpaceEnabled(spaceB, enabled: enabled)
            let drained = independent.waitForProcessed(transition.revision.value)
            let world = independent.server.worldState
            toggleDiagnostics.append(.object(["enabled": .bool(enabled), "status": .string(transition.status.rawValue),
                "snapshot_processed": .bool(drained), "mode": world.at(path: "mode") ?? .null,
                "mode_context_space_key": world.at(path: "mode_context_space_key") ?? .null,
                "interaction_preserved": .bool(world.at(path: "model_state.interaction") == original.world.at(path: "model_state.interaction")),
                "may_issue_origin_request": .bool(independent.controller.mayIssueEffect(flight)),
                "cancelled_request_ids": .array(independent.port.cancelledIDs.sorted().map(JSONValue.string))]))
            meaningfulTogglesPreservedOrigin = meaningfulTogglesPreservedOrigin
                && transition.status == .accepted && transition.revision.value > original.revision && drained
                && independent.server.spaceIsEnabled(spaceB) == enabled
                && world.at(path: "mode")?.stringValue == "resize"
                && world.at(path: "mode_context_space_key")?.stringValue == spaceA
                && world.at(path: "model_state.interaction") == original.world.at(path: "model_state.interaction")
                && independent.controller.mayIssueEffect(flight) && independent.port.cancelledIDs.isEmpty
                && independent.port.issued.first?.fingerprint == flight.fingerprint
        }
        if !meaningfulTogglesPreservedOrigin {
            print("diagnostic independent-toggle observations=\(JSONValue.array(toggleDiagnostics).canonical())")
        }
        test.check(meaningfulTogglesPreservedOrigin,
            "resident-commands/meaningful-independent-Space-ON-OFF-preserves-origin-mode-interaction-and-request-scope")
        independent.port.hold(false); independent.port.release(flight.requestID)
        let result = independent.result(flight.requestID)
        if result?.at(path: "status")?.stringValue != "accepted" {
            print("diagnostic independent-toggle result=\((result ?? .null).canonical()) health=\(independent.controller.health.canonical())")
        }
        test.check(result?.at(path: "status")?.stringValue == "accepted"
            && result?.at(path: "landed_frames")?.objectValue?.count == flight.frameTargets.count,
            "resident-commands/independent-Space-toggle-origin-request-retains-honest-complete-landing")

        var sparseFixture = fixture.objectValue!, sparseWorld = fixture.at(path: "world")!.objectValue!
        sparseWorld["space_activation"] = .object([spaceA: .bool(false)])
        sparseFixture["world"] = .object(sparseWorld)
        let sparse = try ResidentCommandsRig(fixture: .object(sparseFixture))
        let disabled = sparse.server.worldState
        let initialOriginWindows = (disabled.at(path: "windows")?.arrayValue ?? []).filter { $0.at(path: "space_key")?.stringValue == spaceA }
        let removal = sparse.server.applyWorldDelta(["event": .string("settings_changed"), "space_activation": .object([:])])
        let removalDrained = sparse.waitForProcessed(removal.revision.value)
        let restored = sparse.server.worldState
        let originWindows = (restored.at(path: "windows")?.arrayValue ?? []).filter { $0.at(path: "space_key")?.stringValue == spaceA }
        let originContexts = (restored.at(path: "space_contexts")?.arrayValue ?? []).filter { $0.at(path: "space_key")?.stringValue == spaceA }
        test.check(!initialOriginWindows.isEmpty && initialOriginWindows.allSatisfy { $0.at(path: "space_enabled")?.boolValue == false }
            && disabled.at(path: "focus.space_enabled")?.boolValue == false
            && removal.status == .accepted && removalDrained
            && restored.at(path: "space_activation")?.objectValue?.isEmpty == true && sparse.server.spaceIsEnabled(spaceA)
            && restored.at(path: "focus.space_enabled")?.boolValue == true
            && restored.at(path: "active_context.space_enabled")?.boolValue == true
            && originWindows.count == initialOriginWindows.count && originWindows.allSatisfy { $0.at(path: "space_enabled")?.boolValue == true }
            && !originContexts.isEmpty && originContexts.allSatisfy { $0.at(path: "space_enabled")?.boolValue == true }
            && restored.at(path: "invalidation_space_keys")?.arrayValue == [.string(spaceA)],
            "resident-commands/removing-sparse-false-override-restores-default-ON-to-focus-windows-and-contexts")
    } catch { test.check(false, "resident-commands/scoped-activation-fixture: \(error)") }
}

private func runResidentStateOnlyModeEntryScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        var unscopedFixture = fixture.objectValue!, store = fixture.at(path: "store")!.objectValue!
        store["segments"] = .array(store["segments"]!.arrayValue!.map { segment -> JSONValue in
            var row = segment.objectValue!; row.removeValue(forKey: "display_id"); return .object(row)
        })
        unscopedFixture["store"] = .object(store)
        let rig = try ResidentCommandsRig(fixture: .object(unscopedFixture), normalizeBootstrap: false)
        let unscoped = rig.server.worldState.at(path: "model_state.arrangement.segments")?.arrayValue
        _ = rig.act("resize.start", id: "unscoped-mode-start")
        let result = rig.result("unscoped-mode-start")
        let checkpoint = try rig.journal.recoverCheckpoint()
        let marker = checkpoint.records.last {
            $0.at(path: "type")?.stringValue == "model_state_commit"
                && $0.at(path: "request_id")?.stringValue == "unscoped-mode-start"
        }
        let world = rig.server.worldState
        let normalized = world.at(path: "model_state.arrangement.segments")?.arrayValue
        let expectedOrigin = fixture.at(path: "activation_regression.origin_space_key")
        let enteredConsistently = unscoped?.isEmpty == false && unscoped?.allSatisfy { $0.at(path: "display_id") == nil } == true
            && result?.at(path: "status")?.stringValue == "accepted" && marker != nil
            && normalized?.allSatisfy { $0.at(path: "display_id")?.intValue == 1 } == true
            && world.at(path: "mode")?.stringValue == "resize"
            && world.at(path: "mode_context_window_id") == fixture.at(path: "world.focus.window_id")
            && world.at(path: "mode_context_space_key") == expectedOrigin
            && world.at(path: "model_state.interaction.mode")?.stringValue == "resize"
            && marker?.at(path: "state")?.canonical() == world.at(path: "model_state")?.canonical()
            && rig.port.issued.isEmpty && rig.port.writeCount == 0
        if !enteredConsistently {
            print("diagnostic unscoped-mode-entry result=\((result ?? .null).canonical()) mode=\((world.at(path: "mode") ?? .null).canonical()) origin=\((world.at(path: "mode_context_space_key") ?? .null).canonical()) marker=\((marker ?? .null).canonical())")
        }
        test.check(enteredConsistently,
            "resident-commands/state-only-layout-normalization-commits-modal-state-and-origin-with-zero-AX")
    } catch { test.check(false, "resident-commands/state-only-mode-entry-fixture: \(error)") }
}

/// Stops only an actual durable state-only append; default production IO is
/// still performed, so the post-release abort is independently recoverable.
private final class ResidentCommandsStateOnlyJournalGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var heldID: String?
    private let actionID: String
    private var active: Bool
    init(actionID: String = "resize.start", active: Bool = true) { self.actionID = actionID; self.active = active }
    func arm() { lock.lock(); active = true; lock.unlock() }
    var requestID: String? { lock.lock(); defer { lock.unlock() }; return heldID }
    func append(_ record: JSONValue, journal: ResidentEffectorFileJournal) throws {
        try journal.append(record)
        lock.lock()
        let shouldHold = active && record.at(path: "type")?.stringValue == "model_state_intent"
            && record.at(path: "action_id")?.stringValue == actionID
        if shouldHold { heldID = record.at(path: "request_id")?.stringValue }
        lock.unlock()
        if shouldHold {
            entered.signal(); _ = permit.wait(timeout: .now() + .seconds(3))
        }
    }
}

private final class ResidentCommandsStartupResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JSONValue?
    let delivered = DispatchSemaphore(value: 0)
    func record(_ value: JSONValue) { lock.lock(); stored = value; lock.unlock(); delivered.signal() }
    var value: JSONValue? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func runResidentStartupReconciliationScenarios(fixture: JSONValue, test: inout SelfTest) {
    for hard in [false, true] {
        do {
            let gate = ResidentCommandsStateOnlyJournalGate(actionID: "world.reconcile", active: false)
            let rig = try ResidentCommandsRig(fixture: fixture, stateOnlyAppend: { try gate.append($0, journal: $1) })
            defer { gate.permit.signal() }
            _ = rig.server.applyWorldDelta(["event": .string("global_stop"), "management_enabled": .bool(false)])
            let beforeSeed = rig.server.worldState.at(path: "last_result")
            if hard {
                rig.controller.beginMaintenance()
                let reset = ResidentMaintenance(), resetResult = ResidentCommandsStartupResult()
                _ = reset.begin(requestID: "startup-real-reset", stopParticipants: (0..<5).map { _ in { $0() } },
                    reset: { permit in try rig.controller.resetJournal(permit: permit) }, onOutcome: { outcome in
                        switch outcome {
                        case .success(let value): rig.controller.finishMaintenance { resetResult.record(value) }
                        case .failure(let failure): resetResult.record(failure.json)
                        }
                    })
                test.check(resetResult.delivered.wait(timeout: .now() + .seconds(2)) == .success
                    && resetResult.value?.at(path: "journal_reset")?.boolValue == true
                    && resetResult.value?.at(path: "quarantined_journal")?.stringValue != nil
                    && rig.server.worldState.at(path: "model_state") == .object([:]),
                    "resident-commands/startup-real-maintenance-quarantine-establishes-empty-checkpoint-before-resume")
            }
            _ = rig.server.applyWorldDelta(["event": .string("world_seed"),
                "observation": .object(["ready": .bool(true), "world_complete": .bool(true)])])
            let drained = DispatchSemaphore(value: 0); rig.controller.whenIOQuiescent { drained.signal() }
            let quiescent = drained.wait(timeout: .now() + .seconds(2)) == .success
            test.check(quiescent && rig.server.worldState.at(path: "last_result") == beforeSeed
                && rig.controller.health.at(path: "controller_nonterminal_request_ids")?.arrayValue?.isEmpty == true,
                "resident-commands/\(hard ? "reset" : "soft")-OFF-world-seed-does-not-enqueue-doomed-reconciliation")
            _ = rig.server.applyWorldDelta(["event": .string("global_start"), "management_enabled": .bool(true),
                "resident_starting": .bool(true)])
            let baseline = rig.server.committedSnapshot
            let result = ResidentCommandsStartupResult(), id = hard ? "startup-hard-confirm" : "startup-soft-confirm"
            if hard { gate.arm() }
            rig.controller.reconcile(requestID: id) { result.record($0) }
            if hard {
                let held = gate.entered.wait(timeout: .now() + .seconds(2)) == .success
                let queued = rig.controller.handle(["op": .string("result"), "request_id": .string(id)])
                test.check(held && result.value == nil && queued.at(path: "phase")?.stringValue == "queued"
                    && !CoreRuntimeServices.inputCanClaim(rig.server.worldState, trusted: true),
                    "resident-commands/startup-held-real-journal-keeps-reconciliation-pending-and-keyboard-claims-OFF")
                gate.permit.signal()
            }
            let completed = result.delivered.wait(timeout: .now() + .seconds(3)) == .success
            let confirmed = result.value ?? .null
            let current = rig.server.worldState
            test.check(completed && CoreRuntimeServices.startupReconciliationMatches(confirmed, requestID: id,
                baselineRevision: baseline.revision, world: current)
                && confirmed.at(path: "origin")?.stringValue == "internal_reconcile"
                && current.at(path: "model_state.space_partitions.schema")?.stringValue == "leyline/resident-space-partitions/v1",
                "resident-commands/\(hard ? "hard-reset" : "soft-ON")-waits-for-real-terminal-reconciliation-and-current-partition-admission")
            var changed = current.objectValue!, windows = current.at(path: "windows")!.arrayValue!
            var reused = windows[0].objectValue!
            reused["window_generation"] = .int((reused["window_generation"]?.intValue ?? 0) + 1)
            windows[0] = .object(reused); changed["windows"] = .array(windows)
            test.check(!CoreRuntimeServices.startupReconciliationMatches(confirmed, requestID: "wrong-request",
                baselineRevision: baseline.revision, world: current)
                && !CoreRuntimeServices.startupReconciliationMatches(confirmed, requestID: id,
                    baselineRevision: baseline.revision, world: .object(changed)),
                "resident-commands/\(hard ? "reset" : "soft")-readiness-refuses-wrong-request-and-new-window-lifetime")
            _ = rig.server.applyWorldDelta(["event": .string("resident_start_completed"), "resident_starting": .bool(false)])
            _ = rig.act("resize.start", id: id + "-next-resize")
            test.check(rig.result(id + "-next-resize")?.at(path: "status")?.stringValue == "accepted"
                && CoreRuntimeServices.inputCanClaim(rig.server.worldState, trusted: true),
                "resident-commands/\(hard ? "reset" : "soft")-completed-start-admits-next-resize-without-manual-reconcile")
        } catch { test.check(false, "resident-commands/startup-reconciliation: \(error)") }
    }
}

private func residentUnscopedModeFixture(_ fixture: JSONValue) -> JSONValue {
    var value = fixture.objectValue!, store = fixture.at(path: "store")!.objectValue!
    store["segments"] = .array(store["segments"]!.arrayValue!.map { segment in
        var row = segment.objectValue!; row.removeValue(forKey: "display_id"); return .object(row)
    })
    value["store"] = .object(store); return .object(value)
}

private func runResidentStateOnlyCancellationScenarios(fixture: JSONValue, test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/resident_commands/state_only_cancellation.json"
    guard let bytes = FileManager.default.contents(atPath: path), let proof = try? JSONValue.parse(bytes),
          proof.at(path: "scenarios")?.arrayValue?.count == 5 else {
        test.check(false, "resident-commands/state-only-cancellation-fixture"); return
    }
    for retain in [false, true] {
        do {
            let rig = try ResidentCommandsRig(fixture: fixture)
            _ = rig.act("resize.start", id: "recovery-mode-entry"); let entry = rig.result("recovery-mode-entry")
            if !retain {
                _ = rig.server.applyModeFrame(ModeFrame(type: .snapshot, epoch: "cancel-recovery", sequence: 1, mode: "default"))
            }
            let before = rig.server.worldState
            let receipt = DispatchTime.now().uptimeNanoseconds
            let next = (before.at(path: "observer_generation")?.intValue ?? 0) + 1
            _ = rig.server.applyWorldDelta(["event": .string("app_activated"), "observer_generation": .int(next),
                "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "world_recovered": .bool(true)])])
            let recovered = rig.publications.waitForInternalReconcile(after: receipt)
            let after = rig.server.worldState
            let coherent = retain
                ? after.at(path: "mode")?.stringValue == "resize" && after.at(path: "model_state.interaction.observer_generation")?.intValue == next
                : after.at(path: "mode")?.stringValue == "default" && after.at(path: "model_state.interaction") == nil
            test.check(entry?.at(path: "origin") == proof.at(path: "socket_origin")
                && before.at(path: "model_state.interaction.mode")?.stringValue == "resize"
                && recovered?.at(path: "status")?.stringValue == "accepted" && coherent
                && before.at(path: "model_state.arrangement") == after.at(path: "model_state.arrangement")
                && rig.port.issued.isEmpty && rig.port.writeCount == 0,
                retain ? "resident-commands/live-same-mode-compatible-recovery-preserves-held-interaction"
                    : "resident-commands/default-mode-then-actual-recovery-cannot-resurrect-or-retag-old-interaction")
            test.check(recovered?.at(path: "action_id")?.stringValue == "world.reconcile"
                && recovered?.at(path: "origin") == proof.at(path: "reconcile_origin")
                && recovered?.at(path: "source_input_generation") == .null,
                "resident-commands/\(retain ? "held" : "default")-recovery-result-identifies-internal-producer")
        } catch { test.check(false, "resident-commands/mode-recovery-cancellation: \(error)") }
    }
    for inputRelease in [true, false] {
        do {
            let gate = ResidentCommandsStateOnlyJournalGate()
            let rig = try ResidentCommandsRig(fixture: residentUnscopedModeFixture(fixture), normalizeBootstrap: false,
                stateOnlyAppend: { try gate.append($0, journal: $1) })
            defer { gate.permit.signal() }
            let before = rig.server.worldState.at(path: "model_state")
            let modeDelayed = DispatchSemaphore(value: 0), modePermit = DispatchSemaphore(value: 0)
            let epoch = UUID().uuidString
            let input = try ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { action, complete in
                rig.controller.dispatch(action, completion: complete)
            }, onModeChanged: { mode, generation, _ in
                if mode == "default" { modeDelayed.signal(); _ = modePermit.wait(timeout: .now() + .seconds(3)) }
                _ = rig.server.applyModeFrame(ModeFrame(type: mode == "resize" ? .snapshot : .changed,
                    epoch: epoch, sequence: Int64(clamping: generation), mode: mode))
            return true })
            defer { modePermit.signal(); input.routing.flushForSelfTest() }
            rig.controller.setInputGenerationReader { [weak input] in input?.routing.generation }
            if inputRelease { _ = input.inject(chord: proof.at(path: "entry_chord")!.stringValue!) }
            else { _ = rig.act("resize.start", id: "journal-admission-fence") }
            let held = gate.entered.wait(timeout: .now() + .seconds(2)) == .success
            let id = gate.requestID ?? "missing-journal-intent"
            let sourceGeneration = input.routing.generation
            if inputRelease { input.routing.release(reason: "action_deadline") }
            else { rig.controller.invalidate(cause: "cancel") }
            let delayed = !inputRelease || modeDelayed.wait(timeout: .now() + .seconds(1)) == .success
            gate.permit.signal()
            let result = rig.result(id)
            let checkpoint = try rig.journal.recoverCheckpoint()
            let records = checkpoint.records.filter { $0.at(path: "request_id")?.stringValue == id }
            let reason = proof.at(path: inputRelease ? "released_reason" : "invalidated_reason")
            test.check(held && delayed && result?.at(path: "status")?.stringValue == "refused"
                && result?.at(path: "reason") == reason
                && rig.server.worldState.at(path: "model_state") == before
                && rig.server.worldState.at(path: "model_state.interaction") == nil
                && rig.port.issued.isEmpty && rig.port.writeCount == 0,
                "resident-commands/\(inputRelease ? "input-release" : "admission-loss")-during-real-journal-IO-refuses-before-state-publication")
            test.check(records.map { $0.at(path: "type")?.stringValue } == ["model_state_intent", "model_state_abort"]
                && records.last?.at(path: "reason") == reason && checkpoint.state?.canonical() == before?.canonical(),
                "resident-commands/\(inputRelease ? "released" : "invalidated")-state-only-intent-has-durable-abort-and-no-recovered-stale-state")
            test.check(result?.at(path: "action_id") == proof.at(path: "action_id")
                && result?.at(path: "origin") == proof.at(path: inputRelease ? "input_origin" : "socket_origin")
                && result?.at(path: "source_input_generation") == (inputRelease ? .int(Int64(sourceGeneration)) : .null)
                && records.allSatisfy { $0.at(path: "origin") == result?.at(path: "origin")
                    && $0.at(path: "source_input_generation") == result?.at(path: "source_input_generation") },
                "resident-commands/\(inputRelease ? "input" : "socket")-journal-and-terminal-preserve-original-command-source")
            modePermit.signal(); input.routing.flushForSelfTest()
        } catch { test.check(false, "resident-commands/held-state-journal-cancellation: \(error)") }
    }
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        let actions = ResidentCommandsInputActionBox()
        let input = try ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { action, complete in
            actions.record(action); complete(0)
        }, onModeChanged: { _, _, _ in return true })
        _ = input.inject(chord: proof.at(path: "entry_chord")!.stringValue!); input.routing.flushForSelfTest()
        guard let action = actions.last else { test.check(false, "resident-commands/direct-commit-routed-action"); return }
        let held = DispatchSemaphore(value: 0), releaseTransition = DispatchSemaphore(value: 0)
        let sourceChecked = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let sourceReads = ResidentAtomic<UInt64>(0), heldRevision = ResidentAtomic<UInt64>(0)
        let publications = rig.publications
        rig.server.setCommittedSnapshotHandler { [weak controller = rig.controller] snapshot in
            publications.record(snapshot); controller?.receive(snapshot)
            if snapshot.world.at(path: "event")?.stringValue == "fixture_transition_held" {
                heldRevision.store(snapshot.revision, ordering: .releasing); held.signal()
                _ = releaseTransition.wait(timeout: .now() + .seconds(3))
            }
        }
        defer { releaseTransition.signal() }
        DispatchQueue(label: "leylined.test.direct-state-transition").async {
            _ = rig.server.applyWorldDelta(["event": .string("fixture_transition_held")])
        }
        let transitionHeld = held.wait(timeout: .now() + .seconds(2)) == .success
        let before = rig.server.worldState.at(path: "model_state")
        let epochBefore = rig.server.observationEpoch
        rig.controller.setInputGenerationReader { [weak input] in
            let value = input?.routing.generation
            if sourceReads.wrappingAdd(1, ordering: .acquiringAndReleasing) == 0 { sourceChecked.signal() }
            return value
        }
        rig.controller.dispatch(action) { _ in completed.signal() }
        let id = rig.controller.health.at(path: "controller_nonterminal_request_ids")?.arrayValue?.first?.stringValue ?? "missing-direct-request"
        let admitted = rig.controller.handle(["op": .string("result"), "request_id": .string(id)])
        let initialChecked = sourceChecked.wait(timeout: .now() + .seconds(1)) == .success
        input.routing.release(reason: "action_deadline")
        releaseTransition.signal()
        let result = rig.result(id)
        test.check(transitionHeld && initialChecked && completed.wait(timeout: .now() + .seconds(1)) == .success
            && sourceReads.load(ordering: .acquiring) == 2
            && result?.at(path: "status")?.stringValue == "refused" && result?.at(path: "reason") == proof.at(path: "released_reason")
            && result?.at(path: "revision")?.intValue == Int64(heldRevision.load(ordering: .acquiring))
            && rig.server.observationEpoch == epochBefore
            && rig.server.worldState.at(path: "model_state") == before && rig.server.worldState.at(path: "mode")?.stringValue == "default"
            && rig.port.issued.isEmpty && rig.port.writeCount == 0,
            "resident-commands/release-while-real-authority-transition-held-refuses-inside-commit-guard-with-no-state-revision-or-effect")
        test.check(admitted.at(path: "origin") == proof.at(path: "input_origin")
            && admitted.at(path: "action_id") == proof.at(path: "action_id")
            && admitted.at(path: "source_input_generation")?.intValue == Int64(action.generation)
            && result?.at(path: "source_input_generation") == admitted.at(path: "source_input_generation")
            && result?.at(path: "source_receipt_uptime_ns")?.intValue == Int64(action.receiptUptimeNs),
            "resident-commands/direct-admission-and-terminal-identify-original-input-receipt-and-generation")
        let revisionBeforeRefusal = rig.server.currentRevision
        let stateBeforeRefusal = rig.server.worldState
        let guarded = rig.server.applyWorldDelta(["event": .string("global_stop"), "management_enabled": .bool(false)],
            expectedRevision: revisionBeforeRefusal, commitGuard: { "fixture_admission_refused" })
        let wrongRevision = rig.server.applyWorldDelta(["event": .string("global_restart")], expectedRevision: revisionBeforeRefusal + 1)
        test.check(guarded.status == .refused && wrongRevision.status == .refused
            && rig.server.currentRevision == revisionBeforeRefusal && rig.server.worldState == stateBeforeRefusal
            && rig.server.observationEpoch == epochBefore,
            "resident-commands/refused-control-shaped-world-deltas-change-neither-authority-revision-state-nor-observation-epoch")
        input.routing.flushForSelfTest()
    } catch { test.check(false, "resident-commands/direct-transition-cancellation: \(error)") }
}

private func runResidentEffectPublicationCancellationScenario(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        _ = rig.act("resize.start", id: "effect-guard-mode"); _ = rig.result("effect-guard-mode")
        let actions = ResidentCommandsInputActionBox()
        let input = try ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { action, complete in
            actions.record(action); complete(0)
        }, onModeChanged: { _, _, _ in return true })
        _ = input.inject(chord: "cmd + ctrl + alt + shift - r"); input.routing.flushForSelfTest()
        _ = input.inject(chord: "l"); input.routing.flushForSelfTest()
        guard let action = actions.last else { test.check(false, "resident-commands/effect-guard-input-fixture"); return }
        let held = DispatchSemaphore(value: 0), permitAuthority = DispatchSemaphore(value: 0)
        let prechecked = DispatchSemaphore(value: 0), permitPrecheck = DispatchSemaphore(value: 0)
        let sourceReads = ResidentAtomic<UInt64>(0), heldRevision = ResidentAtomic<UInt64>(0)
        rig.server.setCommittedSnapshotHandler { [weak controller = rig.controller] snapshot in
            controller?.receive(snapshot)
            if snapshot.world.at(path: "event")?.stringValue == "effect_authority_held" {
                heldRevision.store(snapshot.revision, ordering: .releasing); held.signal()
                _ = permitAuthority.wait(timeout: .now() + .seconds(3))
            }
        }
        defer { permitAuthority.signal(); permitPrecheck.signal() }
        DispatchQueue(label: "leylined.test.effect-authority-held").async {
            _ = rig.server.applyWorldDelta(["event": .string("effect_authority_held")])
        }
        let authorityHeld = held.wait(timeout: .now() + .seconds(2)) == .success
        let before = rig.server.worldState.at(path: "model_state"), epoch = rig.server.observationEpoch
        let issueCount = rig.port.issued.count, writeCount = rig.port.writeCount
        rig.controller.setInputGenerationReader { [weak input] in
            let captured = input?.routing.generation
            if sourceReads.wrappingAdd(1, ordering: .acquiringAndReleasing) == 1 {
                prechecked.signal(); _ = permitPrecheck.wait(timeout: .now() + .seconds(3))
            }
            return captured
        }
        rig.controller.dispatch(action) { _ in }
        let checked = prechecked.wait(timeout: .now() + .seconds(2)) == .success
        let id = rig.controller.health.at(path: "controller_nonterminal_request_ids")?.arrayValue?.first?.stringValue ?? "missing-effect-guard"
        input.routing.release(reason: "action_deadline")
        permitPrecheck.signal(); permitAuthority.signal()
        let result = rig.result(id)
        test.check(authorityHeld && checked && result?.at(path: "status")?.stringValue == "refused"
            && rig.server.worldState.at(path: "model_state") == before && rig.server.observationEpoch == epoch
            && rig.port.issued.count == issueCount && rig.port.writeCount == writeCount,
            "resident-commands/released-input-final-desired-plan-authority-guard-prevents-state-and-AX-publication")
        let records = try rig.journal.recoverCheckpoint().records.filter { $0.at(path: "request_id")?.stringValue == id }
        test.check(!records.contains { $0.at(path: "type")?.stringValue == "effect_commit" }
            && result?.at(path: "desired_state_committed_revision") == .null,
            "resident-commands/refused-desired-plan-cannot-promote-checkpoint-after-precheck-race")
    } catch { test.check(false, "resident-commands/effect-publication-guard-fixture: \(error)") }
}

private func runResidentMinimumCheckpointScenario(fixture: JSONValue, test: inout SelfTest) {
    do {
        var prepared = fixture.objectValue!, world = fixture.at(path: "world")!.objectValue!
        world["windows"] = .array(world["windows"]!.arrayValue!.map { value -> JSONValue in
            var object = value.objectValue!; object["app"] = .string("minimum-fixture-app"); return .object(object)
        })
        prepared["world"] = .object(world)
        let displays = world["topology"]!.arrayValue!.map { value -> JSONValue in
            var object = value.objectValue!; object["usable"] = object["usable_frame"]; return .object(object)
        }
        let topology: JSONValue = .object(["displays": .array(displays), "gap": fixture.at(path: "gap")!, "outer_gap": fixture.at(path: "outer_gap")!])
        let initialCheckpoint: JSONValue = .object([
            "arrangement": Arrangement.bridgeArrangementNative(store: fixture.at(path: "store")!, topo: topology),
            "minimum_sizes": .object(["minimum-fixture-app": .object(["w": .int(5000)])])])
        let rig = try ResidentCommandsRig(fixture: .object(prepared), checkpoint: initialCheckpoint)
        rig.port.emitMinimumEvidence = true
        _ = rig.act("resize.start", id: "minimum-mode"); _ = rig.result("minimum-mode")
        _ = rig.act("resize.adjust.east", id: "minimum-write"); let result = rig.result("minimum-write")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && rig.controller.health.at(path: "minimum_learning_status")?.stringValue != "known_floor_self_healed" { usleep(500) }
        let current = rig.server.worldState.at(path: "model_state")!
        let checkpoint = try rig.journal.recoverCheckpoint()
        let learned = result?.at(path: "status")?.stringValue == "accepted"
            && (current.at(path: "minimum_sizes")?.objectValue?["minimum-fixture-app"]?.at(path: "w")?.numberValue ?? 5000) < 5000
            && checkpoint.state?.at(path: "minimum_sizes") == current.at(path: "minimum_sizes")
            && checkpoint.records.contains { $0.at(path: "request_id")?.stringValue == "minimum:minimum-write"
                && $0.at(path: "type")?.stringValue == "model_state_commit" }
        if !learned {
            let diagnostic: JSONValue = .object(["result": result ?? .null,
                "health": rig.controller.health, "model": current, "checkpoint": checkpoint.state ?? .null,
                "applications": .array(rig.port.issued.map { .object(JSONObject(unordered: $0.windowApplicationKeys.mapValues(JSONValue.string))) }),
                "records": .array(checkpoint.records.filter { $0.at(path: "request_id")?.stringValue?.contains("minimum") == true })])
            print("diagnostic minimum \(diagnostic.canonical())")
        }
        test.check(learned,
            "resident-commands/proven-known-floor-self-heal-is-journaled-through-current-checkpoint")
        test.check(rig.server.worldState.at(path: "mode")?.stringValue == "resize"
            && current.at(path: "interaction.mode")?.stringValue == "resize"
            && rig.result("minimum-write") == result,
            "resident-commands/minimum-checkpoint-preserves-mode-and-original-effect-result")
    } catch { test.check(false, "resident-commands/minimum-checkpoint-fixture: \(error)") }
}

private func runResidentCachedLandingScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        _ = rig.act("resize.start", id: "cached-start"); _ = rig.result("cached-start")
        rig.port.hold(true)
        _ = rig.act("resize.adjust.east", id: "cached-resize")
        let issued = rig.port.waitForIssues(1)
        guard let request = rig.port.issued.first else {
            test.check(false, "resident-commands/cached-landing-requires-issued-request"); return
        }
        rig.port.acknowledgeOnly(request.requestID)
        let matchingWindows = (rig.server.worldState.at(path: "windows")?.arrayValue ?? []).map { window -> JSONValue in
            var row = window.objectValue!
            if let id = window.at(path: "window_id")?.intValue.map(String.init), let frame = request.frameTargets[id] { row["frame"] = frame.json }
            return .object(row)
        }
        let stamp = DispatchTime.now().uptimeNanoseconds
        let cache = rig.server.applyWorldDelta(["event": .string("settings_changed"), "windows": .array(matchingWindows),
            "focus": matchingWindows.first!, "observation_window_id": .int(Int64(request.windowID)!),
            "observation_completed_uptime_ns": .int(Int64(stamp))])
        let processed = rig.waitForProcessed(cache.revision.value)
        let pending = ServeClient.request(socketPath: rig.socketPath, body: ["op": .string("result"), "request_id": .string(request.requestID)])
        let allFramesCached = request.frameTargets.allSatisfy { id, target in
            matchingWindows.first { $0.at(path: "window_id")?.intValue.map(String.init) == id }.flatMap { Frame.from($0.at(path: "frame")) } == target
        }
        test.check(issued && cache.status == .accepted && processed && !request.frameTargets.isEmpty && allFramesCached
            && pending?.at(path: "phase")?.stringValue == "queued" && rig.port.writeCount == 0
            && rig.controller.health.at(path: "evidence_reads")?.intValue == 0
            && rig.publications.results(for: request.requestID).isEmpty,
            "resident-commands/setter-ack-and-matching-cached-settings-frames-cannot-complete-landing")
        rig.port.hold(false); rig.port.release(request.requestID)
        let result = rig.result(request.requestID)
        rig.port.release(request.requestID); rig.port.drainPublications()
        if result?.at(path: "status")?.stringValue != "accepted" {
            print("diagnostic cached-landing result=\((result ?? .null).canonical()) pending=\((pending ?? .null).canonical()) health=\(rig.controller.health.canonical())")
        }
        test.check(result?.at(path: "status")?.stringValue == "accepted"
            && result?.at(path: "verified_nanos")?.intValue != nil
            && result?.at(path: "first_matching_observation_nanos")?.intValue != nil
            && result?.at(path: "landed_frames")?.objectValue?.count == request.frameTargets.count
            && rig.port.writeCount == request.frameTargets.count
            && rig.publications.results(for: request.requestID) == [result ?? .null],
            "resident-commands/independent-AX-observations-complete-cached-goal-once-with-explicit-landing-evidence")
    } catch { test.check(false, "resident-commands/cached-landing-fixture: \(error)") }
}

private final class ResidentCommandsInputActionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: ResidentInputAction?
    func record(_ value: ResidentInputAction) { lock.lock(); action = value; lock.unlock() }
    var last: ResidentInputAction? { lock.lock(); defer { lock.unlock() }; return action }
}

private func runResidentReleasedInputScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        _ = rig.act("resize.start", id: "input-race-start"); _ = rig.result("input-race-start")
        let actions = ResidentCommandsInputActionBox()
        let delayedModeEntered = DispatchSemaphore(value: 0), deliverMode = DispatchSemaphore(value: 0)
        let delayedModeCompleted = DispatchSemaphore(value: 0)
        guard let input = try? ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { action, complete in
            if action.actionId == "resize.start" { complete(0); return }
            actions.record(action); rig.controller.dispatch(action, completion: complete)
        }, onModeChanged: { mode, generation, _ in
            guard mode == "default", generation > 0 else { return true }
            delayedModeEntered.signal()
            _ = deliverMode.wait(timeout: .now() + .seconds(3))
            _ = rig.server.applyWorldDelta(["event": .string("mode_changed"), "mode": .string(mode),
                "mode_context_window_id": .null, "mode_context_space_key": .null])
            delayedModeCompleted.signal()
        return true }) else { test.check(false, "resident-commands/released-input-shipped-routing-fixture"); return }
        defer { deliverMode.signal(); input.routing.flushForSelfTest() }
        rig.controller.setInputGenerationReader { [weak input] in input?.routing.generation }
        rig.port.mayIssue = { [weak controller = rig.controller] in controller?.mayIssueEffect($0) == true }
        let entered = input.inject(chord: fixture.at(path: "input_generation_regression.entry_chord")!.stringValue!)
        input.routing.flushForSelfTest()
        let liveGeneration = input.routing.generation
        rig.port.hold(true)
        let adjusted = input.inject(chord: fixture.at(path: "input_generation_regression.adjust_chord")!.stringValue!)
        input.routing.flushForSelfTest()
        let issued = rig.port.waitForIssues(1)
        guard let request = rig.port.issued.first, let oldAction = actions.last else {
            test.check(false, "resident-commands/released-input-requires-real-routed-and-issued-action"); return
        }
        let beforeReleaseAllowed = rig.controller.mayIssueEffect(request)
        input.routing.release(reason: "action_deadline")
        let notificationDelayed = delayedModeEntered.wait(timeout: .now() + .seconds(1)) == .success
        let releasedGeneration = input.routing.generation
        let refusedBeforeMode = !rig.controller.mayIssueEffect(request)
        _ = rig.controller.handle(["op": .string("act"), "action_id": .string(oldAction.actionId),
            "request_id": .string("input-race-delayed")], receipt: oldAction.receiptUptimeNs, inputGeneration: oldAction.generation)
        let refused = rig.result("input-race-delayed")
        let releaseFenced = entered == .claimed && adjusted == .claimed && issued && notificationDelayed
            && oldAction.generation == liveGeneration && request.sourceInputGeneration == oldAction.generation
            && releasedGeneration > liveGeneration && beforeReleaseAllowed && refusedBeforeMode
            && input.routing.mode == "default" && rig.server.worldState.at(path: "mode")?.stringValue == "resize"
            && refused?.at(path: "status")?.stringValue == "refused"
            && refused?.at(path: "reason")?.stringValue == "input_generation_released"
            && rig.port.issued.count == 1 && rig.port.writeCount == 0
        if !releaseFenced {
            print("diagnostic released-input fence=\(JSONValue.object(["entered": .string(entered.rawValue), "adjusted": .string(adjusted.rawValue), "issued": .bool(issued), "notification_delayed": .bool(notificationDelayed), "source_input_generation": request.sourceInputGeneration.map { .int(Int64($0)) } ?? .null, "live_before_release": .int(Int64(liveGeneration)), "live_after_release": .int(Int64(releasedGeneration)), "before_release_allowed": .bool(beforeReleaseAllowed), "after_release_denied": .bool(refusedBeforeMode), "input_mode": .string(input.routing.mode), "authority_mode": rig.server.worldState.at(path: "mode") ?? .null, "delayed_result": refused ?? .null, "external_writes": .int(Int64(rig.port.writeCount))]).canonical())")
        }
        test.check(releaseFenced,
            "resident-commands/live-input-generation-release-fences-issued-and-delayed-actions-before-mode-delivery")
        rig.port.release(request.requestID); rig.port.drainPublications()
        let failed = rig.result(request.requestID)
        if failed?.at(path: "status")?.stringValue != "failed" || failed?.at(path: "reason")?.stringValue != "effect_cancelled" {
            print("diagnostic released-input result=\((failed ?? .null).canonical()) delayed=\((refused ?? .null).canonical()) health=\(rig.controller.health.canonical())")
        }
        test.check(failed?.at(path: "status")?.stringValue == "failed"
            && failed?.at(path: "reason")?.stringValue == "effect_cancelled"
            && failed?.at(path: "desired_state_committed_revision")?.intValue != nil
            && failed?.at(path: "effect_issued_nanos")?.intValue != nil
            && failed?.at(path: "landed_frames")?.objectValue?.isEmpty == true
            && failed?.at(path: "verified_nanos") == .null && rig.port.writeCount == 0
            && rig.publications.results(for: request.requestID) == [failed ?? .null],
            "resident-commands/released-issued-action-fails-once-with-committed-unlanded-evidence-and-zero-writes")
        deliverMode.signal()
        test.check(delayedModeCompleted.wait(timeout: .now() + .seconds(1)) == .success
            && rig.server.worldState.at(path: "mode")?.stringValue == "default",
            "resident-commands/delayed-mode-notification-arrives-after-release-refusal-is-observable")
    } catch { test.check(false, "resident-commands/released-input-fixture: \(error)") }
}

private final class ResidentCommandsInputProgressBox: @unchecked Sendable {
    struct Entry: Equatable { let receipt: UInt64; let generation: UInt64; let progress: UInt64 }
    private let condition = NSCondition()
    private var values: [Entry] = []
    func record(_ receipt: UInt64, _ generation: UInt64, _ progress: UInt64) {
        condition.lock(); values.append(.init(receipt: receipt, generation: generation, progress: progress))
        condition.broadcast(); condition.unlock()
    }
    func snapshot() -> [Entry] { condition.lock(); defer { condition.unlock() }; return values }
}

private func runResidentInputProgressScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture), progress = ResidentCommandsInputProgressBox()
        _ = rig.act("resize.start", id: "progress-mode"); _ = rig.result("progress-mode")
        rig.controller.setInputGenerationReader { 77 }
        rig.controller.setInputProgressHandler { receipt, generation, stamp in progress.record(receipt, generation, stamp) }
        rig.port.hold(true)
        let receipt = DispatchTime.now().uptimeNanoseconds
        _ = rig.controller.handle(["op": .string("act"), "action_id": .string("resize.adjust.east"), "request_id": .string("input-progress")],
            receipt: receipt, inputGeneration: 77)
        guard rig.port.waitForIssues(1), let request = rig.port.issued.first else {
            test.check(false, "resident-commands/input-progress-requires-issued-native-action"); return
        }
        rig.port.acknowledgeOnly(request.requestID)
        let first = progress.snapshot()
        test.check(first.count == 1 && first[0].receipt == receipt && first[0].generation == 77 && first[0].progress >= receipt,
            "resident-commands/first-owned-setter-ACK-reports-exact-immutable-input-receipt-and-generation-without-final-completion")
        let frames = rig.server.worldState.at(path: "windows")!.arrayValue!.map { window -> JSONValue in
            var row = window.objectValue!
            if let id = window.at(path: "window_id")?.intValue, let frame = request.frameTargets[String(id)] { row["frame"] = frame.json }
            return .object(row)
        }
        let cached = rig.server.applyWorldDelta(["event": .string("settings_changed"), "windows": .array(frames)])
        _ = rig.waitForProcessed(cached.revision.value)
        test.check(progress.snapshot().count == 1,
            "resident-commands/cached-desired-frames-and-state-publications-never-renew-input-progress")
        func observe(_ id: Int64) -> UInt64 {
            let stamp = DispatchTime.now().uptimeNanoseconds
            let event = rig.server.applyWorldDelta(["event": .string("ax_window_resized"), "windows": .array(frames),
                "observer_generation": .int(Int64(request.observerGeneration)), "observation_window_id": .int(id),
                "observation_completed_uptime_ns": .int(Int64(stamp)),
                "observation": .object(["ready": .bool(true), "world_complete": .bool(true),
                    "read_started_uptime_ns": .int(Int64(stamp)), "read_completed_uptime_ns": .int(Int64(stamp))])])
            _ = rig.waitForProcessed(event.revision.value)
            let drained = DispatchSemaphore(value: 0)
            rig.controller.whenIOQuiescent { drained.signal() }
            _ = drained.wait(timeout: .now() + .seconds(2))
            return stamp
        }
        let firstTarget = observe(1)
        _ = observe(1); _ = observe(999)
        test.check(progress.snapshot().count == 2 && progress.snapshot().last?.progress == firstTarget,
            "resident-commands/only-newly-matching-owned-participant-renews-progress-not-duplicate-or-unrelated-notification")
        let lastTarget = observe(2), completed = rig.result(request.requestID)
        let all = progress.snapshot()
        _ = observe(2)
        test.check(all.count == 3 && all.last?.progress == lastTarget
            && all.allSatisfy { $0.receipt == receipt && $0.generation == 77 && $0.progress >= receipt }
            && completed?.at(path: "status")?.stringValue == "accepted" && progress.snapshot() == all,
            "resident-commands/distinct-target-progress-preserves-input-origin-and-stops-after-final-WmResult")
    } catch { test.check(false, "resident-commands/input-progress-fixture: \(error)") }
}

private func runResidentOwnFocusHandoffScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        for mutation in ["valid", "wrong-target", "wrong-lifetime", "cached", "wrong-PID", "wrong-Space", "wrong-display", "wrong-epoch", "wrong-topology"] {
            let rig = try ResidentCommandsRig(fixture: fixture)
            rig.port.hold(true)
            _ = rig.act("nav.focus.east", id: "own-focus-handoff")
            guard rig.port.waitForIssues(1), let request = rig.port.issued.first,
                  let target = rig.server.worldState.at(path: "windows")?.arrayValue?.first(where: {
                    $0.at(path: "window_id")?.intValue.map(String.init) == request.windowID
                  }) else { test.check(false, "resident-commands/own-focus-handoff-requires-issued-goal"); continue }
            let generation = request.observerGeneration + 1, stamp = DispatchTime.now().uptimeNanoseconds
            var focus = target.objectValue!, windows = rig.server.worldState.at(path: "windows")!.arrayValue!
            focus["observed_uptime_ns"] = .int(Int64(stamp))
            var delta: JSONObject = ["event": .string("app_activated"), "observer_generation": .int(Int64(generation)),
                "frontmost_pid": target.at(path: "pid")!,
                "observation": .object(["reason": .string("app_activated"), "ready": .bool(true), "world_complete": .bool(true),
                    "read_started_uptime_ns": .int(Int64(stamp)), "read_completed_uptime_ns": .int(Int64(stamp))])]
            switch mutation {
            case "wrong-target": focus = windows.first { $0.at(path: "window_id")?.intValue.map(String.init) != request.windowID }!.objectValue!
            case "wrong-lifetime":
                focus["window_generation"] = .int(target.at(path: "window_generation")!.intValue! + 1)
                windows = windows.map { $0.at(path: "window_id") == target.at(path: "window_id") ? .object(focus) : $0 }
            case "cached": focus.removeValue(forKey: "observed_uptime_ns")
            case "wrong-PID": focus["pid"] = .int(9876)
            case "wrong-Space": focus["space_key"] = .string("unrelated-Space")
            case "wrong-display": focus["display_id"] = .string("unrelated-display")
            case "wrong-epoch": delta["observer_epoch"] = .string("unrelated-epoch")
            case "wrong-topology": delta["topology_revision"] = .int(Int64(request.topologyRevision + 1))
            default: break
            }
            delta["focus"] = .object(focus); delta["windows"] = .array(windows)
            let observed = rig.server.applyWorldDelta(delta); _ = rig.waitForProcessed(observed.revision.value)
            if mutation == "valid" {
                let queued = ServeClient.request(socketPath: rig.socketPath, body: ["op": .string("result"), "request_id": .string(request.requestID)])
                test.check(queued?.at(path: "phase")?.stringValue == "queued" && rig.port.cancelledIDs.isEmpty
                    && rig.controller.observationGeneration(for: request) == generation,
                    "resident-commands/own-frontmost-handoff-preserves-only-fresh-intended-focus-goal-while-raise-ACK-is-pending")
                rig.port.acknowledgeOnly(request.requestID)
                let accepted = rig.result(request.requestID)
                test.check(accepted?.at(path: "status")?.stringValue == "accepted"
                    && accepted?.at(path: "focus_confirmed")?.boolValue == true
                    && accepted?.at(path: "requested_observer_generation")?.intValue == Int64(request.observerGeneration)
                    && accepted?.at(path: "observed_observer_generation")?.intValue == Int64(generation)
                    && accepted?.at(path: "first_matching_observation_nanos")?.intValue == Int64(stamp)
                    && accepted?.at(path: "verified_nanos")?.intValue != nil && rig.port.writeCount == 0,
                    "resident-commands/cross-app-focus-handoff-completes-after-independent-target-proof-and-ACK-with-original-request-generation")
            } else {
                let rejected = rig.result(request.requestID)
                test.check(rejected?.at(path: "status")?.stringValue == "failed"
                    && rejected?.at(path: "focus_confirmed")?.boolValue == false
                    && rejected?.at(path: "verified_nanos") == .null
                    && rig.controller.observationGeneration(for: request) == nil,
                    "resident-commands/own-focus-handoff-rejects-\(mutation)-proof-without-retagging-or-verified-success")
            }
        }
    } catch { test.check(false, "resident-commands/own-focus-handoff-fixture: \(error)") }
}

private func runResidentLifecycleDeadlineScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        var specimen = fixture.objectValue!, raw = fixture.at(path: "world")!.objectValue!
        raw["windows"] = .array(raw["windows"]!.arrayValue!.map { window in
            var row = window.objectValue!
            row["managed"] = .bool(window.at(path: "eligible")?.boolValue == true)
            return .object(row)
        })
        specimen["world"] = .object(raw)
        let canonicalFixture = JSONValue.object(specimen)
        let rig = try ResidentCommandsRig(fixture: canonicalFixture)
        _ = rig.act("resize.start", id: "popup-clamp-start"); _ = rig.result("popup-clamp-start")
        rig.port.hold(true); rig.port.evidenceTimeoutNanos = 1_000_000_000
        _ = rig.act("resize.adjust.east", id: "popup-clamp")
        guard rig.port.waitForIssues(1), let request = rig.port.issued.first,
              let requestedNeighbor = request.frameTargets["2"] else {
            test.check(false, "resident-commands/popup-clamp-requires-issued-batch"); return
        }
        let clamped = Frame(x: requestedNeighbor.x, y: requestedNeighbor.y, w: requestedNeighbor.w + 40, h: requestedNeighbor.h)
        rig.port.landingOverrides["2"] = clamped
        rig.port.hold(false); rig.port.release(request.requestID); rig.port.drainPublications()
        var windows = rig.server.worldState.at(path: "windows")!.arrayValue!
        var ignored = windows[0].objectValue!
        ignored["window_id"] = .int(47); ignored["window_generation"] = .int(99)
        ignored["eligible"] = .bool(false); ignored["managed"] = .bool(false); ignored["resizable"] = .bool(false)
        ignored["subrole"] = .string("AXDialog"); ignored["frame"] = Frame(x: 16, y: 54, w: 66, h: 20).json
        windows.append(.object(ignored))
        let popupReceipt = DispatchTime.now().uptimeNanoseconds
        let created = rig.server.applyWorldDelta(["event": .string("ax_window_created"),
            "windows": .array(windows), "notification_window_id": .int(47),
            "notification_receipt_uptime_ns": .int(Int64(popupReceipt)),
            "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "target_window_id": .int(47),
                "reason": .string("ax_window_created"), "source_receipt_uptime_ns": .int(Int64(popupReceipt)),
                "read_completed_uptime_ns": .int(Int64(popupReceipt + 1))])])
        let processed = rig.waitForProcessed(created.revision.value)
        let cache = ServeClient.request(socketPath: rig.socketPath, body: ["op": .string("result"), "request_id": .string(request.requestID)])
        test.check(processed && cache?.at(path: "phase")?.stringValue == "queued"
            && rig.port.deadlineIsArmed(request.requestID) && rig.port.cancelledIDs.isEmpty
            && rig.controller.mayIssueEffect(request),
            "resident-commands/positively-ignored-tooltip-preserves-partially-landed-flight-and-original-one-shot-deadline")
        let expired = rig.result(request.requestID)
        test.check(expired?.at(path: "status")?.stringValue == "failed"
            && expired?.at(path: "reason")?.stringValue == "targeted_evidence_timeout"
            && expired?.at(path: "verified_nanos") == .null
            && Frame.from(expired?.at(path: "landed_frames.2")) == clamped
            && Frame.from(expired?.at(path: "requested_frames.2")) == requestedNeighbor
            && rig.port.firedDeadlineIDs == [request.requestID]
            && rig.controller.health.at(path: "in_flight") == .null,
            "resident-commands/partial-clamp-after-ignored-tooltip-fails-by-live-deadline-with-honest-requested-and-landed-frames")

        let invalid = try ResidentCommandsRig(fixture: canonicalFixture)
        _ = invalid.act("resize.start", id: "cohort-start"); _ = invalid.result("cohort-start")
        invalid.port.hold(true); invalid.port.evidenceTimeoutNanos = 1_000_000_000
        _ = invalid.act("resize.adjust.east", id: "cohort-change")
        guard invalid.port.waitForIssues(1), let old = invalid.port.issued.first else {
            test.check(false, "resident-commands/cohort-change-requires-issued-batch"); return
        }
        var changedWindows = invalid.server.worldState.at(path: "windows")!.arrayValue!
        var newcomer = changedWindows[0].objectValue!; newcomer["window_id"] = .int(48)
        newcomer["window_generation"] = .int(100); newcomer["pid"] = .int(548)
        changedWindows.append(.object(newcomer))
        let cohortReceipt = DispatchTime.now().uptimeNanoseconds
        let changed = invalid.server.applyWorldDelta(["event": .string("ax_window_created"),
            "windows": .array(changedWindows), "notification_window_id": .int(48),
            "notification_receipt_uptime_ns": .int(Int64(cohortReceipt)),
            "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "target_window_id": .int(48),
                "reason": .string("ax_window_created"), "source_receipt_uptime_ns": .int(Int64(cohortReceipt)),
                "read_completed_uptime_ns": .int(Int64(cohortReceipt + 1))])])
        _ = invalid.waitForProcessed(changed.revision.value)
        let failed = invalid.result(old.requestID)
        test.check(failed?.at(path: "status")?.stringValue == "failed"
            && failed?.at(path: "reason")?.stringValue == "invalidated_ax_window_created"
            && failed?.at(path: "desired_state_committed_revision")?.intValue != nil
            && invalid.port.cancelledIDs.contains(old.requestID) && !invalid.port.deadlineIsArmed(old.requestID),
            "resident-commands/hard-same-generation-lifecycle-fence-cancels-effect-authority-and-publishes-terminal-before-lease-removal-can-orphan-it")
    } catch { test.check(false, "resident-commands/lifecycle-deadline-fixture: \(error)") }
}

private func runResidentFrameContinuityScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        _ = rig.act("resize.start", id: "continuity-start"); _ = rig.result("continuity-start")
        rig.port.hold(true)
        _ = rig.act("resize.adjust.east", id: "continuity-first")
        guard rig.port.waitForIssues(1), let request = rig.port.issued.first else {
            test.check(false, "resident-commands/continuity-requires-real-issued-frame-request"); return
        }
        _ = rig.act("resize.adjust.east", id: "continuity-middle")
        let pendingBeforeRebind = rig.waitForPending(1)
        let nextGeneration = request.observerGeneration + 1
        let activation = rig.server.applyWorldDelta(["event": .string("app_activated"),
            "observer_generation": .int(Int64(nextGeneration)),
            "focus": rig.server.worldState.at(path: "windows")!.arrayValue![1]])
        let processed = rig.waitForProcessed(activation.revision.value)
        let admission = ServeClient.request(socketPath: rig.socketPath, body: ["op": .string("result"), "request_id": .string(request.requestID)])
        test.check(pendingBeforeRebind && processed && rig.controller.mayIssueEffect(request)
            && rig.controller.observationGeneration(for: request) == nextGeneration
            && rig.port.cancelledIDs.isEmpty && rig.port.writeCount == 0
            && rig.port.issued.first?.fingerprint == request.fingerprint
            && admission?.at(path: "phase")?.stringValue == "queued",
            "resident-commands/healthy-app-focus-rebind-preserves-issued-frame-goal-without-cached-landing-or-request-retagging")
        _ = rig.act("resize.adjust.east", id: "continuity-new-modal")
        let staleModal = rig.result("continuity-new-modal")
        let pending = rig.waitForPending(1)
        rig.port.hold(false); rig.port.release(request.requestID)
        let first = rig.result(request.requestID), final = rig.result("continuity-middle")
        let landed = pending && first?.at(path: "status")?.stringValue == "accepted"
            && first?.at(path: "requested_observer_generation")?.intValue == Int64(request.observerGeneration)
            && first?.at(path: "observed_observer_generation")?.intValue == Int64(nextGeneration)
            && first?.at(path: "landed_frames")?.objectValue?.count == request.frameTargets.count
            && first?.at(path: "verified_nanos")?.intValue != nil
            && final?.at(path: "status")?.stringValue == "accepted" && rig.port.issued.count == 2
            && Frame.from(final?.at(path: "requested_frames.1"))?.w == 676
            && final?.at(path: "requested_observer_generation")?.intValue == Int64(request.observerGeneration)
            && final?.at(path: "observed_observer_generation")?.intValue == Int64(nextGeneration)
            && staleModal?.at(path: "status")?.stringValue == "refused"
            && staleModal?.at(path: "reason")?.stringValue == "interaction_context_invalid"
            && rig.port.cancelledIDs.isEmpty
        if !landed { print("diagnostic continuity first=\((first ?? .null).canonical()) pending_result=\((final ?? .null).canonical()) stale_modal=\((staleModal ?? .null).canonical()) pending=\(pending) issued=\(rig.port.issued.count) health=\(rig.controller.health.canonical())") }
        test.check(landed,
            "resident-commands/rebound-frame-goal-lands-admitted-relative-intent-and-refuses-stale-new-modal-command")
        for mutation in ["lifetime", "pid", "Space", "display", "epoch", "topology", "incomplete"] {
            let invalid = try ResidentCommandsRig(fixture: fixture)
            _ = invalid.act("resize.start", id: "invalid-continuity-start"); _ = invalid.result("invalid-continuity-start")
            invalid.port.hold(true)
            _ = invalid.act("resize.adjust.east", id: "invalid-continuity")
            guard invalid.port.waitForIssues(1), let old = invalid.port.issued.first else {
                test.check(false, "resident-commands/\(mutation)-continuity-requires-issued-request"); continue
            }
            var delta: JSONObject = ["event": .string("app_activated"), "observer_generation": .int(Int64(old.observerGeneration + 1))]
            var windows = invalid.server.worldState.at(path: "windows")!.arrayValue!
            var window = windows[0].objectValue!
            switch mutation {
            case "lifetime": window["window_generation"] = .int(window["window_generation"]!.intValue! + 1)
            case "pid": window["pid"] = .int(9999)
            case "Space": window["space_key"] = .string("display-A/other-Space")
            case "display": window["display_id"] = .string("display-B")
            case "epoch": delta["observer_epoch"] = .string("different-world-epoch")
            case "topology": delta["topology_revision"] = .int(Int64(old.topologyRevision + 1))
            default: delta["observation"] = .object(["ready": .bool(false), "world_complete": .bool(false)])
            }
            windows[0] = .object(window); delta["windows"] = .array(windows)
            let changed = invalid.server.applyWorldDelta(delta)
            let deniedImmediately = !invalid.controller.mayIssueEffect(old)
                && invalid.controller.observationGeneration(for: old) == nil
            let drained = invalid.waitForProcessed(changed.revision.value)
            let result = invalid.result(old.requestID)
            invalid.port.release(old.requestID); invalid.port.drainPublications()
            test.check(deniedImmediately && drained && result?.at(path: "status")?.stringValue == "failed"
                && result?.at(path: "verified_nanos") == .null
                && result?.at(path: "landed_frames")?.objectValue?.isEmpty == true && invalid.port.writeCount == 0,
                "resident-commands/activation-with-changed-\(mutation)-fences-old-frame-goal-with-zero-external-writes")
        }
        let recovery = try ResidentCommandsRig(fixture: fixture, complete: false)
        let recovered = recovery.server.applyWorldDelta(["event": .string("app_activated"),
            "observer_generation": .int(9), "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "world_recovered": .bool(false)])])
        _ = recovery.waitForProcessed(recovered.revision.value)
        let deadline = Date(timeIntervalSinceNow: 2)
        while recovery.server.worldState.at(path: "model_state.space_partitions.schema") == nil && Date() < deadline { usleep(500) }
        let quiescent = DispatchSemaphore(value: 0)
        recovery.controller.whenIOQuiescent { quiescent.signal() }
        let durable = quiescent.wait(timeout: .now() + .seconds(2)) == .success
        let checkpoint = try recovery.journal.recoverCheckpoint()
        test.check(durable && recovery.server.worldState.at(path: "model_state.space_partitions.schema")?.stringValue == "leyline/resident-space-partitions/v1"
            && checkpoint.state?.at(path: "space_partitions.schema")?.stringValue == "leyline/resident-space-partitions/v1"
            && recovery.port.issued.isEmpty,
            "resident-commands/incomplete-to-complete-app-activation-reconciles-fresh-world-without-retrying-old-effects")
    } catch { test.check(false, "resident-commands/frame-continuity-fixture: \(error)") }
}

private func runResidentStateOnlyScenarios(fixture: JSONValue, test: inout SelfTest) {
    for allOff in [false, true] {
        let name = allOff ? "all-OFF" : "empty"
        do {
            var specimen = fixture.objectValue!, world = fixture.at(path: "world")!.objectValue!
            world["focus"] = .null
            if allOff {
                world["space_activation"] = .object(["display-A/space-A": .bool(false), "display-B/space-B": .bool(false)])
                world["space_contexts"] = .array(world["space_contexts"]!.arrayValue!.map { row in
                    var value = row.objectValue!; value["space_enabled"] = .bool(false); return .object(value)
                })
                world["windows"] = .array(world["windows"]!.arrayValue!.map { row in
                    var value = row.objectValue!; value["space_enabled"] = .bool(false); return .object(value)
                })
                var active = world["active_context"]!.objectValue!; active["space_enabled"] = .bool(false)
                world["active_context"] = .object(active)
            } else {
                world["windows"] = .array([])
            }
            specimen["world"] = .object(world)
            let rig = try ResidentCommandsRig(fixture: .object(specimen))
            let checkpoint = try rig.journal.recoverCheckpoint()
            let model = rig.server.worldState.at(path: "model_state")!
            let records = checkpoint.records
            let marker = records.last { $0.at(path: "type")?.stringValue == "model_state_commit" }
            test.check(rig.bootstrapResult?.at(path: "status")?.stringValue == "accepted"
                && rig.port.issued.isEmpty && rig.port.writeCount == 0
                && model.at(path: "arrangement.bindings")?.objectValue?.isEmpty == true,
                "resident-commands/\(name)-identified-world-commits-partition-state-with-zero-AX")
            let recoveredExactly = records.contains { $0.at(path: "type")?.stringValue == "model_state_intent" }
                && marker != nil && checkpoint.state?.canonical() == model.canonical()
                && checkpoint.highWaterRevision == UInt64(marker?.at(path: "revision")?.intValue ?? -1)
                && checkpoint.highWaterRevision > 0
            if !recoveredExactly {
                print("diagnostic \(name)-state-only checkpoint=\((checkpoint.state ?? .null).canonical()) model=\(model.canonical()) highwater=\(checkpoint.highWaterRevision) marker=\((marker ?? .null).canonical())")
            }
            test.check(recoveredExactly,
                "resident-commands/\(name)-state-only-journal-recovers-exact-checkpoint-and-highwater")
            let cached = model.at(path: "space_partitions")
            test.check(cached?.at(path: "visible.1.space_enabled")?.boolValue == !allOff
                && (allOff || cached?.at(path: "partitions")?.objectValue?["1:display-A/space-A"]?.at(path: "arrangement.bindings")?.objectValue?.isEmpty == true),
                "resident-commands/\(name)-checkpoint-keeps-actual-context-without-inventing-window-effects")
        } catch { test.check(false, "resident-commands/\(name)-state-only-fixture: \(error)") }
    }
}

private func runResidentSpaceSwitchScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        var manualAccepted = true
        for (action, id) in [("resize.start", "switch-resize-start"), ("resize.adjust.east", "switch-resize"), ("resize.off", "switch-resize-off")] {
            _ = rig.act(action, id: id)
            let result = rig.result(id)
            manualAccepted = manualAccepted && result?.at(path: "status")?.stringValue == "accepted"
        }
        let original = rig.server.worldState
        let originalA = original.at(path: "model_state.space_partitions.partitions")?.objectValue?["1:display-A/space-A"]
        let originalContexts = original.at(path: "space_contexts")!.arrayValue!
        let originalWindows = original.at(path: "windows")!.arrayValue!
        let newKey = "display-A/space-C"
        let switchedContexts = originalContexts.map { context -> JSONValue in
            guard context.at(path: "display_id")?.stringValue == "display-A" else { return context }
            var row = context.objectValue!; row["space_key"] = .string(newKey); row["space_uuid"] = .string(newKey)
            return .object(row)
        }
        let arrivalA = (fixture.at(path: "world.windows")!.arrayValue!).filter {
            $0.at(path: "display_id")?.stringValue == "display-A"
        }.map { window -> JSONValue in
            var row = window.objectValue!; let id = window.at(path: "window_id")!.intValue! + 3
            row["window_id"] = .int(id); row["pid"] = .int(500 + id)
            row["space_key"] = .string(newKey); row["space_uuid"] = .string(newKey)
            return .object(row)
        }
        let switchedWindows = arrivalA + originalWindows.filter { $0.at(path: "display_id")?.stringValue != "display-A" }
        var activation = original.at(path: "space_activation")!.objectValue!; activation[newKey] = .bool(true)
        let switchAdmission = rig.server.applyWorldDelta(["event": .string("space_changed"),
            "windows": .array(switchedWindows), "focus": arrivalA.first!, "space_contexts": .array(switchedContexts),
            "active_context": switchedContexts.first!, "space_activation": .object(activation)])
        rig.controller.reconcile(requestID: "fixture-switch-C")
        let switchResult = rig.result("fixture-switch-C")
        let switched = rig.server.worldState.at(path: "model_state")!
        let switchedIDs = Set((switched.at(path: "arrangement.bindings")?.objectValue ?? [:]).values.compactMap { $0.at(path: "window_id")?.intValue })
        test.check(manualAccepted && originalA != nil && switchAdmission.status == .accepted
            && ["accepted", "noop"].contains(switchResult?.at(path: "status")?.stringValue ?? "")
            && switchedIDs == [4, 5]
            && switched.at(path: "space_partitions.partitions")?.objectValue?["1:display-A/space-A"] == originalA,
            "resident-commands/actual-Space-switch-caches-departed-manual-partition-and-admits-only-new-membership")
        let returnAdmission = rig.server.applyWorldDelta(["event": .string("space_changed"),
            "windows": .array(originalWindows), "focus": original.at(path: "focus")!,
            "space_contexts": .array(originalContexts), "active_context": original.at(path: "active_context")!])
        rig.controller.reconcile(requestID: "fixture-return-A")
        let returnResult = rig.result("fixture-return-A")
        let returned = rig.server.worldState.at(path: "model_state")!
        let returnedIDs = Set((returned.at(path: "arrangement.bindings")?.objectValue ?? [:]).values.compactMap { $0.at(path: "window_id")?.intValue })
        let checkpoint = try rig.journal.recoverCheckpoint()
        let returnRestored = returnAdmission.status == .accepted && ["accepted", "noop"].contains(returnResult?.at(path: "status")?.stringValue ?? "")
            && returnedIDs == [1, 2] && returned.at(path: "space_partitions.partitions")?.objectValue?["1:display-A/space-A"] == originalA
            && returned.at(path: "space_partitions.partitions")?.objectValue?["1:display-A/space-C"] != nil
            && checkpoint.state?.canonical() == returned.canonical() && checkpoint.highWaterRevision > 0
        if !returnRestored {
            print("diagnostic return-Space result=\((returnResult ?? .null).canonical()) original-A=\((originalA ?? .null).canonical()) returned-A=\((returned.at(path: "space_partitions.partitions")?.objectValue?["1:display-A/space-A"] ?? .null).canonical()) checkpoint_matches=\(checkpoint.state?.canonical() == returned.canonical()) highwater=\(checkpoint.highWaterRevision)")
        }
        test.check(returnRestored,
            "resident-commands/return-to-actual-Space-restores-manual-geometry-and-durable-dormant-cache")
    } catch { test.check(false, "resident-commands/Space-switch-fixture: \(error)") }
}

private func runResidentGutterScenarios(fixture: JSONValue, test: inout SelfTest) {
    let displays = (fixture.at(path: "world.topology")?.arrayValue ?? []).map { value -> JSONValue in
        var object = value.objectValue!; object["usable"] = object["usable_frame"]; return .object(object)
    }
    let tree: JSONValue = .object(["root_id": .string("root"), "nodes": .object([
        "root": .object(["id": .string("root"), "mode": .string("region"), "children": .array([.string("d:1")])]),
        "d:1": .object(["id": .string("d:1"), "mode": .string("row"), "display_id": .int(1),
            "frame_source": .string("pinned"), "children": .array([.string("w:1"), .string("w:2")])]),
        "w:1": .object(["id": .string("w:1"), "window_id": .int(1), "min_size": .object(["w": .int(590), "h": .int(700)])]),
        "w:2": .object(["id": .string("w:2"), "window_id": .int(2), "min_size": .object(["w": .int(590), "h": .int(700)])]),
    ])])
    let gutterCases = fixture.at(path: "gutter_cases")?.arrayValue ?? []
    test.check(gutterCases.compactMap { $0.at(path: "gap")?.intValue } == [0, 8, 20],
        "resident-commands/gutter-fixture-discovery-exact-and-nonempty")
    for gutterCase in gutterCases {
        guard let gap = gutterCase.at(path: "gap")?.intValue else { continue }
        let topology: JSONValue = .object(["displays": .array(displays), "gap": .int(gap), "outer_gap": gutterCase.at(path: "outer_gap")!])
        let normalized = Project.normTopology(topology)
        let cells = Arrangement.cellsMd(Arrangement.parseSegs(fixture.at(path: "store.segments")), normalized)
        let area = cells.reduce(0) { $0 + $1.frame.w * $1.frame.h }
        let usableArea = normalized.displays.reduce(0) { $0 + $1.usable.w * $1.usable.h }
        let bridge = Arrangement.bridgeArrangementNative(store: fixture.at(path: "store")!, topo: topology)
        let targets = Arrangement.arrangementTargets(bridge: bridge, topo: topology)
        let first = Frame.from(targets.at(path: "1.frame")), second = Frame.from(targets.at(path: "2.frame"))
        test.check(abs(area - usableArea) < 0.5 && first != nil && second != nil
            && first!.x == 0 && first!.y == 30 && first!.maxY == 800 && second!.maxX == 1200
            && abs(second!.x - first!.maxX - Double(gap)) < 0.5,
            "resident-commands/gutter-\(gap)-covers-raw-usable-canvas-with-only-interior-inset")
        let projected = Project.reconcileTargets(tree: tree, topo: topology)
        let projectedFirst = Frame.from(projected.at(path: "1.frame")), projectedSecond = Frame.from(projected.at(path: "2.frame"))
        test.check(projectedFirst == first && projectedSecond == second && projectedFirst!.w >= 590
            && projectedSecond!.w >= 590 && projectedFirst!.h >= 700,
            "resident-commands/gutter-\(gap)-native-and-tree-min-fit-agree-without-double-reservations")
    }
    let legacy: JSONValue = .object(["displays": .array(displays), "gap": .int(8)])
    let explicitLegacy: JSONValue = .object(["displays": .array(displays), "gap": .int(8), "outer_gap": .int(8)])
    test.check(Project.normTopology(legacy).outerGap == 8 && !Project.normTopology(legacy).hasExplicitOuterGap
        && Project.reconcileTargets(tree: tree, topo: legacy) == Project.reconcileTargets(tree: tree, topo: explicitLegacy),
        "resident-commands/missing-outer-gap-preserves-legacy-projection-exactly")
}

private func runResidentSpacePreferenceToggleScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        let target = ResidentSpaceTarget(spaceKey: "display-A/space-A", displayId: "display-A")
        let path = rig.directory.appendingPathComponent("space-settings.json").path
        try ResidentSettingsStore.write(path: path, spacesEnabled: [target.spaceKey: true, "display-B/space-B": false],
            desiredRunning: true, globalGutterWidth: 1)
        let off = try ResidentSpaceManagement.toggle(target: target, world: rig.server.worldState,
            settingsPath: path, desiredRunning: true, commit: { rig.server.setSpaceEnabled($0, enabled: $1) })
        let disabled = ResidentSettingsStore.read(path: path)
        test.check(!off && !rig.server.spaceIsEnabled(target.spaceKey) && disabled.spacesEnabled[target.spaceKey] == false
            && disabled.spacesEnabled["display-B/space-B"] == false && !rig.server.spaceIsEnabled("display-B/space-B")
            && disabled.desiredRunning && disabled.globalGutterWidth == 1,
            "space-shortcut/native-off-persists-only-target-and-preserves-global-settings")
        let on = try ResidentSpaceManagement.toggle(target: target, world: rig.server.worldState,
            settingsPath: path, desiredRunning: true, commit: { rig.server.setSpaceEnabled($0, enabled: $1) })
        test.check(on && rig.server.spaceIsEnabled(target.spaceKey)
            && ResidentSettingsStore.read(path: path).spacesEnabled[target.spaceKey] == true
            && !rig.server.spaceIsEnabled("display-B/space-B"),
            "space-shortcut/native-on-restores-target-with-other-space-still-off")
        let bytes = FileManager.default.contents(atPath: path)
        do {
            _ = try ResidentSpaceManagement.toggle(target: .init(spaceKey: "unobserved-space", displayId: "display-A"),
                world: rig.server.worldState, settingsPath: path, desiredRunning: true,
                commit: { rig.server.setSpaceEnabled($0, enabled: $1) })
            test.check(false, "space-shortcut/unobserved-target-refuses-before-persistence")
        } catch {
            test.check((error as? ResidentInputError)?.code == "space_identity_unavailable"
                && FileManager.default.contents(atPath: path) == bytes,
                "space-shortcut/unobserved-target-refuses-before-persistence")
        }
        try Data("invalid preferences".utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try ResidentSpaceManagement.toggle(target: target, world: rig.server.worldState,
                settingsPath: path, desiredRunning: true, commit: { rig.server.setSpaceEnabled($0, enabled: $1) })
            test.check(false, "space-shortcut/invalid-preferences-never-overwritten")
        } catch {
            test.check((error as? ResidentInputError)?.code == "SETTINGS.INVALID"
                && FileManager.default.contents(atPath: path) == Data("invalid preferences".utf8),
                "space-shortcut/invalid-preferences-never-overwritten")
        }
    } catch { test.check(false, "space-shortcut/native-integration: \(error)") }
}

/// Production-default outer policy must use the configured stroke width even
/// though older fixed-geometry integration specimens declare outer_gap0.
private func runResidentBorderWidthScenarios(fixture: JSONValue, test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/projection/border-spacing.json"
    guard let bytes = FileManager.default.contents(atPath: path), let spacing = try? JSONValue.parse(bytes),
          let cases = spacing.at(path: "resident_cases")?.arrayValue, cases.count == 5 else {
        test.check(false, "resident-border/fixture-load"); return
    }
    for scenario in cases {
        do {
            var configured = fixture.objectValue!
            let width = scenario.at(path: "width")!.intValue!
            configured["gap"] = .int(width)
            let rig = try ResidentCommandsRig(fixture: .object(configured), outerGap: nil)
            let windows = rig.server.worldState.at(path: "windows")!.arrayValue!
            test.check(Frame.from(windows.first { $0.at(path: "window_id") == .int(1) }?.at(path: "frame"))
                == Frame.from(scenario.at(path: "expected_left"))
                && Frame.from(windows.first { $0.at(path: "window_id") == .int(2) }?.at(path: "frame"))
                == Frame.from(scenario.at(path: "expected_right")),
                "resident-border/width-\(width)-real-controller-journal-effect-uses-border-spacing")
        } catch { test.check(false, "resident-border/integration: \(error)") }
    }
    do {
        let rig = try ResidentCommandsRig(fixture: fixture, outerGap: nil)
        for scenario in cases.reversed() where scenario.at(path: "width")?.intValue != 8 {
            let width = scenario.at(path: "width")!.intValue!
            let receipt = DispatchTime.now().uptimeNanoseconds
            rig.controller.setGap(Int(width))
            let result = rig.publications.waitForInternalReconcile(after: receipt)
            let windows = rig.server.worldState.at(path: "windows")!.arrayValue!
            test.check(result?.at(path: "status")?.stringValue == "accepted"
                && Frame.from(windows.first { $0.at(path: "window_id") == .int(1) }?.at(path: "frame"))
                    == Frame.from(scenario.at(path: "expected_left"))
                && Frame.from(windows.first { $0.at(path: "window_id") == .int(2) }?.at(path: "frame"))
                    == Frame.from(scenario.at(path: "expected_right")),
                "resident-border/width-change-to-\(width)-reflows-same-resident-with-shared-spacing")
        }
    } catch { test.check(false, "resident-border/responsive-configuration: \(error)") }
}

private final class ResidentCommandsOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResidentEffectOutcome] = []
    func record(_ value: ResidentEffectOutcome) { lock.lock(); values.append(value); lock.unlock() }
    var last: ResidentEffectOutcome? { lock.lock(); defer { lock.unlock() }; return values.last }
}

private func runResidentCrossGenerationGoalScenarios(test: inout SelfTest) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ley-focus-goal-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ResidentEffectorFileJournal(path: directory.appendingPathComponent("journal.jsonl").path)
        let context = ResidentEffectContext(revision: 3, observerGeneration: 8, activeSpaceKey: "display-A/space-A",
            topologyRevision: 4, trusted: true, complete: true, spaceEnabled: true)
        let port = ResidentCommandsPort(); port.hold(true)
        let outcomes = ResidentCommandsOutcomeBox()
        let observationClock = ResidentAtomic<UInt64>(100)
        let effector = ResidentEffector(context: context, journal: journal, port: port,
            now: { observationClock.load(ordering: .acquiring) }, onOutcome: { outcomes.record($0) })
        var request = ResidentEffectRequest(requestID: "generation-goal", actionID: "nav.focus.east", windowID: "2",
            expectedRevision: 3, observerGeneration: 8, activeSpaceKey: "display-A/space-A", topologyRevision: 4,
            receiptNanos: 10, frame: Frame(x: 604, y: 30, w: 596, h: 770))
        request.effectKind = .focus; request.ordered = true; request.windowGenerations = ["2": 1]
        _ = effector.submit(request); let issued = port.waitForIssues(1); port.acknowledgeOnly("generation-goal")
        observationClock.store(110, ordering: .releasing)
        var observed = context; observed.revision = 4; observed.observerGeneration = 9
        var wrongSpace = observed; wrongSpace.activeSpaceKey = "display-B/space-B"
        var wrongTopology = observed; wrongTopology.topologyRevision = 5
        var untrusted = observed; untrusted.trusted = false
        test.check(issued && !effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 2,
            observedContext: observed, timestampNanos: 110), "resident-commands/cross-generation-goal-rejects-recycled-window-lifetime")
        test.check(!effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
            observedContext: wrongSpace, timestampNanos: 110), "resident-commands/cross-generation-goal-rejects-wrong-Space")
        test.check(!effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
            observedContext: wrongTopology, timestampNanos: 110), "resident-commands/cross-generation-goal-rejects-changed-topology")
        test.check(!effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
            observedContext: untrusted, timestampNanos: 110)
            && !effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
                observedContext: observed, timestampNanos: 99), "resident-commands/cross-generation-goal-rejects-untrusted-or-pre-issue-evidence")
        let accepted = effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
            observedContext: observed, timestampNanos: 110)
        test.check(accepted && outcomes.last?.requestedGeneration == 8 && outcomes.last?.observedGeneration == 9
            && outcomes.last?.verifiedNanos == 110 && outcomes.last?.firstMatchingObservationNanos == 110
            && effector.snapshot().at(path: "generation_causes")?.arrayValue?.last?.at(path: "generation")?.intValue == 9,
            "resident-commands/cross-generation-goal-completes-and-attributes-real-generation-without-retagging")
        observationClock.store(120, ordering: .releasing)
        test.check(!effector.confirmFocusedGoal(requestID: request.requestID, windowID: "2", windowGeneration: 1,
            observedContext: observed, timestampNanos: 120), "resident-commands/completed-goal-cannot-be-replayed-as-new-evidence")
    } catch { test.check(false, "resident-commands/cross-generation-goal-fixture: \(error)") }
}

/// Actual Controller/journal/effect route over independently delivered mock AX
/// observations. These cases prove state/provenance semantics, not live pixels.
private func runResidentProductCompletionScenarios(fixture sourceFixture: JSONValue, test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/resident_commands/product_completion.json"
    guard let bytes = FileManager.default.contents(atPath: path), let product = try? JSONValue.parse(bytes) else {
        test.check(false, "product/fixture-load"); return
    }
    var positiveFixture = sourceFixture.objectValue!, positiveWorld = sourceFixture.at(path: "world")!.objectValue!
    let observerGeneration = positiveWorld["observer_generation"]!
    positiveWorld["windows"] = .array(positiveWorld["windows"]!.arrayValue!.map { row -> JSONValue in
        var window = row.objectValue!; window["managed"] = .bool(true); window["observer_generation"] = observerGeneration
        return .object(window)
    })
    var positiveFocus = positiveWorld["focus"]!.objectValue!
    positiveFocus["managed"] = .bool(true); positiveFocus["observer_generation"] = observerGeneration
    positiveWorld["focus"] = .object(positiveFocus); positiveFixture["world"] = .object(positiveWorld)
    let fixture = JSONValue.object(positiveFixture)
    let previewActions = product.at(path: "preview_actions")!.arrayValue!.compactMap(\.stringValue)
    func preparePreview(_ rig: ResidentCommandsRig, prefix: String) -> Bool {
        for (index, action) in previewActions.enumerated() {
            let id = "\(prefix)-\(index)"
            _ = rig.act(action, id: id)
            if rig.result(id)?.at(path: "status")?.stringValue != "accepted" { return false }
        }
        return true
    }
    func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() { if Date() >= deadline { return false }; usleep(500) }
        return true
    }
    do {
        let preview = try ResidentCommandsRig(fixture: fixture)
        let initial = preview.server.worldState.at(path: "model_state.arrangement")
        let actual = preview.server.worldState.at(path: "windows")
        let prepared = preparePreview(preview, prefix: "exact-preview")
        let snapshot = preview.server.committedSnapshot
        let candidate = snapshot.world.at(path: "model_state.interaction.candidate")
        let ghosts = snapshot.borderPlan.rings.filter { $0.stroke == .dashed }
        test.check(prepared && candidate != nil && !ghosts.isEmpty && preview.port.issued.isEmpty
            && preview.server.worldState.at(path: "model_state.arrangement") == initial
            && preview.server.worldState.at(path: "windows") == actual
            && candidate?.at(path: "base.state_revision") == snapshot.world.at(path: "model_state_revision")
            && ghosts.allSatisfy {
                let target = candidate?.at(path: "affected_frames")?.objectValue?[String($0.windowId)]
                return $0.frame.json == (target?.at(path: "effect_frame") ?? target?.at(path: "frame"))
            },
            "product/native-staged-preview-shares-current-revision-and-keeps-every-actual-window-stationary")
        _ = preview.act(product.at(path: "preview_commit")!.stringValue!, id: "exact-confirm")
        let confirmed = preview.result("exact-confirm")
        let expected = candidate?.at(path: "targets")?.objectValue ?? [:]
        let issued = preview.port.issued.last
        test.check(confirmed?.at(path: "status")?.stringValue == "accepted"
            && issued?.proposedState?.at(path: "arrangement") == candidate?.at(path: "desired_arrangement")
            && issued?.frameTargets.allSatisfy { $0.value.json == (expected[$0.key]?.at(path: "effect_frame") ?? expected[$0.key]?.at(path: "frame")) } == true
            && preview.server.worldState.at(path: "model_state.arrangement") == candidate?.at(path: "desired_arrangement"),
            "product/native-confirm-consumes-preview-arrangement-and-every-issued-frame-verbatim")

        let stale = try ResidentCommandsRig(fixture: fixture)
        _ = preparePreview(stale, prefix: "stale-preview")
        let oldID = stale.server.worldState.at(path: "model_state.interaction.candidate.candidate_id")
        var updated = stale.server.worldState.at(path: "model_state")!.objectValue!
        updated["minimum_sizes"] = product.at(path: "stale_minimums")
        let delta = stale.server.applyWorldDelta(["event": .string("fixture_floor_changed"), "model_state": .object(updated)])
        _ = stale.waitForProcessed(delta.revision.value)
        _ = stale.act(product.at(path: "preview_commit")!.stringValue!, id: "stale-confirm")
        let replacement = stale.result("stale-confirm")
        test.check(replacement?.at(path: "reason")?.stringValue == "candidate_replaced_requires_confirmation"
            && stale.port.issued.isEmpty && stale.server.worldState.at(path: "model_state.interaction.candidate.candidate_id") != oldID
            && !stale.server.committedSnapshot.borderPlan.rings.filter({ $0.stroke == .dashed }).isEmpty,
            "product/stale-confirm-publishes-new-preview-with-zero-AX-and-requires-fresh-confirmation")
        var refocusedWindows = stale.server.worldState.at(path: "windows")!.arrayValue!
        refocusedWindows = refocusedWindows.map { row in
            var window = row.objectValue!; window["observer_generation"] = .int(9); return .object(window)
        }
        let refocus = stale.server.applyWorldDelta(["event": .string("app_activated"), "observer_generation": .int(9),
            "windows": .array(refocusedWindows), "focus": refocusedWindows.first { $0.at(path: "window_id") == .int(2) }!])
        _ = stale.waitForProcessed(refocus.revision.value)
        _ = stale.act(product.at(path: "preview_commit")!.stringValue!, id: "refocused-confirm")
        test.check(stale.result("refocused-confirm")?.at(path: "reason") == .string("candidate_replaced_requires_confirmation")
            && stale.server.worldState.at(path: "model_state.interaction.source_window_id") == .int(1)
            && stale.port.issued.isEmpty,
            "product/healthy-focus-generation-change-refreshes-original-lifetime-intent-without-retarget-or-AX")

        var crowded = fixture.objectValue!, crowdedWorld = fixture.at(path: "world")!.objectValue!
        var rawWindows = crowdedWorld["windows"]!.arrayValue!
        var buried = rawWindows[0].objectValue!
        buried["window_id"] = .int(4); buried["pid"] = .int(504); buried["window_generation"] = .int(1)
        rawWindows.append(.object(buried)); crowdedWorld["windows"] = .array(rawWindows)
        crowded["world"] = .object(crowdedWorld)
        let member = try ResidentCommandsRig(fixture: .object(crowded))
        var memberModel = member.server.worldState.at(path: "model_state")!.objectValue!
        var memberArrangement = memberModel["arrangement"]!.objectValue!
        var memberBindings = memberArrangement["bindings"]!.objectValue!
        let frontKey = memberBindings.first { $0.value.at(path: "window_id") == .int(1) }!.key
        let buriedKey = memberBindings.first { $0.value.at(path: "window_id") == .int(4) }!.key
        var front = memberBindings[frontKey]!.objectValue!
        var buriedRecord = memberBindings[buriedKey]!.objectValue!
        buriedRecord["frame"] = .null; buriedRecord["presented"] = .bool(false)
        front["contents"] = .array([memberBindings[frontKey]!, .object(buriedRecord)])
        memberBindings[frontKey] = .object(front); memberBindings.removeValue(forKey: buriedKey)
        memberArrangement["bindings"] = .object(memberBindings)
        memberModel["arrangement"] = .object(memberArrangement)
        var cache = memberModel["space_partitions"]!.objectValue!
        var partitions = cache["partitions"]!.objectValue!
        for (key, entry) in partitions where entry.at(path: "space_key") == .string("display-A/space-A") {
            var partition = entry.objectValue!
            var local = partition["arrangement"]!.objectValue!
            local["bindings"] = .object(memberBindings)
            partition["arrangement"] = .object(local); partitions[key] = .object(partition)
        }
        cache["partitions"] = .object(partitions); memberModel["space_partitions"] = .object(cache)
        let stacked = member.server.applyWorldDelta(["event": .string("fixture_overload_member"), "model_state": .object(memberModel)])
        _ = member.waitForProcessed(stacked.revision.value)
        let target = ResidentSpaceTarget(spaceKey: "display-A/space-A", displayId: "display-A")
        let memberAction = ResidentMenuAction(actionID: "window.select",
            arguments: .object(["window_id": .int(4), "expected_pid": .int(504), "expected_window_generation": .int(1),
                "expected_observer_epoch": member.server.worldState.at(path: "observer_epoch")!]),
            target: target, expectedRevision: member.server.currentRevision)
        _ = member.server.applyWorldDelta(["event": .string("fixture_focus_tracking_update")])
        _ = member.controller.handleMenuAction(memberAction, requestID: "select-member")
        let selected = member.result("select-member")
        test.check(selected?.at(path: "status")?.stringValue == "accepted" && selected?.at(path: "focus_confirmed")?.boolValue == true
            && member.server.worldState.at(path: "focus.window_id") == .int(4)
            && member.port.issued.last?.requiresFocus == true,
            "product/menu-reframes-and-focuses-exact-obscured-member-after-unrelated-tracking-revision")
        var driftedWindows = member.server.worldState.at(path: "windows")!.arrayValue!
        let driftedIndex = driftedWindows.firstIndex { $0.at(path: "window_id") == .int(4) }!
        var drifted = driftedWindows[driftedIndex].objectValue!
        let oldFrame = Frame.from(drifted["frame"])!
        drifted["frame"] = Frame(x: oldFrame.x + 20, y: oldFrame.y, w: oldFrame.w, h: oldFrame.h).json
        driftedWindows[driftedIndex] = .object(drifted)
        let drift = member.server.applyWorldDelta(["event": .string("fixture_unsettled_geometry"), "windows": .array(driftedWindows)])
        _ = member.waitForProcessed(drift.revision.value)
        let regutter = ResidentMenuAction(actionID: "layout.regutter", arguments: .object([:]),
            target: target, expectedRevision: member.server.currentRevision)
        _ = member.controller.handleMenuAction(regutter, requestID: "regutter-original-space")
        let regutterResult = member.result("regutter-original-space")
        let regutterRequest = member.port.issued.last(where: { $0.requestID == "regutter-original-space" })
        if regutterResult?.at(path: "status")?.stringValue != "accepted" || regutterRequest == nil {
            print("regutter-diagnostic: " + (regutterResult?.canonical() ?? "missing")
                + " issued=" + member.port.issued.map(\.requestID).joined(separator: ","))
        }
        test.check(regutterResult?.at(path: "status")?.stringValue == "accepted"
            && regutterResult?.at(path: "verified_nanos")?.intValue != nil
            && regutterRequest != nil
            && regutterRequest?.windowSpaceKeys.values.allSatisfy { $0 == target.spaceKey } == true,
            "product/menu-regutter-routes-through-native-verified-effect-on-original-space-only")
        let badAction = ResidentMenuAction(actionID: "window.select", arguments: .object(["window_id": .int(4), "expected_pid": .int(999)]),
            target: target, expectedRevision: member.server.currentRevision)
        let issueCount = member.port.issued.count
        _ = member.controller.handleMenuAction(badAction, requestID: "select-stale-member")
        test.check(member.result("select-stale-member")?.at(path: "reason")?.stringValue == "menu_window_lifetime_changed"
            && member.port.issued.count == issueCount, "product/menu-lifetime-change-refuses-before-any-external-write")

        var historyState = member.server.worldState.at(path: "model_state")!.objectValue!
        historyState["focus_history"] = product.at(path: "history_seed")
        historyState["confirmed_focus_window_id"] = .int(1)
        let seeded = member.server.applyWorldDelta(["event": .string("fixture_history_seed"), "model_state": .object(historyState)])
        _ = member.waitForProcessed(seeded.revision.value)
        let fresh = ResidentMenuAction(actionID: "window.select", arguments: .object(["window_id": .int(2)]), target: target,
            expectedRevision: member.server.currentRevision)
        _ = member.controller.handleMenuAction(fresh, requestID: "history-focus")
        _ = member.result("history-focus")
        let historyReady = wait { member.server.worldState.at(path: "model_state.confirmed_focus_window_id") == .int(2) }
        _ = member.act("resize.start", id: "history-new-mode"); let historyMode = member.result("history-new-mode")
        let quiet = DispatchSemaphore(value: 0); member.controller.whenIOQuiescent { quiet.signal() }
        _ = quiet.wait(timeout: .now() + .seconds(2))
        let checkpoint = try member.journal.recoverCheckpoint()
        let history = member.server.worldState.at(path: "model_state.focus_history")?.arrayValue ?? []
        let historyPassed = historyReady && history.count == Int(product.at(path: "history_depth")!.intValue!)
            && Set(history.compactMap { $0.at(path: "window_id")?.intValue }).count == history.count
            && history.first?.at(path: "window_id") == .int(2) && history.first?.at(path: "pid") == .int(502)
            && checkpoint.state?.at(path: "focus_history") == .array(history)
            && member.server.worldState.at(path: "model_state.interaction.mode") == .string("resize")
        if !historyPassed {
            let diagnostic: JSONValue = .object(["ready": .bool(historyReady), "history": .array(history),
                "mode_result": historyMode ?? .null, "checkpoint": checkpoint.state ?? .null,
                "model": member.server.worldState.at(path: "model_state") ?? .null])
            print("diagnostic product-history \(diagnostic.canonical())")
        }
        test.check(historyPassed,
            "product/confirmed-focus-history-is-typed-deduplicated-bounded-durable-and-preserves-new-mode")

        for manual in [false, true] {
            var specimen = fixture.objectValue!, world = fixture.at(path: "world")!.objectValue!
            let clampID = product.at(path: manual ? "manual_clamp_window_id" : "automatic_clamp_window_id")!.intValue!
            world["windows"] = .array(world["windows"]!.arrayValue!.map { value -> JSONValue in
                var row = value.objectValue!
                if row["window_id"]?.intValue == clampID { row["app"] = product.at(path: "minimum_application") }
                return .object(row)
            })
            specimen["world"] = .object(world)
            let clamp = try ResidentCommandsRig(fixture: .object(specimen))
            clamp.port.emitMinimumEvidence = true; clamp.port.confirmMinimumClamps = true; clamp.port.hold(true)
            if manual { _ = preparePreview(clamp, prefix: "clamped-preview") }
            else { _ = clamp.act("resize.start", id: "clamped-resize-start"); _ = clamp.result("clamped-resize-start") }
            let action = manual ? product.at(path: "preview_commit")!.stringValue! : "resize.adjust.east"
            _ = clamp.act(action, id: "clamped-original")
            guard clamp.port.waitForIssues(1), let request = clamp.port.issued.first,
                  let targetFrame = request.frameTargets[String(clampID)],
                  let before = clamp.server.worldState.at(path: "windows")?.arrayValue?.first(where: {
                      $0.at(path: "window_id")?.intValue == clampID
                  }).flatMap({ Frame.from($0.at(path: "frame")) }),
                  before.w > targetFrame.w + 8 || before.h > targetFrame.h + 8 else {
                test.check(false, "product/clamp-fixture-requires-genuine-size-shrink-\(manual)"); continue
            }
            let widthClamp = before.w > targetFrame.w + 8
            let axis = widthClamp ? "w" : "h"
            var landed = targetFrame
            if widthClamp { landed.w = ((before.w + targetFrame.w) / 2).rounded() }
            else { landed.h = ((before.h + targetFrame.h) / 2).rounded() }
            let floor = widthClamp ? landed.w : landed.h
            if widthClamp { clamp.port.minimumWidthOverrides = [String(clampID): floor] }
            else { clamp.port.minimumHeightOverrides = [String(clampID): floor] }
            clamp.port.hold(false); clamp.port.release(request.requestID)
            let failed = clamp.result("clamped-original")
            let learned = wait { clamp.server.worldState.at(path: "model_state.minimum_sizes")?.objectValue?[product.at(path: "minimum_application")!.stringValue!]?.at(path: axis)?.numberValue == floor }
            test.check(learned && failed?.at(path: "status")?.stringValue == "failed"
                && failed?.at(path: "reason")?.stringValue == "minimum_constraint" && failed?.at(path: "verified_nanos") == .null,
                "product/confirmed-clamp-journals-exact-current-floor-and-preserves-honest-original-result-\(manual)")
            if manual {
                let replacementReady = wait { clamp.controller.health.at(path: "minimum_learning_status") == .string("move_preview_replaced_requires_confirmation") }
                test.check(replacementReady && clamp.port.issued.count == 1
                    && clamp.server.worldState.at(path: "model_state.interaction.candidate") != nil
                    && clamp.server.worldState.at(path: "model_state.arrangement") == request.priorInteraction?.at(path: "candidate.base.arrangement")
                    && clamp.result("clamped-original") == failed,
                    "product/manual-clamp-publishes-replacement-intent-preview-without-AX-rollback-or-auto-confirm")
            } else {
                let replanned = clamp.result("minimum-replan:clamped-original")
                let boundedReplan = replanned?.at(path: "status")?.stringValue == "accepted"
                    && replanned?.at(path: "verified_nanos")?.intValue != nil && clamp.port.issued.count == 2
                    && clamp.result("clamped-original") == failed
                if !boundedReplan {
                    let diagnostic: JSONValue = .object([
                        "original_result": failed ?? .null, "child_terminal_result": replanned ?? .null,
                        "child_current_result": ServeClient.request(socketPath: clamp.socketPath,
                            body: ["op": .string("result"), "request_id": .string("minimum-replan:clamped-original")]) ?? .null,
                        "issued": .array(clamp.port.issued.map { request in .object([
                            "request_id": .string(request.requestID), "frame_targets": .object(JSONObject(unordered: request.frameTargets.mapValues(\.json)))]) }),
                        "actual_windows": clamp.server.worldState.at(path: "windows") ?? .null,
                        "model_state": clamp.server.worldState.at(path: "model_state") ?? .null,
                        "controller_health": clamp.controller.health])
                    print("diagnostic product-automatic-clamp \(diagnostic.canonical())")
                }
                test.check(boundedReplan,
                    "product/automatic-clamp-uses-one-bounded-replan-and-never-rewrites-original-failed-result")
            }
        }
    } catch { test.check(false, "product/native-integration-fixture: \(error)") }
}


/// Real lifecycle publications traverse controller planning, native journal,
/// compound effects and matching readback. Direct planner calls cannot certify it.
private func runReactiveLifecycleRefocusScenarios(fixture sourceFixture: JSONValue, test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/resident_commands/reactive_lifecycle_refocus.json"
    guard let bytes = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(bytes),
          let cases = fixture.at(path: "cases")?.arrayValue else {
        test.check(false, "reactive-lifecycle/fixture-load"); return
    }
    test.check(cases.count == 8 && Set(cases.compactMap { $0.at(path: "name")?.stringValue }).count == 8,
        "reactive-lifecycle/eight-explicit-integration-cases")
    func traceEvents(after start: UInt64) -> [JSONValue] {
        var cursor = start, result: [JSONValue] = []
        for _ in 0..<32 {
            let page = ResidentPerformanceTrace.shared.snapshot(from: cursor, limit: 128)
            guard let events = page.at(path: "events")?.arrayValue, !events.isEmpty else { break }
            result.append(contentsOf: events)
            guard let next = events.last?.at(path: "sequence")?.intValue, next > 0, UInt64(next) > cursor else { break }
            cursor = UInt64(next)
            if cursor >= UInt64(max(0, page.at(path: "last_sequence")?.intValue ?? 0)) { break }
        }
        return result
    }
    func makeFixture(_ row: JSONValue) -> JSONValue {
        var value = sourceFixture.objectValue!, world = sourceFixture.at(path: "world")!.objectValue!
        let generation = world["observer_generation"]!
        var windows = world["windows"]!.arrayValue!.map { raw -> JSONValue in
            var window = raw.objectValue!; window["managed"] = .bool(true); window["observer_generation"] = generation
            return .object(window)
        }
        if row.at(path: "store")?.stringValue != "two" {
            var extra = windows.first { $0.at(path: "window_id") == .int(2) }!.objectValue!
            for (key, field) in fixture.at(path: "extra_window")!.objectValue! { extra[key] = field }
            windows.append(.object(extra))
            var store = fixture.at(path: "three_cell_store")!.objectValue!
            if row.at(path: "store")?.stringValue == "pinned-three" {
                store["segments"] = .array(store["segments"]!.arrayValue!.map { raw in
                    var segment = raw.objectValue!; segment["relation"] = .string("pinned"); return .object(segment)
                })
            }
            value["store"] = .object(store)
        }
        world["windows"] = .array(windows)
        world["focus"] = windows.first { $0.at(path: "window_id") == .int(1) }!
        value["world"] = .object(world)
        return .object(value)
    }
    func quiet(_ rig: ResidentCommandsRig) -> Bool {
        let completed = DispatchSemaphore(value: 0)
        rig.controller.whenIOQuiescent { completed.signal() }
        return completed.wait(timeout: .now() + .seconds(3)) == .success
    }
    func nativeTopology(_ rig: ResidentCommandsRig) -> JSONValue {
        .object(["displays": .array(rig.initialWorld.at(path: "topology")!.arrayValue!.map { raw in
            var display = raw.objectValue!; display["usable"] = display["usable_frame"]; return .object(display)
        }), "gap": sourceFixture.at(path: "gap")!, "outer_gap": sourceFixture.at(path: "outer_gap")!])
    }
    for row in cases {
        let name = row.at(path: "name")!.stringValue!
        do {
            let traceStart = UInt64(max(0, ResidentPerformanceTrace.shared.snapshot().at(path: "last_sequence")?.intValue ?? 0))
            let rig = try ResidentCommandsRig(fixture: makeFixture(row))
            guard quiet(rig) else { test.check(false, "reactive-lifecycle/\(name)-bootstrap-quiescence"); continue }
            var state = rig.server.worldState.at(path: "model_state")!.objectValue!
            state["confirmed_focus_window_id"] = row.at(path: "confirmed_focus")
            state["focus_history"] = row.at(path: "history")
            var seed: JSONObject = ["event": .string("fixture_reactive_focus_history")]
            if row.at(path: "store")?.stringValue != "two" {
                // A fresh native partition intentionally authors its own cold layout.
                // Supply the independently declared three-cell scene in both the
                // observed world and existing valid partition, not just an ignored seed.
                var store = fixture.at(path: "three_cell_store")!.objectValue!
                if row.at(path: "store") == .string("pinned-three") {
                    store["segments"] = .array(store["segments"]!.arrayValue!.map { raw in
                        var segment = raw.objectValue!; segment["relation"] = .string("pinned"); return .object(segment)
                    })
                }
                let arrangement = Arrangement.bridgeArrangementNative(store: .object(store), topo: nativeTopology(rig))
                state["arrangement"] = arrangement
                var cache = state["space_partitions"]!.objectValue!, entries = cache["partitions"]!.objectValue!
                for (key, raw) in entries where raw.at(path: "space_key") == .string("display-A/space-A") {
                    var entry = raw.objectValue!; entry["arrangement"] = arrangement; entries[key] = .object(entry)
                }
                cache["partitions"] = .object(entries); state["space_partitions"] = .object(cache)
                let observed = rig.server.worldState.at(path: "windows")!.arrayValue!.map { raw -> JSONValue in
                    var window = raw.objectValue!
                    if let id = window["window_id"]?.intValue,
                       let frame = fixture.at(path: "three_cell_frames")?.objectValue?[String(id)] { window["frame"] = frame }
                    return .object(window)
                }
                seed["windows"] = .array(observed); seed["focus"] = observed.first { $0.at(path: "window_id") == .int(1) }
            }
            seed["model_state"] = .object(state)
            let seeded = rig.server.applyWorldDelta(seed)
            guard rig.waitForProcessed(seeded.revision.value), quiet(rig) else {
                test.check(false, "reactive-lifecycle/\(name)-seed-processing"); continue
            }
            if let expected = row.at(path: "expected_absorber") {
                let proof = Arrangement.pruneAllocatedWindow(store: rig.server.worldState.at(path: "model_state.arrangement")!,
                    windowID: row.at(path: "notification_window_id")!.intValue!, topo: nativeTopology(rig), focused: nil)
                test.check(proof?.at(path: "absorber") == expected,
                    "reactive-lifecycle/\(name)-independent-fixture-proves-absorber-before-real-event")
            }
            let issuedBefore = rig.port.issued.count
            let event = row.at(path: "event")!.stringValue!
            let removed = Set(row.at(path: "removed_ids")!.arrayValue!.compactMap(\.intValue))
            let windows = rig.server.worldState.at(path: "windows")!.arrayValue!.compactMap { raw -> JSONValue? in
                guard let id = raw.at(path: "window_id")?.intValue, removed.contains(id) else { return raw }
                if event == "ax_window_destroyed" { return nil }
                var window = raw.objectValue!; window["minimized"] = .bool(true); return .object(window)
            }
            let currentFocus = row.at(path: "current_focus")?.intValue.flatMap { id in
                windows.first { $0.at(path: "window_id")?.intValue == id }
            } ?? .null
            let notificationReceipt = DispatchTime.now().uptimeNanoseconds
            var delta: JSONObject = ["event": .string(event), "windows": .array(windows), "focus": currentFocus,
                "notification_window_id": row.at(path: "notification_window_id")!,
                "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "failure_code": .null,
                    "reason": .string(event)])]
            if row.at(path: "omit_notification_receipt")?.boolValue != true {
                delta["notification_receipt_uptime_ns"] = .int(Int64(clamping: notificationReceipt))
            }
            let publication = rig.server.applyWorldDelta(delta)
            let expectedReceipt = row.at(path: "omit_notification_receipt")?.boolValue == true
                ? rig.publications.receipt(for: publication.revision.value) : notificationReceipt
            guard let expectedReceipt, let result = rig.publications.waitForInternalReconcile(after: expectedReceipt-1),
                  let requestID = result.at(path: "request_id")?.stringValue else {
                test.check(false, "reactive-lifecycle/\(name)-real-reactive-completion"); continue
            }
            let quiet = DispatchSemaphore(value: 0); rig.controller.whenIOQuiescent { quiet.signal() }
            _ = quiet.wait(timeout: .now() + .seconds(2))
            let requests = Array(rig.port.issued.dropFirst(issuedBefore))
            let requiresFocus = row.at(path: "requires_focus")!.boolValue!
            let expectedFocus = row.at(path: "expected_focus")?.intValue
            let focusedRequests = requests.filter { $0.effectKind == .focus || $0.requiresFocus }
            let succeeded = ["accepted", "noop"].contains(result.at(path: "status")?.stringValue ?? "")
            let focusPassed: Bool
            if requiresFocus {
                focusPassed = succeeded && focusedRequests.count == 1
                    && focusedRequests.first?.windowID == expectedFocus.map(String.init)
                    && result.at(path: "focus_confirmed")?.boolValue == true
                    && result.at(path: "verified_nanos")?.intValue != nil
                    && rig.server.worldState.at(path: "focus.window_id")?.intValue == expectedFocus
            } else {
                focusPassed = succeeded && focusedRequests.isEmpty
                    && rig.server.worldState.at(path: "focus.window_id") == currentFocus.at(path: "window_id")
            }
            if !focusPassed {
                print("reactive-lifecycle-diagnostic \(name) result=\(result.canonical()) issued=\(requests.map { $0.windowID + ":" + String($0.requiresFocus) }.joined(separator: ","))")
            }
            test.check(focusPassed, "reactive-lifecycle/\(name)-native-journal-effect-and-readback-focus-rule")
            let checkpoint = try rig.journal.recoverCheckpoint()
            let remaining = Set((rig.server.worldState.at(path: "windows")?.arrayValue ?? []).filter {
                $0.at(path: "space_enabled")?.boolValue == true && $0.at(path: "minimized")?.boolValue != true
            }.compactMap { $0.at(path: "window_id")?.intValue })
            let topology = rig.initialWorld.at(path: "topology")!.arrayValue!
            let nativeTopology: JSONValue = .object(["displays": .array(topology.map { raw in
                var display = raw.objectValue!; display["usable"] = display["usable_frame"]; return .object(display)
            }), "gap": sourceFixture.at(path: "gap")!, "outer_gap": sourceFixture.at(path: "outer_gap")!])
            let model = rig.server.worldState.at(path: "model_state.arrangement") ?? .null
            test.check(Set(Arrangement.allocatedWindowIDs(model, topo: nativeTopology)) == remaining
                && checkpoint.state?.at(path: "arrangement") == model,
                "reactive-lifecycle/\(name)-removed-member-pruned-and-survivors-durably-conserved")
            let traces = traceEvents(after: traceStart)
            let admissions = traces.filter { $0.at(path: "kind") == .string("admission") && $0.at(path: "request_id") == .string(requestID) }
            let commits = traces.filter { $0.at(path: "kind") == .string("plan_committed") && $0.at(path: "request_id") == .string(requestID) }
            let expectedCause = event == "ax_window_minimized" ? "window.minimized" : "window.destroyed"
            test.check(admissions.count == 1 && commits.count == 1
                && admissions[0].at(path: "uptime_ns") == .int(Int64(clamping: expectedReceipt))
                && admissions[0].at(path: "source_receipt_uptime_ns") == .int(Int64(clamping: expectedReceipt))
                && admissions[0].at(path: "source_event") == .string(event)
                && admissions[0].at(path: "source_event_revision") == .int(Int64(clamping: publication.revision.value))
                && admissions[0].at(path: "source_notification_window_id") == row.at(path: "notification_window_id")
                && admissions[0].at(path: "lifecycle_causes")?.arrayValue?.contains(.string(expectedCause)) == true
                && commits[0].at(path: "source_receipt_uptime_ns") == admissions[0].at(path: "source_receipt_uptime_ns"),
                "reactive-lifecycle/\(name)-one-admission-joins-original-event-receipt-and-committed-plan")
            let bootstrapAdmissions = traces.filter { $0.at(path: "kind") == .string("admission") && $0.at(path: "request_id") == .string("fixture-bootstrap") }
            test.check(bootstrapAdmissions.count == 1, "reactive-lifecycle/\(name)-explicit-bootstrap-not-double-admitted")
        } catch { test.check(false, "reactive-lifecycle/\(name)-fixture-error: \(error)") }
    }
    do {
        let gate = ResidentCommandsStateOnlyJournalGate(actionID: "world.reconcile", active: false)
        let marker = UInt64(max(0, ResidentPerformanceTrace.shared.snapshot().at(path: "last_sequence")?.intValue ?? 0))
        let rig = try ResidentCommandsRig(fixture: makeFixture(cases[0]), stateOnlyAppend: { try gate.append($0, journal: $1) })
        defer { gate.permit.signal() }
        var model = rig.server.worldState.at(path: "model_state")!.objectValue!
        model["confirmed_focus_window_id"] = cases[0].at(path: "confirmed_focus")
        model["focus_history"] = cases[0].at(path: "history")
        model.removeValue(forKey: "space_partitions")
        let seeded = rig.server.applyWorldDelta(["event": .string("fixture_batched_focus_history"), "model_state": .object(model)])
        _ = rig.waitForProcessed(seeded.revision.value); _ = quiet(rig)
        gate.arm(); rig.controller.reconcile(requestID: "hold-reactive-planning")
        guard gate.entered.wait(timeout: .now() + .seconds(2)) == .success else {
            test.check(false, "reactive-lifecycle/batch-real-journal-boundary-held"); return
        }
        var windows = rig.server.worldState.at(path: "windows")!.arrayValue!
        var newcomer = windows.first { $0.at(path: "window_id") == .int(2) }!.objectValue!
        for (key, field) in fixture.at(path: "extra_window")!.objectValue! { newcomer[key] = field }
        windows.append(.object(newcomer))
        let firstReceipt = DispatchTime.now().uptimeNanoseconds
        let created = rig.server.applyWorldDelta(["event": .string("ax_window_created"), "windows": .array(windows),
            "notification_window_id": fixture.at(path: "extra_window.window_id")!,
            "notification_receipt_uptime_ns": .int(Int64(clamping: firstReceipt))])
        let closeReceipt = DispatchTime.now().uptimeNanoseconds
        let closed = rig.server.applyWorldDelta(["event": .string("ax_window_destroyed"),
            "windows": .array(windows.filter { $0.at(path: "window_id") != .int(1) }), "focus": .null,
            "notification_window_id": .int(1), "notification_receipt_uptime_ns": .int(Int64(clamping: closeReceipt))])
        gate.permit.signal()
        guard let result = rig.publications.waitForInternalReconcile(after: firstReceipt-1),
              let requestID = result.at(path: "request_id")?.stringValue else {
            test.check(false, "reactive-lifecycle/batch-real-reconciliation-completes"); return
        }
        let events = traceEvents(after: marker)
        let admission = events.filter { $0.at(path: "kind") == .string("admission") && $0.at(path: "request_id") == .string(requestID) }
        let captured = admission.first?.at(path: "source_events")?.arrayValue ?? []
        test.check(result.at(path: "status") == .string("accepted") && result.at(path: "focus_confirmed") == .bool(true)
            && rig.server.worldState.at(path: "focus.window_id") == .int(2),
            "reactive-lifecycle/coalesced-created-then-destroyed-retains-real-close-refocus")
        test.check(admission.count == 1 && captured.count == 2
            && captured[0].at(path: "source_event_revision") == .int(Int64(clamping: created.revision.value))
            && captured[0].at(path: "source_event_receipt_uptime_ns") == .int(Int64(clamping: firstReceipt))
            && captured[1].at(path: "source_event_revision") == .int(Int64(clamping: closed.revision.value))
            && captured[1].at(path: "source_event_receipt_uptime_ns") == .int(Int64(clamping: closeReceipt))
            && admission[0].at(path: "lifecycle_causes")?.arrayValue?.contains(.string("window.destroyed")) == true,
            "reactive-lifecycle/bounded-coalescing-keeps-both-original-event-receipts-and-lifecycle-cause")
    } catch { test.check(false, "reactive-lifecycle/coalesced-source-fixture: \(error)") }
    do {
        let marker = UInt64(max(0, ResidentPerformanceTrace.shared.snapshot().at(path: "last_sequence")?.intValue ?? 0))
        let rig = try ResidentCommandsRig(fixture: sourceFixture)
        let completion = ResidentCommandsStartupResult()
        rig.controller.reconcile(requestID: "trace-explicit-startup", completion: { completion.record($0) })
        let completed = completion.delivered.wait(timeout: .now() + .seconds(3)) == .success
        _ = rig.act("nav.focus.east", id: "trace-explicit-handle")
        let handled = rig.result("trace-explicit-handle")
        _ = rig.act("nav.focus.east", id: "trace-explicit-handle")
        let events = traceEvents(after: marker)
        test.check(completed && events.filter { $0.at(path: "kind") == .string("admission")
            && $0.at(path: "request_id") == .string("trace-explicit-startup") }.count == 1,
            "reactive-lifecycle/explicit-readiness-reconcile-has-one-admission")
        test.check(handled?.at(path: "status") == .string("accepted") && events.filter {
            $0.at(path: "kind") == .string("admission") && $0.at(path: "request_id") == .string("trace-explicit-handle")
        }.count == 1, "reactive-lifecycle/handled-command-and-idempotent-replay-have-one-admission")
    } catch { test.check(false, "reactive-lifecycle/explicit-admission-fixture: \(error)") }
}

private final class ResidentCommandsModeInputBox: @unchecked Sendable {
    weak var input: ResidentInput?
}

/// Real routing/mode publications plus native focus history must not revive ghost geometry.
private func runResidentModeReleasePublicationScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        var positive = fixture.objectValue!, world = fixture.at(path: "world")!.objectValue!
        let generation = world["observer_generation"]!
        world["windows"] = .array(world["windows"]!.arrayValue!.map { value in
            var row = value.objectValue!; row["managed"] = .bool(true); row["observer_generation"] = generation
            return .object(row)
        })
        var focus = world["focus"]!.objectValue!
        focus["managed"] = .bool(true); focus["observer_generation"] = generation
        world["focus"] = .object(focus); positive["world"] = .object(world)
        let rig = try ResidentCommandsRig(fixture: .object(positive))
        for (action, id) in [("move.start", "release-move-start"), ("move.cursor.east", "release-move-cursor"), ("move.drop", "release-move-stage")] {
            _ = rig.act(action, id: id)
            guard rig.result(id)?.at(path: "status") == .string("accepted") else {
                test.check(false, "mode-release/native-move-preview-fixture-required"); return
            }
        }
        let staged = rig.server.committedSnapshot
        let stagedFrames = staged.world.at(path: "windows")!.arrayValue!.map { $0.at(path: "frame") }
        let stagedArrangement = staged.world.at(path: "model_state.arrangement")
        test.check(staged.borderPlan.previewCandidateID != nil && staged.borderPlan.rings.contains { $0.stroke == .dashed }
            && rig.port.writeCount == 0, "mode-release/reproduction-has-real-staged-ghosts-and-zero-window-writes")

        // A provisional keyboard exit deliberately retains the staged model for Escape's rc3.
        // Focus completion/history may update that checkpoint but must not author its mode.
        let provisional = rig.server.applyModeFrame(.init(type: .snapshot, epoch: "release-history-fixture",
            sequence: 0, mode: "default"))
        _ = rig.waitForProcessed(provisional.revision.value)
        let retained = rig.server.worldState.at(path: "model_state.interaction.mode") == .string("move")
        _ = rig.act("nav.focus.east", id: "release-history-focus")
        let navigated = rig.result("release-history-focus")
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline,
              rig.server.worldState.at(path: "model_state.confirmed_focus_window_id") != .int(2) { usleep(500) }
        let recorded = rig.server.committedSnapshot
        test.check(retained && navigated?.at(path: "status") == .string("accepted")
            && recorded.world.at(path: "model_state.confirmed_focus_window_id") == .int(2)
            && recorded.world.at(path: "mode") == .string("default")
            && recorded.world.at(path: "mode_context_window_id") == .null
            && recorded.borderPlan.previewCandidateID == nil
            && !recorded.borderPlan.rings.contains { $0.stroke == .dashed }
            && recorded.world.at(path: "model_state.arrangement") == stagedArrangement && rig.port.writeCount == 0,
            "mode-release/focus-only-completion-and-journaled-focus-history-cannot-resurrect-staged-mode-or-ghosts")

        // Forced release uses the real atomic mailbox-contention path and current-generation guard.
        let box = ResidentCommandsModeInputBox(), sequence = ResidentAtomic<UInt64>(0)
        guard let input = try? ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { _, complete in complete(0) },
            onModeChanged: { mode, inputGeneration, reset in
                let next = sequence.load(ordering: .acquiring) + 1
                let publication = rig.server.applyModeFrame(.init(type: .changed, epoch: "release-history-fixture",
                    sequence: Int64(clamping: next), mode: mode, resetsInteraction: reset, inputGeneration: inputGeneration), commitGuard: { [box] in
                        box.input?.routing.generation == inputGeneration ? nil : "input_generation_released"
                    })
                if publication.status == .accepted { sequence.store(next, ordering: .releasing) }
                return publication.status == .accepted
            }) else { test.check(false, "mode-release/native-routing-required"); return }
        box.input = input
        _ = input.inject(chord: "cmd + ctrl + alt + shift - m"); input.routing.flushForSelfTest()
        input.routing.withMailboxLockForSelfTest { input.releaseModal(reason: "external_context_invalidated") }
        input.routing.flushForSelfTest()
        let cleared = rig.server.committedSnapshot
        _ = rig.waitForProcessed(cleared.revision)
        test.check(input.routing.mode == "default" && cleared.world.at(path: "mode") == .string("default")
            && cleared.world.at(path: "model_state.interaction") == nil
            && cleared.world.at(path: "mode_context_window_id") == .null
            && cleared.borderPlan.previewCandidateID == nil
            && cleared.world.at(path: "windows")!.arrayValue!.map { $0.at(path: "frame") } == stagedFrames
            && cleared.world.at(path: "model_state.arrangement") == stagedArrangement && rig.port.writeCount == 0,
            "mode-release/forced-release-atomically-clears-canonical-interaction-and-projection-without-window-mutations")
        let refused = rig.server.applyModeFrame(.init(type: .changed, epoch: "release-history-fixture",
            sequence: Int64(clamping: sequence.load(ordering: .acquiring) + 1), mode: "move"), commitGuard: { "input_generation_released" })
        test.check(refused.status == .refused && rig.server.currentRevision == cleared.revision
            && rig.server.worldState.at(path: "mode") == .string("default"),
            "mode-release/authority-boundary-rejects-delayed-stale-mode-before-cursor-or-revision-advances")
    } catch { test.check(false, "mode-release/native-publication-fixture: \(error)") }
}

private final class ResidentCommandsKeyboardFeedback: @unchecked Sendable {
    struct Entry { let action: String; let rc: Int }
    private let condition = NSCondition()
    private var entries: [Entry] = []
    func record(_ action: String, _ rc: Int) { condition.lock(); entries.append(.init(action: action, rc: rc)); condition.broadcast(); condition.unlock() }
    var count: Int { condition.lock(); defer { condition.unlock() }; return entries.count }
    func wait(after count: Int) -> Entry? {
        condition.lock(); defer { condition.unlock() }; let deadline = Date(timeIntervalSinceNow: 3)
        while entries.count <= count { if !condition.wait(until: deadline) { return nil } }
        return entries.last
    }
}

/// Keyboard predicates consume the actual controller's return code, not a fake rc0 handler.
private func runResidentKeyboardMoveContinuationScenarios(fixture: JSONValue, test: inout SelfTest) {
    do {
        let rig = try ResidentCommandsRig(fixture: fixture)
        let box = ResidentCommandsModeInputBox(), sequence = ResidentAtomic<UInt64>(0)
        let feedback = ResidentCommandsKeyboardFeedback(), epoch = "keyboard-move-continuation"
        _ = rig.server.applyModeFrame(.init(type: .snapshot, epoch: epoch, sequence: 0, mode: "default", resetsInteraction: true))
        guard let input = try? ResidentInput.load(home: responsivenessRepositoryRoot(), dispatchAction: { action, complete in
            if ["move.cancel", "move.off", "resize.off"].contains(action.actionId) { rig.controller.invalidate(cause: "cancel") }
            rig.controller.dispatch(action) { rc in complete(rc); feedback.record(action.actionId, rc) }
        }, onModeChanged: { mode, generation, reset in
            let next = sequence.load(ordering: .acquiring) + 1
            let result = rig.server.applyModeFrame(.init(type: .changed, epoch: epoch, sequence: Int64(clamping: next),
                mode: mode, resetsInteraction: reset, inputGeneration: generation),
                commitGuard: { box.input?.routing.generation == generation ? nil : "input_generation_released" })
            guard result.status == .accepted else { return false }
            sequence.store(next, ordering: .releasing)
            if mode == "default" { rig.controller.invalidate(cause: "cancel") }
            return true
        }) else { test.check(false, "keyboard-move/actual-routing-required"); return }
        box.input = input
        rig.controller.setInputGenerationReader { box.input?.routing.generation }
        func key(_ chord: String) -> ResidentCommandsKeyboardFeedback.Entry? {
            let count = feedback.count
            guard input.inject(chord: chord) == .claimed else { return nil }
            let reply = feedback.wait(after: count); input.routing.flushForSelfTest(); return reply
        }
        guard key("cmd + ctrl + alt + shift - m")?.rc == 0, key("l")?.rc == 0 else {
            test.check(false, "keyboard-move/native-entry-and-cursor-required"); return
        }
        let staged = key("d")
        test.check(staged?.action == "move.drop" && staged?.rc == 3 && input.routing.mode == "move"
            && rig.server.worldState.at(path: "model_state.interaction.staged_edge")?.stringValue != nil
            && rig.port.writeCount == 0,
            "keyboard-move/first-D-stages-with-rc3-and-keeps-real-bare-key-claims")
        let rotated = key("c"), widened = key("u"), narrowed = key("i")
        test.check(rotated?.rc == 0 && widened?.rc == 3 && narrowed?.rc == 3 && input.routing.mode == "move"
            && rig.server.worldState.at(path: "mode") == .string("move") && rig.port.writeCount == 0,
            "keyboard-move/C-U-I-accepted-selection-changes-retain-real-mode-with-correct-predicate-return-codes")
        let partial = key("0x35")
        test.check(partial?.action == "move.cancel" && partial?.rc == 3 && input.routing.mode == "move"
            && rig.server.worldState.at(path: "model_state.interaction.staged_edge") == .null,
            "keyboard-move/first-Escape-reaches-controller-unstages-and-retains-mode")
        let final = key("0x35")
        test.check(final?.rc == 0 && input.routing.mode == "default"
            && rig.server.worldState.at(path: "model_state.interaction") == nil && rig.port.writeCount == 0,
            "keyboard-move/second-Escape-clears-interaction-and-exits-without-window-writes")
        _ = key("cmd + ctrl + alt + shift - m"); _ = key("l"); _ = key("d")
        let hard = input.inject(chord: "0x5A"); input.routing.flushForSelfTest()
        test.check(hard == .claimed && input.routing.mode == "default"
            && rig.server.worldState.at(path: "mode") == .string("default")
            && rig.server.worldState.at(path: "model_state.interaction") == nil && rig.port.writeCount == 0,
            "keyboard-move/generic-hard-exit-clears-transient-state-without-a-dispatched-cancel-action")
        _ = key("cmd + ctrl + alt + shift - m"); _ = key("l")
        let preview = key("d"), confirmed = key("d")
        test.check(preview?.rc == 3 && confirmed?.rc == 0 && input.routing.mode == "default"
            && rig.server.worldState.at(path: "model_state.interaction") == nil && rig.port.writeCount > 0,
            "keyboard-move/second-D-confirms-real-effects-and-exits-after-accepted-completion")
    } catch { test.check(false, "keyboard-move/actual-controller-fixture: \(error)") }
}
