// self-test timeline — the authority timeline's revision discipline and refusal
// purity, the result wire vocabulary, and the bounded resident performance trace.
// Trace stamps are deterministic test input, never measured acceptance evidence.
import Foundation
import LeylineModel

func runTimelineSelfTest() -> Int32 {
    var t = SelfTest()
    let n = 1000
    var timeline = Timeline(state: 0, revision: Revision(0))
    for _ in 1...n {
        timeline.apply { state in
            state += 1
            return .accepted
        }
    }

    // Revision discipline: N accepted transitions mint exactly N revisions.
    t.check(timeline.revision == Revision(UInt64(n)) && timeline.state == n,
            "timeline/accepted-mints-exactly-one-revision-each (\(n))")

    // Refusal purity is a MECHANISM: a body that mutates its draft and then
    // refuses commits nothing and mints nothing. Same for noop and failed.
    let before = (timeline.state, timeline.revision)
    let refused = timeline.apply { state in
        state = -999
        return .refused
    }
    let nooped = timeline.apply { state in
        state = -999
        return .noop
    }
    let failed = timeline.apply { state in
        state = -999
        return .failed
    }
    t.check(timeline.state == before.0 && timeline.revision == before.1
                && refused.status == .refused && refused.revision == before.1
                && nooped.status == .noop && failed.status == .failed,
            "timeline/refused-noop-failed-commit-nothing-mint-nothing")

    // The wire vocabulary round-trips as bare strings.
    if let data = try? JSONEncoder().encode(WmStatus.refused),
       let back = try? JSONDecoder().decode(WmStatus.self, from: data) {
        t.check(String(decoding: data, as: UTF8.self) == "\"refused\"" && back == .refused,
                "timeline/wmstatus-wire-shape")
    } else {
        t.check(false, "timeline/wmstatus-wire-shape")
    }

    // The real resident trace preserves authority and bounded collection facts.
    // These stamps are deterministic test input, never measured acceptance.
    let trace = ResidentPerformanceTrace()
    trace.record("", timestamp: 1)
    trace.record("invalid", timestamp: 0)
    t.check(trace.snapshot().at(path: "last_sequence")?.intValue == 0,
            "trace/invalid-events-do-not-mint-sequences")
    trace.record("admission", fields: ["kind": .string("substituted"),
        "sequence": .int(900), "uptime_ns": .int(900),
        "provenance": .string("substituted"), "request_id": .string("trace-test")], timestamp: 100)
    let first = trace.snapshot().at(path: "events")?.arrayValue?.first
    t.check(first?.at(path: "kind")?.stringValue == "admission"
        && first?.at(path: "sequence")?.intValue == 1
        && first?.at(path: "uptime_ns")?.intValue == 100
        && first?.at(path: "provenance")?.stringValue == "resident_monotonic_observation"
        && first?.at(path: "request_id")?.stringValue == "trace-test",
            "trace/caller-cannot-substitute-authoritative-fields")
    for index in 2...(ResidentPerformanceTrace.capacity + 5) {
        trace.record("observation", timestamp: UInt64(index + 100), nonblocking: true)
    }
    let page = trace.snapshot(from: 0, limit: 999)
    t.check(page.at(path: "events")?.arrayValue?.count == 128
        && page.at(path: "oldest_sequence")?.intValue == 6
        && page.at(path: "last_sequence")?.intValue == Int64(ResidentPerformanceTrace.capacity + 5)
        && page.at(path: "dropped_events")?.intValue == 5
        && page.at(path: "visible_evidence")?.boolValue == false,
            "trace/overflow-and-bounded-page-remain-explicit")
    let tail = trace.snapshot(from: UInt64(ResidentPerformanceTrace.capacity + 3), limit: 2)
    let tailSequences: [Int64?]? = tail.at(path: "events")?.arrayValue?.map { $0.at(path: "sequence")?.intValue }
    let expectedTail: [Int64?] = [Int64(ResidentPerformanceTrace.capacity + 4), Int64(ResidentPerformanceTrace.capacity + 5)]
    t.check(tailSequences == expectedTail,
            "trace/cursor-pages-preserve-exact-sequence")

    return t.finish("timeline")
}
