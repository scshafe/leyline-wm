import Foundation
import LeylineModel

/// @canonical resident_performance_trace -- bounded, monotonic runtime facts.
/// No filesystem, AX, AppKit or observer work is performed by recording. A
/// collector must preserve gaps and supply its own independent visual evidence.
final class ResidentPerformanceTrace: @unchecked Sendable {
    static let shared = ResidentPerformanceTrace()
    static let capacity = 4_096
    private let lock = NSLock()
    private var events: [JSONValue] = []
    private var sequence: UInt64 = 0
    private var dropped: UInt64 = 0
    private let contendedDrops = ResidentAtomic<UInt64>(0)

    func record(_ kind: String, fields: JSONObject = [:], timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds,
                nonblocking: Bool = false) {
        guard !kind.isEmpty, timestamp > 0 else { return }
        if nonblocking {
            guard lock.try() else { contendedDrops.wrappingAdd(1, ordering: .relaxed); return }
        } else { lock.lock() }
        defer { lock.unlock() }
        sequence &+= 1
        var event = fields
        event["kind"] = .string(kind)
        event["sequence"] = .int(Int64(clamping: sequence))
        event["uptime_ns"] = .int(Int64(clamping: timestamp))
        event["provenance"] = .string("resident_monotonic_observation")
        events.append(.object(event))
        if events.count > Self.capacity { events.removeFirst(); dropped &+= 1 }
    }

    func snapshot(from sequence: UInt64 = 0, limit: Int = 128) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let selected = events.filter { UInt64($0.at(path: "sequence")?.intValue ?? 0) > sequence }.prefix(max(1, min(limit, 128)))
        return .object(["schema": .string("leyline/native-performance-trace/v1"),
            "events": .array(Array(selected)), "last_sequence": .int(Int64(clamping: self.sequence)),
            "oldest_sequence": events.first?.at(path: "sequence") ?? .null,
            "dropped_events": .int(Int64(clamping: dropped + contendedDrops.load(ordering: .acquiring))),
            "visible_evidence": .bool(false)])
    }
}
