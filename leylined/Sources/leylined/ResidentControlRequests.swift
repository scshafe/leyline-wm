import Foundation
import LeylineModel

struct ResidentControlIntent: Sendable {
    let requestID: String
    let action: String
    let hard: Bool
    let resume: Bool?
    let expectedRevision: UInt64?
    var admissionSequence: UInt64 = 0
    var fingerprint: JSONValue {
        .object(["action": .string(action), "hard": .bool(hard), "resume": resume.map(JSONValue.bool) ?? .null,
            "expected_revision": expectedRevision.map { .int(Int64(clamping: $0)) } ?? .null])
    }
}

struct ResidentControlTimeoutResolution: Sendable {
    let requestID: String
    let admissionSequence: UInt64
    let generation: UInt64?
    let result: JSONValue
}

/// @canonical resident_control_requests -- bounded idempotency and terminal
/// result storage for the existing resident lifecycle/maintenance owner.
final class ResidentControlRequests: @unchecked Sendable {
    static let resultLimit = 64
    static let completionDeadlineNs: UInt64 = 5_000_000_000
    private struct Record { let intent: ResidentControlIntent; var result: JSONValue; var began = false }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var admissionSequence: UInt64 = 0
    private let limit = ResidentControlRequests.resultLimit

    func admit(_ request: JSONObject, revision: UInt64) -> (intent: ResidentControlIntent?, result: JSONValue) {
        let id = request["request_id"]?.stringValue ?? ""
        func refused(_ reason: String) -> (ResidentControlIntent?, JSONValue) {
            (nil, Self.result(id: id, status: .refused, revision: revision, reason: reason))
        }
        guard !id.isEmpty, id.utf8.count <= 256 else { return refused("control_request_id_invalid") }
        guard let action = request["action_id"]?.stringValue, ["start", "stop", "restart", "reset"].contains(action),
              let args = (request["args"] ?? .object([:])).objectValue,
              Set(args.keys).isSubset(of: ["mode", "resume"]),
              args["resume"] == nil || args["resume"]?.boolValue != nil else { return refused("control_arguments_invalid") }
        guard args["mode"] == nil || args["mode"]?.stringValue != nil else { return refused("control_reset_mode_invalid") }
        let mode = args["mode"]?.stringValue ?? "soft"
        guard ["soft", "hard"].contains(mode), action == "reset" || args["mode"] == nil,
              action == "reset" || action == "restart" || args["resume"] == nil else { return refused("control_reset_mode_invalid") }
        let expected: Int64?
        switch request["expected_revision"] {
        case nil: expected = nil
        case .some(.int(let value)) where value >= 0: expected = value
        default: return refused("expected_revision_invalid")
        }
        var intent = ResidentControlIntent(requestID: id, action: action, hard: mode == "hard",
            resume: args["resume"]?.boolValue, expectedRevision: expected.map(UInt64.init))
        lock.lock(); defer { lock.unlock() }
        if let existing = records[id] {
            return existing.intent.fingerprint == intent.fingerprint ? (nil, existing.result) : refused("control_request_id_conflict")
        }
        if order.count >= limit {
            guard let retired = order.first(where: { records[$0]?.result.at(path: "phase")?.stringValue == "completed" }) else {
                return refused("resident_control_limit")
            }
            order.removeAll { $0 == retired }; records.removeValue(forKey: retired)
        }
        func rememberRefusal(_ reason: String) -> (ResidentControlIntent?, JSONValue) {
            let value = Self.result(id: id, status: .refused, revision: revision, reason: reason,
                admissionSequence: intent.admissionSequence)
            records[id] = Record(intent: intent, result: value); order.append(id)
            return (nil, value)
        }
        if let expected = intent.expectedRevision, expected != revision { return rememberRefusal("expected_revision_mismatch") }
        guard action == "stop" || !records.values.contains(where: { $0.result.at(path: "phase")?.stringValue == "queued" }) else {
            return rememberRefusal("resident_control_busy")
        }
        guard admissionSequence < UInt64(Int64.max) else { return rememberRefusal("resident_control_epoch_exhausted") }
        admissionSequence += 1
        intent.admissionSequence = admissionSequence
        let queued: JSONValue = .object(["ok": .bool(true), "status": .string("accepted"), "phase": .string("queued"),
            "completed": .bool(false), "request_id": .string(id), "revision": .int(Int64(clamping: revision)),
            "control_admission_sequence": .int(Int64(intent.admissionSequence))])
        records[id] = Record(intent: intent, result: queued); order.append(id)
        return (intent, queued)
    }

