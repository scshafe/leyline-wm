// Pure topology normalization, tree projection and reconcile-target joins.
// Oracle rounding and minimum-size overflow dialects remain explicit.
import Foundation

private func coalesce(_ values: JSONValue?...) -> JSONValue? {
    for v in values {
        if let v, v != .null { return v }
    }
    return nil
}

public struct NormDisplay: Sendable {
    public let id: Int64?
    public let frame: Frame
    public let usable: Frame
}

public struct NormTopology: Sendable {
    public let displays: [NormDisplay]
    public let gap: Double
    /// Outer usable-canvas reservation is independent of interior gutters.
    /// Missing outer_gap retains the legacy gap-inset policy for port/parity callers.
    public let outerGap: Double
    public let hasExplicitOuterGap: Bool
}

public enum Project {
    // ── P::norm_topology ─────────────────────────────────────────────────
    public static func normTopology(_ topo: JSONValue) -> NormTopology {
        let o = topo.objectValue ?? [:]
        let displays = (o["displays"]?.arrayValue ?? []).map { d -> NormDisplay in
            let dd = d.objectValue ?? [:]
            let frame = (Frame.from(dd["frame"]) ?? Frame(x: 0, y: 0, w: 0, h: 0)).rounded()
            let usable = (Frame.from(coalesce(dd["usable"], dd["frame"])) ?? Frame(x: 0, y: 0, w: 0, h: 0)).rounded()
            return NormDisplay(id: dd["id"]?.intValue, frame: frame, usable: usable)
        }
        let gap = o["gap"]?.numberValue ?? 0
        let outerGap = o["outer_gap"]?.numberValue
        return NormTopology(displays: displays, gap: gap,
                            outerGap: outerGap ?? gap, hasExplicitOuterGap: outerGap != nil)
    }

    // ── P::display_usable ────────────────────────────────────────────────
    static func displayUsable(_ T: NormTopology, _ dispId: Int64?) -> Frame? {
        T.displays.first(where: { $0.id == dispId })?.usable
    }

    // ── P::leaf_fit_min — a binding's known minimum, 0 on each unknown axis ──
    static func leafFitMin(_ n: JSONObject) -> (w: Double, h: Double) {
        let ms = coalesce(n["min_size"], n["binding"]?.objectValue?["min_size"])?.objectValue ?? [:]
        return (ms["w"]?.numberValue ?? 0, ms["h"]?.numberValue ?? 0)
    }

    // ── P::reach_bump — THE one min-size clamp dialect of the author path ─
    static func reachBump(_ frame: Frame, _ min: (w: Double, h: Double)) -> Frame {
        var f = frame
        f.w = max(f.w, min.w)
        f.h = max(f.h, min.h)
        return f
    }

}
