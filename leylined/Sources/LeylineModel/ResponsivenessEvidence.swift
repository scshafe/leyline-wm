import Foundation

/// Endpoint names describe observation boundaries, not interchangeable timer labels.
public enum ResponsivenessEndpoint: String, Codable, Sendable {
    case receipt, intentResolved = "intent_resolved", planCommitted = "plan_committed"
    case renderSubmitted = "render_submitted", physicallyVisible = "physically_visible"
    case verified, serving, tapReleased = "tap_released", targetedReadCompleted = "targeted_read_completed"
}

public struct ResponsivenessStamp: Codable, Sendable {
    public let endpoint: ResponsivenessEndpoint
    public let nanos: UInt64
    public let provenance: String
    public init(endpoint: ResponsivenessEndpoint, nanos: UInt64, provenance: String) {
        self.endpoint = endpoint; self.nanos = nanos; self.provenance = provenance
    }
}

public struct ResponsivenessSample: Codable, Sendable {
    public let scenarioID: String
    public let revision: UInt64
    public let generation: UInt64
    public let refreshHz: Double?
    public let windowCount: Int
    public let load: String
    public let synthetic: Bool
    public let stamps: [String: ResponsivenessStamp]
    public init(scenarioID: String, revision: UInt64, generation: UInt64,
                refreshHz: Double?, windowCount: Int, load: String, synthetic: Bool,
                stamps: [String: ResponsivenessStamp]) {
        self.scenarioID = scenarioID; self.revision = revision; self.generation = generation
        self.refreshHz = refreshHz; self.windowCount = windowCount; self.load = load
        self.synthetic = synthetic; self.stamps = stamps
    }

    /// Reject missing/stale/swapped/fabricated endpoints. AX setter/AppKit submission is never visible.
    public func validate(expectedRevision: UInt64, expectedGeneration: UInt64,
                         endpoints: [ResponsivenessEndpoint], liveRequired: Bool) -> [String] {
        var errors: [String] = []
        if revision != expectedRevision || generation != expectedGeneration { errors.append("stale_revision_or_generation") }
        if liveRequired && synthetic { errors.append("synthetic_not_live_evidence") }
        if scenarioID.isEmpty || windowCount < 0 || load.isEmpty { errors.append("sample_context_missing") }
        for endpoint in endpoints {
            guard let stamp = stamps[endpoint.rawValue] else { errors.append("missing_endpoint_" + endpoint.rawValue); continue }
            if stamp.endpoint != endpoint { errors.append("swapped_endpoint_" + endpoint.rawValue) }
            if stamp.provenance.isEmpty { errors.append("missing_provenance_" + endpoint.rawValue) }
            if endpoint == .physicallyVisible {
                if stamp.provenance != "independent_visible_observer" { errors.append("visible_endpoint_not_independently_observed") }
                if refreshHz == nil || refreshHz! <= 0 { errors.append("visible_refresh_rate_missing") }
            }
        }
        let order: [ResponsivenessEndpoint] = [.receipt, .intentResolved, .planCommitted, .renderSubmitted, .physicallyVisible, .verified]
        let times = order.compactMap { stamps[$0.rawValue]?.nanos }
        if zip(times, times.dropFirst()).contains(where: { $0 > $1 }) { errors.append("nonmonotonic_endpoints") }
        return errors
    }
}

/// @canonical responsiveness_absolute_gate -- a nonempty exact source-bound corpus is mandatory.
/// These frozen border budgets are proposed release gates; passing fixtures confers no live certification.
public enum ResponsivenessEvidence {
    public static let borderSubmissionP95Ms: Double = 16
    public static let borderVisibleP95Ms: Double = 125
    public static let maximumOrderedQueueDepth = 32
    public static let maximumPendingDesiredPerLane = 1
    public static let tapReleaseDeadlineMs: Double = 250

    public static func gate(samples: [ResponsivenessSample], scenarioID: String,
                            from: ResponsivenessEndpoint, to: ResponsivenessEndpoint,
                            p95CeilingMs: Double, minimumSamples: Int,
                            expectedRevision: UInt64, expectedGeneration: UInt64,
                            liveRequired: Bool) -> [String] {
        guard minimumSamples > 0, !samples.isEmpty else { return ["empty_evidence_inventory"] }
        let exact = samples.filter { $0.scenarioID == scenarioID }
        guard exact.count >= minimumSamples else { return ["insufficient_scenario_samples"] }
        var errors = exact.flatMap { $0.validate(expectedRevision: expectedRevision,
            expectedGeneration: expectedGeneration, endpoints: [from, to], liveRequired: liveRequired) }
        guard errors.isEmpty else { return errors }
        var series = PerfSeries()
        for sample in exact {
            guard let start = sample.stamps[from.rawValue]?.nanos, let end = sample.stamps[to.rawValue]?.nanos,
                  end >= start else { errors.append("nonmonotonic_endpoints"); continue }
            series.record(end - start)
        }
        if let p95 = series.percentileNanos(95), Double(p95) / 1_000_000 > p95CeilingMs {
            errors.append("absolute_ceiling_missed")
        }
        return errors
    }
}
