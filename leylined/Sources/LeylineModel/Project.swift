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
    public let main: Bool
}

public struct NormTopology: Sendable {
    public let displays: [NormDisplay]
    public let deadZones: [Frame]
    public let gap: Double
    /// Outer usable-canvas reservation is independent of interior gutters.
    /// Missing outer_gap retains the legacy gap-inset policy for port/parity callers.
    public let outerGap: Double
    public let hasExplicitOuterGap: Bool
}

public struct LeafProjection: Sendable {
    public let presented: Bool
    public let desiredFrame: Frame?
    public let conformance: String
    public let overflow: Bool
    public let vacant: Bool
}

public struct ProjectResult: Sendable {
    public let leaves: [String: LeafProjection]
    public let contention: [String]
    public let vacant: [String]
    public let deadZoneHits: [String]
}

public enum Project {
    // ── P::norm_topology ─────────────────────────────────────────────────
    public static func normTopology(_ topo: JSONValue) -> NormTopology {
        let o = topo.objectValue ?? [:]
        let displays = (o["displays"]?.arrayValue ?? []).map { d -> NormDisplay in
            let dd = d.objectValue ?? [:]
            let frame = (Frame.from(dd["frame"]) ?? Frame(x: 0, y: 0, w: 0, h: 0)).rounded()
            let usable = (Frame.from(coalesce(dd["usable"], dd["frame"])) ?? Frame(x: 0, y: 0, w: 0, h: 0)).rounded()
            return NormDisplay(
                id: dd["id"]?.intValue,
                frame: frame,
                usable: usable,
                main: dd["main"]?.boolValue ?? false
            )
        }
        let deadZones = (o["dead_zones"]?.arrayValue ?? []).compactMap { Frame.from($0)?.rounded() }
        let gap = o["gap"]?.numberValue ?? 0
        let outerGap = o["outer_gap"]?.numberValue
        return NormTopology(displays: displays, deadZones: deadZones, gap: gap,
                            outerGap: outerGap ?? gap, hasExplicitOuterGap: outerGap != nil)
    }

    // ── P::display_usable ────────────────────────────────────────────────
    static func displayUsable(_ T: NormTopology, _ dispId: Int64?) -> Frame? {
        T.displays.first(where: { $0.id == dispId })?.usable
    }

    // ── P::remap_absent_displays (pinned mounts on missing displays → main) ─
    static func remapAbsentDisplays(_ nodes: JSONObject, _ T: NormTopology) -> JSONObject {
        let live = Set(T.displays.compactMap(\.id))
        let main = (T.displays.first(where: \.main) ?? T.displays.first)?.id
        guard let main else { return nodes }
        var out = nodes
        for (id, node) in nodes {
            guard var o = node.objectValue,
                  o["frame_source"]?.stringValue == "pinned",
                  let did = o["display_id"]?.intValue,
                  !live.contains(did) else { continue }
            o["display_id"] = .int(main)
            out[id] = .object(o)
        }
        return out
    }

    // ── P::covers_any ────────────────────────────────────────────────────
    static func coversAny(_ f: Frame?, _ displays: [NormDisplay]) -> Bool {
        guard let f else { return false }
        return displays.contains {
            Geometry.overlapX(f, $0.frame) > 0 && Geometry.overlapY(f, $0.frame) > 0
        }
    }

    // ── P::canvas_rect ───────────────────────────────────────────────────
    static func canvasRect(_ T: NormTopology) -> Frame {
        let union = Geometry.union(T.displays.map(\.usable)) ?? Frame(x: 0, y: 0, w: 0, h: 0)
        return Geometry.inset(union, by: T.outerGap) ?? union
    }

    // ── P::split_slots (edge-rounded proportional split with gap gutters) ─
    static func splitSlots(_ lo: Double, _ size: Double, _ ratios: [Double], _ gap: Double) -> [(lo: Double, hi: Double)] {
        let cnt = ratios.count
        let sum = ratios.reduce(0, +)
        let tot = sum == 0 ? 1 : sum
        let avail = max(size - gap * Double(max(cnt - 1, 0)), 0)
        var cum: [Double] = [0]
        var acc = 0.0
        for r in ratios {
            acc += r
            cum.append(acc)
        }
        return (0..<cnt).map { i -> (lo: Double, hi: Double) in
            let precedingGap = gap * Double(i)
            let lowerOffset = avail * cum[i] / tot
            let upperOffset = avail * cum[i + 1] / tot
            return (lo: (lo + lowerOffset + precedingGap).rounded(),
                    hi: (lo + upperOffset + precedingGap).rounded())
        }
    }

    // ── P::leaf_fit_min (0-default fit-min, NOT the 160×120 diagnostic) ──
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

