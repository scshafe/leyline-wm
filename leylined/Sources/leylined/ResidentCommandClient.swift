// Thin, on-demand resident command client. Mutations have one socket path and
// never fall back to a shell, one-shot AX implementation, or legacy process.
import Darwin
import Foundation
import LeylineModel

struct ResidentClientReply: Sendable {
    let value: JSONValue
    let exitCode: Int32
}

struct ResidentClientOptions: Sendable {
    let operation: String
    let socketPath: String
    let requestID: String?
    let actionID: String?
    let expectedRevision: Int64?
    let arguments: JSONValue
    let waitForCompletion: Bool
    let timeoutSeconds: Int
}

private struct ResidentClientArgumentError: Error {
    let code: String
    let message: String
}

/// One scoped subscription owns its descriptor until the reader finishes. The
/// one-shot deadline only shutdowns it; it never closes/reuses an in-use fd.
private final class ResidentCommandStream: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var closed = false
    private var deadline: DispatchSourceTimer?

    init?(path: String, timeoutSeconds: Int, deadlineUptimeNanoseconds: UInt64) {
        guard let fd = FramedJSONSocket.connect(path: path, timeoutSeconds: timeoutSeconds) else { return nil }
        descriptor = fd
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "leylined.client.completion.deadline"))
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadlineUptimeNanoseconds))
        source.setEventHandler { [weak self] in self?.interrupt() }
        deadline = source
        source.resume()
    }

    func subscribe(from revision: Int64) -> Bool {
        FramedJSONSocket.writeAll(descriptor, FramedJSONSocket.encode(.object([
            "op": .string("subscribe"), "from_revision": .int(revision),
        ])))
    }

    func receive() -> JSONValue? {
        guard let bytes = FramedJSONSocket.readFrame(descriptor) else { return nil }
        return try? JSONValue.parse(bytes)
    }

    private func interrupt() {
        lock.lock(); defer { lock.unlock() }
        if !closed { _ = shutdown(descriptor, SHUT_RDWR) }
    }

    func closeStream() {
        deadline?.cancel(); deadline = nil
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    deinit { closeStream() }
}

