// Self-instrumentation (ADR-023 D11): every transition stamps the pipeline
// t_input → t_intent → t_plan → t_effect_issued → t_first_frame → t_verified.
// Timestamps are SUPPLIED by the daemon boundary (monotonic nanos) — the pure
// model never reads a clock, so recording stays deterministic and testable.
// Histograms are in-memory, capped, reset per epoch; `ley perf` and
// `ley bench core --json` are two readers of this one surface.
public struct TransitionStamps: Sendable {
    public var tInputNanos: UInt64?
    public var tIntentNanos: UInt64?
    public var tPlanNanos: UInt64?
    public var tEffectIssuedNanos: UInt64?
    public var tFirstFrameNanos: UInt64?
    public var tVerifiedNanos: UInt64?

    public init() {}

    /// The recorded segments, each relative to t_input (absent stamps skip).
    public func segments() -> [(name: String, nanos: UInt64)] {
        guard let input = tInputNanos else { return [] }
        var out: [(String, UInt64)] = []
        func add(_ name: String, _ stamp: UInt64?) {
            guard let stamp, stamp >= input else { return }
            out.append((name, stamp - input))
        }
        add("input_to_intent", tIntentNanos)
        add("input_to_plan", tPlanNanos)
        add("input_to_effect_issued", tEffectIssuedNanos)
        add("input_to_first_frame", tFirstFrameNanos)
        add("input_to_verified", tVerifiedNanos)
        return out
    }
}

public struct PerfSeries: Sendable {
    public private(set) var count: Int = 0
    public private(set) var maxNanos: UInt64 = 0
    private var samples: [UInt64] = []
    private static let cap = 8192

    public init() {}

    public mutating func record(_ nanos: UInt64) {
        count += 1
        maxNanos = Swift.max(maxNanos, nanos)
        if samples.count < Self.cap {
            samples.append(nanos)
        } else {
            samples[count % Self.cap] = nanos
        }
    }

    /// Nearest-rank percentile over the retained samples (exact until the cap,
    /// a ring approximation after — the max is tracked exactly regardless).
    public func percentileNanos(_ p: Double) -> UInt64? {
        guard !samples.isEmpty, p > 0, p <= 100 else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }
}

public struct PerfSummary: Codable, Sendable {
    public struct Segment: Codable, Sendable {
        public let count: Int
        public let p50Ms: Double
        public let p95Ms: Double
        public let p99Ms: Double
        public let maxMs: Double

        enum CodingKeys: String, CodingKey {
            case count
            case p50Ms = "p50_ms"
            case p95Ms = "p95_ms"
            case p99Ms = "p99_ms"
            case maxMs = "max_ms"
        }
    }

    public let synthetic: Bool
    public let segments: [String: Segment]
}

public struct PerfRecorder: Sendable {
    public private(set) var series: [String: PerfSeries] = [:]

    public init() {}

    public mutating func record(_ stamps: TransitionStamps) {
        for (name, nanos) in stamps.segments() {
            series[name, default: PerfSeries()].record(nanos)
        }
    }

    public func summary(synthetic: Bool) -> PerfSummary {
        func ms(_ nanos: UInt64?) -> Double {
            Double(nanos ?? 0) / 1_000_000
        }
        var segments: [String: PerfSummary.Segment] = [:]
        for (name, s) in series {
            segments[name] = PerfSummary.Segment(
                count: s.count,
                p50Ms: ms(s.percentileNanos(50)),
                p95Ms: ms(s.percentileNanos(95)),
                p99Ms: ms(s.percentileNanos(99)),
                maxMs: ms(s.maxNanos)
            )
        }
        return PerfSummary(synthetic: synthetic, segments: segments)
    }
}