    // ── P::subtree_min ───────────────────────────────────────────────────
    static func subtreeMin(_ nodes: JSONObject, _ id: String, _ gap: Double) -> (w: Double, h: Double) {
        guard let n = nodes[id]?.objectValue else { return (0, 0) }
        let kids = (n["children"]?.arrayValue ?? []).compactMap(\.stringValue)
        if kids.isEmpty { return leafFitMin(n) }
        let mode = n["mode"]?.stringValue ?? "region"
        let cm = kids.map { subtreeMin(nodes, $0, gap) }
        let cnt = Double(kids.count)
        switch mode {
        case "row":
            return (cm.map(\.w).reduce(0, +) + gap * (cnt - 1), cm.map(\.h).max() ?? 0)
        case "col":
            return (cm.map(\.w).max() ?? 0, cm.map(\.h).reduce(0, +) + gap * (cnt - 1))
        default:
            return (cm.map(\.w).max() ?? 0, cm.map(\.h).max() ?? 0)
        }
    }

    // ── P::fit_sizes (1-D min-fit solver) ────────────────────────────────
    static func fitSizes(_ sizes: [Double], _ mins: [Double]) -> [Double] {
        let avail = sizes.reduce(0, +)
        let tmin = mins.reduce(0, +)
        if tmin <= 0 || tmin > avail { return sizes }
        let deficit = zip(mins, sizes).map { max($0 - $1, 0) }.reduce(0, +)
        if deficit <= 0 { return sizes }
        let slacks = zip(sizes, mins).map { max($0 - $1, 0) }
        let tslack = slacks.reduce(0, +)
        return (0..<sizes.count).map { i in
            if mins[i] - sizes[i] > 0 { return mins[i] }
            if tslack > 0 && slacks[i] > 0 { return sizes[i] - deficit * (slacks[i] / tslack) }
            return sizes[i]
        }
    }

    struct ChildSlot {
        let childId: String
        let frame: Frame?
        let selected: Bool
    }

    // ── P::child_slots ───────────────────────────────────────────────────
    static func childSlots(_ nodes: JSONObject, _ T: NormTopology, _ n: JSONObject, _ frame: Frame) -> [ChildSlot] {
        let kids = (n["children"]?.arrayValue ?? []).compactMap(\.stringValue)
        let cnt = kids.count
        let mode = n["mode"]?.stringValue ?? "region"
        let gap = T.gap

        var ratios: [Double]
        if let r = n["ratios"]?.arrayValue, r.count == cnt, cnt > 0 {
            ratios = r.map { $0.numberValue ?? 0 }
        } else {
            ratios = Array(repeating: 1, count: cnt)
        }

        var slots0: [(lo: Double, hi: Double)]?
        switch mode {
        case "row": slots0 = splitSlots(frame.x, frame.w, ratios, gap)
        case "col": slots0 = splitSlots(frame.y, frame.h, ratios, gap)
        default: slots0 = nil
        }

        // Min-fit re-lay (Piece 2b) — VETOED for hand-pinned ratios (I4);
        // pinned/authored children held inert (min = their current slot).
        var slots = slots0
        if let s0 = slots0, (n["ratio_source"]?.stringValue ?? "computed") != "pinned" {
            let sizes = s0.map { $0.hi - $0.lo }
            let mins = (0..<cnt).map { i -> Double in
                let fs = nodes[kids[i]]?.objectValue?["frame_source"]?.stringValue ?? "computed"
                guard fs == "computed" else { return sizes[i] }
                let sm = subtreeMin(nodes, kids[i], gap)
                return mode == "row" ? sm.w : sm.h
            }
            let adj = fitSizes(sizes, mins)
            let origin = mode == "row" ? frame.x : frame.y
            var relaid: [(lo: Double, hi: Double)] = []
            var cum = 0.0
            for i in 0..<cnt {
                let b = cum
                cum += adj[i]
                relaid.append((lo: (origin + b + gap * Double(i)).rounded(),
                               hi: (origin + b + adj[i] + gap * Double(i)).rounded()))
            }
            slots = relaid
        }

        return (0..<cnt).map { i in
            let cid = kids[i]
            let cn = nodes[cid]?.objectValue ?? [:]
            let fs = cn["frame_source"]?.stringValue ?? "computed"
            var computed: Frame
            switch mode {
            case "row":
                computed = Frame(x: slots![i].lo, y: frame.y, w: slots![i].hi - slots![i].lo, h: frame.h)
            case "col":
                computed = Frame(x: frame.x, y: slots![i].lo, w: frame.w, h: slots![i].hi - slots![i].lo)
            default:
                computed = frame
            }
            var slot: Frame?
            switch fs {
            case "pinned":
                slot = Geometry.inset(displayUsable(T, cn["display_id"]?.intValue), by: T.outerGap)
            case "authored":
                slot = Frame.from(cn["frame"])?.rounded()
            default:
                slot = computed
            }
            let selected: Bool
            if mode == "stack" {
                let top = n["top"]?.stringValue ?? kids.first
                selected = cid == top
            } else {
                selected = true
            }
            return ChildSlot(childId: cid, frame: slot, selected: selected)
        }
    }

