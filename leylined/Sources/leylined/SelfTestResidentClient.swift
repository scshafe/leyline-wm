// Real temp Unix sockets with fake registered handlers; no tap, AppKit, AX,
// subprocess or deployed resident binary is used by these client checks.
import Darwin
import Foundation
import LeylineModel

private enum ResidentClientFixtureMode: Sendable {
    case completedAfterResultRead, fastCompletion, unrelatedThenCompletion
    case noCompletion, closeWithoutCompletion, refusal
    case wrongReplyIdentity
}

private final class ResidentClientServerFixture: @unchecked Sendable {
    let path: String
    let server: CoreServer
    private let lock = NSLock()
    private let responses: JSONObject
    private let mode: ResidentClientFixtureMode
    private var requests: [JSONObject] = []
    private var result: JSONValue
    private var scheduled = false
    private let producer = DispatchQueue(label: "leylined.client.fixture.result")

    init(path: String, responses: JSONObject, mode: ResidentClientFixtureMode) {
        self.path = path; self.responses = responses; self.mode = mode
        result = responses["admitted"]!
        server = CoreServer(socketPath: path)
        server.configureCommands(actionIDs: ["nav.focus.west"], handler: { [weak self] request in
            self?.handle(request) ?? .object(["ok": .bool(false), "reason": .string("fixture_stopped")])
        })
    }

    func start() -> Bool {
        _ = server.applyWorldDelta(["event": .string("world_seed"), "focus": .null,
            "windows": .array([]), "observation": .object(["world_complete": .bool(true), "synthetic": .bool(true)])])
        return server.start(requireWorldSeed: true)
    }
    func stop() { server.stop() }

    private func handle(_ request: JSONObject) -> JSONValue {
        lock.lock()
        requests.append(request)
        let operation = request["op"]?.stringValue
        if operation == "act" {
            if mode == .wrongReplyIdentity { lock.unlock(); return responses["unrelated_terminal"]! }
            if mode == .refusal { lock.unlock(); return responses["refused"]! }
            if mode == .fastCompletion {
                result = responses["terminal"]!
                lock.unlock()
                publish(responses["terminal"]!)
                return responses["admitted"]!
            }
            lock.unlock()
            return responses["admitted"]!
        }
        let baseline = result
        let needsProducer = operation == "result" && !scheduled
        if needsProducer { scheduled = true }
        lock.unlock()
        if needsProducer {
            producer.async { [weak self] in
                guard let self else { return }
                switch self.mode {
                case .completedAfterResultRead: self.complete()
                case .unrelatedThenCompletion:
                    self.publish(self.responses["unrelated_terminal"]!)
                    self.complete()
                case .closeWithoutCompletion: self.server.stop()
                case .fastCompletion, .noCompletion, .refusal, .wrongReplyIdentity: break
                }
            }
        }
        return baseline
    }

    private func complete() {
        let terminal = responses["terminal"]!
        lock.lock(); result = terminal; lock.unlock()
        publish(terminal)
    }

    private func publish(_ result: JSONValue) {
        _ = server.applyWorldDelta(["event": .string("action_result"), "last_result": result])
    }

    var recordedRequests: [JSONObject] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}