/// @canonical resident_command_client -- registered commands and diagnostics
/// use ServeClient requests plus the canonical revision subscription framing.
enum ResidentCommandClient {
    static func parse(operation: String, arguments: [String],
                      environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ResidentClientOptions {
        guard ["act", "result", "control", "control-result", "hello", "status", "snapshot", "health", "perf", "trace"].contains(operation) else {
            throw ResidentClientArgumentError(code: "operation_invalid", message: "Unknown resident client operation")
        }
        let root = environment["LEYLINE_ROOT"] ?? (NSHomeDirectory() + "/.config/leyline")
        let runtime = environment["LEYLINE_RUNTIME_DIR"] ?? (root + "/runtime")
        var path = environment["LEYLINE_CORE_SOCKET"] ?? (runtime + "/sockets/leylined.sock")
        var requestID: String?
        var actionID: String?
        var expected: Int64?
        var payload: JSONValue = .object([:])
        let mutating = operation == "act" || operation == "control"
        let queryingResult = operation == "result" || operation == "control-result"
        var waiting = mutating
        var timeout = 10
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw ResidentClientArgumentError(code: "argument_missing", message: "Missing value for \(flag)")
            }
            return arguments[index + 1]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--socket": path = try value(after: argument); index += 2
            case "--request-id": requestID = try value(after: argument); index += 2
            case "--expected-revision":
                let raw = try value(after: argument)
                guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let revision = Int64(raw), revision >= 0 else {
                    throw ResidentClientArgumentError(code: "expected_revision_invalid", message: "Expected revision must be a nonnegative Int64 decimal")
                }
                expected = revision; index += 2
            case "--args-json":
                let raw = try value(after: argument)
                guard raw.utf8.count <= 1_048_576,
                      let parsed = try? JSONValue.parse(Data(raw.utf8)), parsed.objectValue != nil else {
                    throw ResidentClientArgumentError(code: "action_arguments_invalid", message: "Action arguments must be a JSON object of at most 1 MiB")
                }
                payload = parsed; index += 2
            case "--timeout-seconds":
                let raw = try value(after: argument)
                guard let seconds = Int(raw), seconds >= 1, seconds <= 60 else {
                    throw ResidentClientArgumentError(code: "timeout_invalid", message: "Timeout must be an integer from 1 to 60 seconds")
                }
                timeout = seconds; index += 2
            case "--wait": waiting = true; index += 1
            case "--no-wait": waiting = false; index += 1
            case "--json": index += 1
            default:
                guard !argument.hasPrefix("-") else {
                    throw ResidentClientArgumentError(code: "argument_invalid", message: "Unknown option \(argument)")
                }
                if mutating, actionID == nil { actionID = argument }
                else if queryingResult, requestID == nil { requestID = argument }
                else { throw ResidentClientArgumentError(code: "argument_invalid", message: "Unexpected positional argument") }
                index += 1
            }
        }
        guard !path.isEmpty, path.utf8.count < 104 else {
            throw ResidentClientArgumentError(code: "socket_path_invalid", message: "Socket path must fit the local Unix socket address")
        }
        if mutating {
            guard let actionID, !actionID.isEmpty, actionID.utf8.count <= 256 else {
                throw ResidentClientArgumentError(code: "action_id_missing", message: "Provide a registered action ID")
            }
            if requestID == nil { requestID = UUID().uuidString }
        }
        if mutating || queryingResult {
            guard let requestID, !requestID.isEmpty, requestID.utf8.count <= 256 else {
                throw ResidentClientArgumentError(code: "request_id_invalid", message: "Request ID must contain 1 to 256 UTF-8 bytes")
            }
        } else if requestID != nil || expected != nil || (operation != "trace" && payload != .object([:])) || waiting {
            throw ResidentClientArgumentError(code: "argument_invalid", message: "Mutation options require act, result, control or control-result")
        }
        if !mutating, expected != nil || (operation != "trace" && payload != .object([:])) {
            throw ResidentClientArgumentError(code: "argument_invalid", message: "Expected revision and arguments require act or control")
        }
        return ResidentClientOptions(operation: operation, socketPath: path, requestID: requestID,
            actionID: actionID, expectedRevision: expected, arguments: payload,
            waitForCompletion: waiting, timeoutSeconds: timeout)
    }

    static func execute(operation: String, arguments: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> ResidentClientReply {
        let options: ResidentClientOptions
        do { options = try parse(operation: operation, arguments: arguments, environment: environment) }
        catch let error as ResidentClientArgumentError {
            return failure(code: error.code, message: error.message, requestID: nil, exitCode: 64)
        } catch { return failure(code: "argument_invalid", message: String(describing: error), requestID: nil, exitCode: 64) }
        signal(SIGPIPE, SIG_IGN)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(options.timeoutSeconds) * 1_000_000_000
        func request(_ body: JSONObject) -> JSONValue? {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = Double(deadline - now) / 1_000_000_000
            return ServeClient.request(socketPath: options.socketPath, body: body, timeoutSeconds: remaining)
        }
        if !["act", "result", "control", "control-result"].contains(operation) {
            var body: JSONObject = ["op": .string(operation == "perf" ? "health" : operation)]
            if operation == "trace" { body["args"] = options.arguments }
            guard let response = request(body) else {
                return failure(code: "core_not_running", message: "Resident core is not reachable", requestID: nil)
            }
            if operation == "perf" { return performance(response) }
            guard response.objectValue != nil, response.at(path: "ok")?.boolValue != nil else {
                return failure(code: "resident_protocol_invalid", message: "Resident read response is malformed", requestID: nil)
            }
            if response.at(path: "ok")?.boolValue == true {
                guard let revision = response.at(path: "revision")?.intValue, revision >= 0,
                      let epoch = response.at(path: "epoch_ms")?.intValue, epoch >= 0,
                      operation == "hello" || operation == "trace" || response.at(path: "health")?.objectValue != nil else {
                    return failure(code: "resident_protocol_invalid", message: "Resident read baseline or health is missing", requestID: nil)
                }
                if operation == "trace" {
                    guard response.at(path: "schema")?.stringValue == "leyline/native-performance-trace/v1",
                          let events = response.at(path: "events")?.arrayValue, events.count <= 128,
                          let sequence = response.at(path: "last_sequence")?.intValue, sequence >= 0,
                          let drops = response.at(path: "dropped_events")?.intValue, drops >= 0,
                          response.at(path: "visible_evidence")?.boolValue == false,
                          let pid = response.at(path: "pid")?.intValue, pid > 0 else {
                        return failure(code: "resident_protocol_invalid", message: "Resident trace shape or bounds are invalid", requestID: nil)
                    }
                }
            }
            return wrap(response, requestID: nil, completed: true)
        }
        guard let hello = request(["op": .string("hello")]) else {
            return failure(code: "core_not_running", message: "Resident core hello baseline is unavailable", requestID: options.requestID)
        }
        guard hello.at(path: "ok")?.boolValue == true,
              let baseline = hello.at(path: "revision")?.intValue, baseline >= 0,
              let epoch = hello.at(path: "epoch_ms")?.intValue, epoch >= 0 else {
            return failure(code: "resident_protocol_invalid", message: "Resident hello revision or epoch is malformed", requestID: options.requestID)
        }
        var body: JSONObject = ["op": .string(operation), "request_id": .string(options.requestID!)]
        if operation == "act" || operation == "control" {
            body["action_id"] = options.actionID.map(JSONValue.string)
            body["args"] = options.arguments
            body["expected_revision"] = options.expectedRevision.map(JSONValue.int)
        }
        guard let response = request(body) else {
            return failure(code: "resident_request_failed", message: "Resident request transport failed; mutation outcome is unknown",
                           requestID: options.requestID)
        }
        if identityMismatch(response, requestID: options.requestID!) {
            return failure(code: "resident_request_id_mismatch", message: "Resident reply belongs to another request",
                           requestID: options.requestID)
        }
        if isTerminal(response) || !options.waitForCompletion || response.at(path: "ok")?.boolValue == false {
            return wrap(response, requestID: options.requestID, completed: isTerminal(response))
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline,
              let stream = ResidentCommandStream(path: options.socketPath,
                timeoutSeconds: max(1, Int((deadline - now + 999_999_999) / 1_000_000_000)),
                deadlineUptimeNanoseconds: deadline) else {
            return failure(code: "completion_subscription_unavailable", message: "Cannot subscribe to resident completion; retain the request ID",
                           requestID: options.requestID)
        }
        defer { stream.closeStream() }
        guard stream.subscribe(from: baseline) else {
            return failure(code: "completion_subscription_failed", message: "Resident completion subscription failed", requestID: options.requestID)
        }
        // Exactly one cache read closes a completion racing admission and
        // subscription registration. All later completion comes from push.
        let resultOperation = operation == "control" || operation == "control-result" ? "control-result" : "result"
        guard let current = request(["op": .string(resultOperation), "request_id": .string(options.requestID!)]) else {
            return failure(code: "result_read_failed", message: "Resident result baseline is unavailable", requestID: options.requestID)
        }
        if identityMismatch(current, requestID: options.requestID!) {
            return failure(code: "resident_request_id_mismatch", message: "Resident result baseline belongs to another request",
                           requestID: options.requestID)
        }
        if isTerminal(current) || current.at(path: "ok")?.boolValue == false {
            return wrap(current, requestID: options.requestID, completed: isTerminal(current))
        }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let event = stream.receive() else {
                let timedOut = DispatchTime.now().uptimeNanoseconds >= deadline
                return failure(code: timedOut ? "completion_timeout" : "completion_stream_closed",
                    message: "Resident completion was not observed; query the same request ID without resubmitting a mutation",
                    requestID: options.requestID)
            }
            if let eventEpoch = event.at(path: "epoch_ms")?.intValue, eventEpoch != epoch {
                return failure(code: "resident_epoch_changed", message: "Resident authority changed during completion wait", requestID: options.requestID)
            }
            if event.at(path: "ok")?.boolValue == false || event.at(path: "type")?.stringValue == "revision_gap" {
                return failure(code: event.at(path: "error")?.stringValue ?? "completion_subscription_refused",
                    message: "Resident completion subscription was refused or lost its revision baseline", requestID: options.requestID)
            }
            let result = resultOperation == "control-result" ? event.at(path: "delta.control_last_result")
                : event.at(path: "delta.last_result") ?? event.at(path: "result")
            if let result, result.at(path: "request_id")?.stringValue == options.requestID, isTerminal(result) {
                return wrap(result, requestID: options.requestID, completed: true)
            }
        }
        return failure(code: "completion_timeout", message: "Resident completion deadline expired; mutation outcome remains unconfirmed",
                       requestID: options.requestID)
    }

    static func isTerminal(_ value: JSONValue) -> Bool {
        if value.at(path: "phase")?.stringValue == "queued" || value.at(path: "completed")?.boolValue == false { return false }
        return value.at(path: "completed")?.boolValue == true || value.at(path: "phase")?.stringValue == "completed"
            || ["refused", "failed", "noop"].contains(value.at(path: "status")?.stringValue ?? "")
    }

    private static func identityMismatch(_ value: JSONValue, requestID: String) -> Bool {
        let status = value.at(path: "status")?.stringValue
        let successOrAdmission = value.at(path: "ok")?.boolValue == true || status == "accepted" || status == "noop"
        return successOrAdmission && value.at(path: "request_id")?.stringValue != requestID
    }

    private static func performance(_ response: JSONValue) -> ResidentClientReply {
        guard response.at(path: "ok")?.boolValue == true else { return wrap(response, requestID: nil, completed: true) }
        guard let health = response.at(path: "health"), health.objectValue != nil else {
            return failure(code: "resident_protocol_invalid", message: "Resident performance health diagnostics are missing", requestID: nil)
        }
        let distributions = health.at(path: "resident.performance.distributions")
            ?? health.at(path: "performance.distributions")
        let diagnostic: JSONValue = .object([
            "schema": .string("leyline/resident-performance/v1"),
            "revision": response.at(path: "revision") ?? .null,
            "epoch_ms": response.at(path: "epoch_ms") ?? .null,
            "diagnostics": health, "distributions": distributions ?? .null,
            "release_evidence": .bool(false), "live_certification": .bool(false),
        ])
        guard let distributions, let object = distributions.objectValue, !object.isEmpty else {
            return failure(code: "performance_distributions_unavailable", message: "Resident distributions are unmeasured; health diagnostics are available",
                           requestID: nil, data: diagnostic)
        }
        return ResidentClientReply(value: envelope(data: diagnostic, error: nil, requestID: nil, completed: true), exitCode: 0)
    }

    private static func wrap(_ response: JSONValue, requestID: String?, completed: Bool) -> ResidentClientReply {
        guard response.objectValue != nil,
              response.at(path: "ok")?.boolValue != nil || response.at(path: "status")?.stringValue != nil else {
            return failure(code: "resident_protocol_invalid", message: "Resident response has no typed status", requestID: requestID)
        }
        let status = response.at(path: "status")?.stringValue
        let refused = response.at(path: "ok")?.boolValue == false || status == "refused" || status == "failed"
        let reason = response.at(path: "reason")?.stringValue ?? response.at(path: "error")?.stringValue ?? "resident_refused"
        let error: JSONValue? = refused ? .object(["code": .string(reason), "message": .string("Resident request did not complete successfully")]) : nil
        return ResidentClientReply(value: envelope(data: response, error: error, requestID: requestID, completed: completed),
                                   exitCode: refused ? 65 : 0)
    }

    private static func failure(code: String, message: String, requestID: String?, exitCode: Int32 = 69,
                                data: JSONValue? = nil) -> ResidentClientReply {
        ResidentClientReply(value: envelope(data: data, error: .object(["code": .string(code), "message": .string(message)]),
                                           requestID: requestID, completed: false), exitCode: exitCode)
    }

    private static func envelope(data: JSONValue?, error: JSONValue?, requestID: String?, completed: Bool) -> JSONValue {
        .object(["data": data ?? .null, "error": error ?? .null,
                 "meta": .object(["transport": .string("resident_socket"),
                    "request_id": requestID.map(JSONValue.string) ?? .null,
                    "completed": .bool(completed), "mutation_fallback": .bool(false)])])
    }
}

func runResidentCommandClient(_ operation: String, _ args: [String]) -> Int32 {
    let reply = ResidentCommandClient.execute(operation: operation, arguments: args)
    print(reply.value.canonical())
    return reply.exitCode
}