    func result(requestID: String, revision: UInt64) -> JSONValue {
        guard !requestID.isEmpty, requestID.utf8.count <= 256 else {
            return Self.result(id: requestID, status: .refused, revision: revision, reason: "control_request_id_invalid")
        }
        lock.lock(); defer { lock.unlock() }
        return records[requestID]?.result ?? Self.result(id: requestID, status: .refused, revision: revision, reason: "control_request_unknown")
    }

    /// Allocate only the atomic lifecycle fence under this lock. Completion
    /// wins against delayed queued work; no IO, timeline or presentation runs here.
    func begin(requestID: String, expectedAdmissionSequence: UInt64, allocateGeneration: () -> UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[requestID], record.intent.admissionSequence == expectedAdmissionSequence,
              record.intent.admissionSequence == admissionSequence, !record.began,
              record.result.at(path: "phase")?.stringValue == "queued" else { return nil }
        record.began = true; records[requestID] = record
        return allocateGeneration()
    }

    @discardableResult
    func complete(requestID: String, expectedAdmissionSequence: UInt64, status: WmStatus, revision: UInt64,
                  reason: String?, details: JSONObject = [:]) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[requestID], record.intent.admissionSequence == expectedAdmissionSequence,
              record.result.at(path: "phase")?.stringValue == "queued" else { return nil }
        record.result = Self.result(id: requestID, status: status, revision: revision, reason: reason,
            details: details, admissionSequence: record.intent.admissionSequence)
        records[requestID] = record; return record.result
    }

    /// Fence the owning timeout before publishing its terminal record or reopening
    /// admission. The callback may only advance a lock-free atomic generation;
    /// no timeline, capability, maintenance or IO callback can run under this lock.
    func expire(requestID: String, expectedAdmissionSequence: UInt64, revision: UInt64,
                allocateGeneration: () -> UInt64) -> ResidentControlTimeoutResolution? {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[requestID], record.intent.admissionSequence == expectedAdmissionSequence,
              record.result.at(path: "phase")?.stringValue == "queued" else { return nil }
        let generation = record.intent.admissionSequence == admissionSequence ? allocateGeneration() : nil
        record.result = Self.result(id: requestID, status: .failed, revision: revision,
            reason: "resident_control_timeout", details: ["readiness_verified": .bool(false)],
            admissionSequence: record.intent.admissionSequence)
        records[requestID] = record
        return ResidentControlTimeoutResolution(requestID: requestID, admissionSequence: record.intent.admissionSequence,
            generation: generation, result: record.result)
    }

    /// A newer admitted intent retires old timeout work even while its lifecycle
    /// queue is held and the new intent has not allocated its generation yet.
    func isCurrentTimeout(_ timeout: ResidentControlTimeoutResolution) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard timeout.generation != nil, timeout.admissionSequence == admissionSequence,
              let record = records[timeout.requestID] else { return false }
        return record.intent.admissionSequence == timeout.admissionSequence
            && record.result == timeout.result
    }

    func supersede(except requestID: String?, revision: UInt64) -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        var results: [JSONValue] = []
        for id in order where id != requestID {
            guard var record = records[id], record.result.at(path: "phase")?.stringValue == "queued" else { continue }
            record.result = Self.result(id: id, status: .failed, revision: revision, reason: "resident_control_superseded",
                admissionSequence: record.intent.admissionSequence)
            records[id] = record; results.append(record.result)
        }
        return results
    }

    private static func result(id: String, status: WmStatus, revision: UInt64, reason: String?,
                               details: JSONObject = [:], admissionSequence: UInt64? = nil) -> JSONValue {
        var value = details.merging(["ok": .bool(status == .accepted || status == .noop), "status": .string(status.rawValue),
            "phase": .string("completed"), "completed": .bool(true), "request_id": .string(id),
            "revision": .int(Int64(clamping: revision)), "reason": reason.map(JSONValue.string) ?? .null])
        if let admissionSequence { value["control_admission_sequence"] = .int(Int64(admissionSequence)) }
        return .object(value)
    }
}
