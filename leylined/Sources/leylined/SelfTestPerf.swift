// self-test perf — drives N synthetic transitions with deterministic stamps
// through Timeline + PerfRecorder and asserts revision discipline, refusal
// purity, segment counts, and exact percentiles (the distribution is known).
// `leylined perf --dump [--synthetic N]` emits the same recorder's summary as
// JSON — marked synthetic:true until a resident daemon exists to be read live.
import Foundation
import LeylineModel

func driveSynthetic(n: Int) -> (timeline: Timeline<Int>, recorder: PerfRecorder) {
    var timeline = Timeline(state: 0, revision: Revision(0))
    var recorder = PerfRecorder()
    for i in 1...n {
        timeline.apply { state in
            state += 1
            return .accepted
        }
        var stamps = TransitionStamps()
        stamps.tInputNanos = 0
        stamps.tIntentNanos = UInt64(i) * 1_000
        stamps.tPlanNanos = UInt64(i) * 2_000
        stamps.tEffectIssuedNanos = UInt64(i) * 3_000
        stamps.tFirstFrameNanos = UInt64(i) * 4_000
        stamps.tVerifiedNanos = UInt64(i) * 5_000
        recorder.record(stamps)
    }
    return (timeline, recorder)
}

func runPerfSelfTest() -> Int32 {
    var t = SelfTest()
    let n = 1000
    var (timeline, recorder) = driveSynthetic(n: n)

    // Revision discipline: N accepted transitions mint exactly N revisions.
    t.check(timeline.revision == Revision(UInt64(n)) && timeline.state == n,
            "perf/accepted-mints-exactly-one-revision-each (\(n))")

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
            "perf/refused-noop-failed-commit-nothing-mint-nothing")

    // Segment counts: all five pipeline segments recorded N times.
    let expectedSegments = ["input_to_intent", "input_to_plan", "input_to_effect_issued",
                            "input_to_first_frame", "input_to_verified"]
    let counts = expectedSegments.map { recorder.series[$0]?.count ?? -1 }
    t.check(counts.allSatisfy { $0 == n },
            "perf/all-five-segments-recorded-n-times")

    // Exact percentiles on the known distribution (input_to_intent = 1..N μs,
    // nearest-rank): p50 = 500 μs, p95 = 950 μs, max = 1000 μs.
    let intent = recorder.series["input_to_intent"]
    t.check(intent?.percentileNanos(50) == 500_000
                && intent?.percentileNanos(95) == 950_000
                && intent?.maxNanos == 1_000_000,
            "perf/exact-percentiles-on-known-distribution")

    // The wire vocabulary round-trips as bare strings.
    if let data = try? JSONEncoder().encode(WmStatus.refused),
       let back = try? JSONDecoder().decode(WmStatus.self, from: data) {
        t.check(String(decoding: data, as: UTF8.self) == "\"refused\"" && back == .refused,
                "perf/wmstatus-wire-shape")
    } else {
        t.check(false, "perf/wmstatus-wire-shape")
    }

    // The summary is well-formed JSON with every segment present.
    if let dump = try? JSONEncoder().encode(recorder.summary(synthetic: true)),
       let parsed = (try? JSONSerialization.jsonObject(with: dump)) as? [String: Any],
       let segments = parsed["segments"] as? [String: Any] {
        t.check(segments.count == expectedSegments.count && parsed["synthetic"] as? Bool == true,
                "perf/summary-json-well-formed (\(segments.count) segments)")
    } else {
        t.check(false, "perf/summary-json-well-formed")
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

    return t.finish("perf")
}

func runPerfDump(_ args: [String]) -> Int32 {
    var n = 1000
    if let i = args.firstIndex(of: "--synthetic"), i + 1 < args.count, let v = Int(args[i + 1]), v > 0 {
        n = v
    }
    let (_, recorder) = driveSynthetic(n: n)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(recorder.summary(synthetic: true)) else {
        return 70
    }
    print(String(decoding: data, as: UTF8.self))
    return 0
}