    struct Visit {
        let leafId: String
        let node: JSONObject
        let frame: Frame?
        let presented: Bool
        let path: [String]
    }

    // ── P::project_walk (cycle-guarded root→leaf path enumeration) ───────
    static func projectWalk(_ nodes: JSONObject, _ T: NormTopology, _ id: String,
                            _ frame: Frame?, _ presented: Bool, _ path: [String]) -> [Visit] {
        if path.contains(id) { return [] }
        guard let n = nodes[id]?.objectValue else {
            return [Visit(leafId: id, node: [:], frame: frame, presented: presented, path: path + [id])]
        }
        let p = path + [id]
        let kids = (n["children"]?.arrayValue ?? []).compactMap(\.stringValue)
        if kids.isEmpty {
            return [Visit(leafId: id, node: n, frame: frame, presented: presented, path: p)]
        }
        // An internal node with a nil frame is unreachable in well-formed
        // trees (remap_absent_displays re-homes the pinned case; jq would
        // hard-error here) — returning [] keeps the port total.
        guard let frame else { return [] }
        var out: [Visit] = []
        for s in childSlots(nodes, T, n, frame) {
            out += projectWalk(nodes, T, s.childId, s.frame, presented && s.selected, p)
        }
        return out
    }

    // ── P::project ───────────────────────────────────────────────────────
    public static func project(tree: JSONValue, topo: JSONValue) -> ProjectResult {
        let T = normTopology(topo)
        let rawNodes: JSONObject = tree.at(path: "nodes")?.objectValue ?? [:]
        let nodes = remapAbsentDisplays(rawNodes, T)
        let root = tree.at(path: "root_id")?.stringValue
        let canvas = canvasRect(T)

        var visits: [Visit] = []
        if let root, nodes[root] != nil {
            visits = projectWalk(nodes, T, root, canvas, true, [])
        }

        var byLeaf: [String: [Visit]] = [:]
        for v in visits {
            byLeaf[v.leafId, default: []].append(v)
        }

        var leaves: [String: LeafProjection] = [:]
        var contention: [String] = []
        var vacant: [String] = []
        var deadZoneHits: [String] = []

        for (lid, group) in byLeaf {
            let ln = group[0].node
            let pres = group.filter(\.presented)
            let win = pres.sorted { $0.path.joined(separator: "/") < $1.path.joined(separator: "/") }.first
            let contended = pres.count > 1
            let isPres = pres.count >= 1
            let bound = coalesce(ln["window_id"]) != nil
            let isVacant = ln["binding"] != nil && coalesce(ln["window_id"]) == nil
            let wf = win?.frame
            let placeable = bound && isPres && wf != nil
            let m = Geometry.minSize(coalesce(ln["min_size"], ln["binding"]?.objectValue?["min_size"]))
            let ovf = placeable ? (wf!.w < m.w || wf!.h < m.h) : false
            let dead = placeable ? !coversAny(wf, T.displays) : false
            let reach = placeable ? reachBump(wf!, leafFitMin(ln)) : nil

            leaves[lid] = LeafProjection(
                presented: isPres,
                desiredFrame: reach,
                conformance: ln["conformance"]?.stringValue ?? "conforming",
                overflow: ovf,
                vacant: isVacant
            )
            if contended { contention.append(lid) }
            if isVacant { vacant.append(lid) }
            if dead { deadZoneHits.append(lid) }
        }

        return ProjectResult(
            leaves: leaves,
            contention: Array(Set(contention)).sorted(),
            vacant: Array(Set(vacant)).sorted(),
            deadZoneHits: Array(Set(deadZoneHits)).sorted()
        )
    }

    // ── R::reconcile_targets (project ⋈ tree.nodes window ids) ───────────
    public static func reconcileTargets(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let proj = project(tree: tree, topo: topo)
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        var out: JSONObject = [:]
        for (lid, leaf) in proj.leaves {
            guard let widValue = coalesce(nodes[lid]?.objectValue?["window_id"]),
                  let wid = widValue.intValue else { continue }
            out[String(wid)] = .object([
                "window_id": widValue,
                "presented": .bool(leaf.presented),
                "frame": leaf.desiredFrame?.json ?? .null,
            ])
        }
        return .object(out)
    }
}