func runResidentClientSelfTest(_ args: [String]) -> Int32 {
    var test = SelfTest()
    let home = SelfTestFixtures.repositoryRoot(arguments: args)
    let fixturePath = SelfTestFixtures.path("client/responses.json", root: home)
    runResidentControlsClientScenarios(home: home, test: &test)
    guard let bytes = FileManager.default.contents(atPath: fixturePath),
          let responses = (try? JSONValue.parse(bytes))?.objectValue else {
        test.check(false, "client/response-fixtures-load"); return test.finish("resident-client")
    }
    let directory = "/tmp/leyline-client-" + String(getpid()) + "-" + String(UUID().uuidString.prefix(8))
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch { test.check(false, "client/temp-fixture-create"); return test.finish("resident-client") }
    defer { try? FileManager.default.removeItem(atPath: directory) }

    let requestID = "client-fixture-request"
    let action = "nav.focus.west"
    let missing = ResidentCommandClient.execute(operation: "act", arguments: [action, "--socket", directory + "/absent.sock"])
    test.check(missing.exitCode == 69 && missing.value.at(path: "error.code")?.stringValue == "core_not_running",
               "client/missing-core-has-typed-error-without-mutation-fallback")
    for invalid in ["-1", "+1", "1.5", "1e3", "9223372036854775808", ""] {
        let reply = ResidentCommandClient.execute(operation: "act", arguments: [action, "--expected-revision", invalid])
        test.check(reply.exitCode == 64 && reply.value.at(path: "error.code")?.stringValue == "expected_revision_invalid",
                   "client/rejects-invalid-revision-\(invalid.isEmpty ? "empty" : invalid)")
    }
    let valid = try? ResidentCommandClient.parse(operation: "act", arguments: [action,
        "--request-id", requestID, "--expected-revision", "0", "--args-json", "{\"step\":8}"])
    test.check(valid?.expectedRevision == 0 && valid?.requestID == requestID
        && valid?.arguments.at(path: "step")?.intValue == 8, "client/nonnegative-revision-and-json-args-preserved")
    let badArguments = ResidentCommandClient.execute(operation: "act", arguments: [action, "--args-json", "[]"])
    test.check(badArguments.exitCode == 64, "client/arguments-must-be-object-before-any-network-call")
    test.check(!ResidentCommandClient.isTerminal(responses["admitted"]!), "client/queued-admission-is-never-final-success")

    func run(_ mode: ResidentClientFixtureMode, name: String, extra: [String] = []) -> (ResidentClientReply, [JSONObject])? {
        let fixture = ResidentClientServerFixture(path: directory + "/" + name + ".sock",
            responses: responses, mode: mode)
        guard fixture.start() else { test.check(false, "client/\(name)-server-start"); return nil }
        defer { fixture.stop() }
        let reply = ResidentCommandClient.execute(operation: "act", arguments: [action,
            "--request-id", requestID, "--socket", fixture.path, "--timeout-seconds", "1"] + extra)
        return (reply, fixture.recordedRequests)
    }

    if let (reply, requests) = run(.completedAfterResultRead, name: "completion",
        extra: ["--expected-revision", "0", "--args-json", "{\"step\":8}"]) {
        test.check(reply.exitCode == 0 && reply.value.at(path: "data.phase")?.stringValue == "completed"
            && reply.value.at(path: "meta.completed")?.boolValue == true,
                   "client/waits-for-subscription-terminal-event")
        test.check(requests.filter { $0["op"]?.stringValue == "result" }.count == 1,
                   "client/exactly-one-result-baseline-read-with-no-recurring-poll")
        let mutation = requests.first { $0["op"]?.stringValue == "act" }
        test.check(mutation?["request_id"]?.stringValue == requestID && mutation?["expected_revision"]?.intValue == 0
            && mutation?["args"]?.at(path: "step")?.intValue == 8, "client/socket-mutation-preserves-request-and-preconditions")
    }
    if let (reply, _) = run(.fastCompletion, name: "fast") {
        test.check(reply.exitCode == 0 && reply.value.at(path: "data.status")?.stringValue == "accepted",
                   "client/replay-and-result-baseline-close-fast-completion-race")
    }
    if let (reply, requests) = run(.unrelatedThenCompletion, name: "unrelated") {
        test.check(reply.exitCode == 0 && reply.value.at(path: "data.request_id")?.stringValue == requestID,
                   "client/ignores-another-request-terminal-event")
        test.check(requests.filter { $0["op"]?.stringValue == "act" }.count == 1,
                   "client/completion-wait-does-not-resubmit-mutation")
    }
    if let (reply, _) = run(.refusal, name: "refusal") {
        test.check(reply.exitCode == 65 && reply.value.at(path: "error.code")?.stringValue == "focus_not_managed",
                   "client/server-refusal-remains-typed-and-unsuccessful")
    }
    if let (reply, _) = run(.wrongReplyIdentity, name: "wrong-reply") {
        test.check(reply.exitCode != 0 && reply.value.at(path: "error.code")?.stringValue == "resident_request_id_mismatch",
                   "client/wrong-request-reply-cannot-certify-this-command")
    }
    if let (reply, requests) = run(.noCompletion, name: "admission", extra: ["--no-wait"]) {
        test.check(reply.exitCode == 0 && reply.value.at(path: "meta.completed")?.boolValue == false
            && requests.filter { $0["op"]?.stringValue == "result" }.isEmpty,
                   "client/no-wait-explicitly-reports-admission-only")
    }
    if let (reply, _) = run(.closeWithoutCompletion, name: "closed") {
        test.check(reply.exitCode != 0 && reply.value.at(path: "meta.completed")?.boolValue == false,
                   "client/stream-loss-does-not-invent-completed-result")
    }
    let started = DispatchTime.now().uptimeNanoseconds
    if let (reply, requests) = run(.noCompletion, name: "timeout") {
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        test.check(reply.exitCode == 69 && reply.value.at(path: "error.code")?.stringValue == "completion_timeout"
            && elapsed < 2_000_000_000, "client/one-shot-completion-deadline-is-bounded")
        test.check(requests.filter { $0["op"]?.stringValue == "result" }.count == 1,
                   "client/timeout-has-no-result-poll-loop")
    }
    let reads = ResidentClientServerFixture(path: directory + "/reads.sock",                                              responses: responses, mode: .noCompletion)
    if reads.start() {
        defer { reads.stop() }
        for operation in ["hello", "status", "snapshot", "health"] {
            let reply = ResidentCommandClient.execute(operation: operation, arguments: ["--socket", reads.path])
            test.check(reply.exitCode == 0 && reply.value.at(path: "data.revision")?.intValue == 1,
                       "client/\(operation)-reads-exact-resident-baseline")
        }
        let cursor = ResidentPerformanceTrace.shared.snapshot().at(path: "last_sequence")!.intValue!
        ResidentPerformanceTrace.shared.record("client_trace_fixture", fields: ["request_id": .string("trace-client")])
        let trace = ResidentCommandClient.execute(operation: "trace", arguments: ["--socket", reads.path,
            "--args-json", "{\"from_sequence\":\(cursor),\"limit\":1}"])
        test.check(trace.exitCode == 0 && trace.value.at(path: "data.events")?.arrayValue?.count == 1
            && trace.value.at(path: "data.events")?.arrayValue?.first?.at(path: "kind")?.stringValue == "client_trace_fixture"
            && trace.value.at(path: "data.visible_evidence")?.boolValue == false,
            "client/trace-cursor-reads-bounded-facts-without-substituting-health")
        for invalid in ["{\"limit\":129}", "{\"limit\":\"2\"}", "{\"from_sequence\":-1}", "{\"unknown\":true}"] {
            let rejected = ResidentCommandClient.execute(operation: "trace", arguments: ["--socket", reads.path, "--args-json", invalid])
            test.check(rejected.exitCode != 0 && rejected.value.at(path: "data.reason")?.stringValue == "trace_arguments_invalid",
                "client/trace-invalid-shape-or-bound-refuses: \(invalid)")
        }
        let removed = ResidentCommandClient.execute(operation: "perf", arguments: ["--socket", reads.path])
        test.check(removed.exitCode == 64 && removed.value.at(path: "error.code")?.stringValue == "operation_invalid",
                   "client/unmeasured-perf-operation-is-not-offered")
    } else { test.check(false, "client/read-server-start") }
    return test.finish("resident-client")
}
