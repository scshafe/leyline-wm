// Read-only floorplan lens over projected frames: cells, collinear merged edges
// with divider provenance, stack inventory and nested path closure.
import Foundation

public enum Floorplan {
    // ── P::closure — iterative DFS over children; returns the seen-id set.
    // Consumers iterate it via jq `keys`, which SORTS — sortedKeys mirrors that.
    public static func closure(_ nodes: JSONObject, seeds: [String]) -> Set<String> {
        var seen = Set<String>()
        var stack = seeds
        while let x = stack.popLast() {
            if seen.contains(x) { continue }
            seen.insert(x)
            stack += (nodes[x]?.objectValue?["children"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        return seen
    }

    // ── P::paths_to — every root→target path following children (cycle-guarded).
    public static func pathsTo(_ nodes: JSONObject, root: String?, target: String) -> [[String]] {
        guard let root else { return [] }
        func go(_ id: String, _ seen: [String]) -> [[String]] {
            if seen.contains(id) { return [] }
            if id == target { return [[id]] }
            let s = seen + [id]
            let kids = (nodes[id]?.objectValue?["children"]?.arrayValue ?? []).compactMap(\.stringValue)
            return kids.flatMap { go($0, s) }.map { [id] + $0 }
        }
        return go(root, [])
    }

    // ── P::descriptor_specificity.
    public static func descriptorSpecificity(_ b: JSONValue?) -> Int {
        let o = b?.objectValue ?? [:]
        if o["document_path"] != nil { return 3 }
        if o["title_pattern"] != nil { return 2 }
        if o["ordinal"] != nil { return 1 }
        return 0
    }

    public struct FPCell {
        public let leafId: String
        public let frame: Frame
    }

    // ── FP::_cells — presented leaves with a real frame, sorted [x, y, leaf_id].
    static func cells(_ proj: ProjectResult) -> [FPCell] {
        proj.leaves
            .compactMap { (lid, leaf) -> FPCell? in
                guard leaf.presented, let f = leaf.desiredFrame else { return nil }
                return FPCell(leafId: lid, frame: f)
            }
            .sortedStableBy { .array([.double($0.frame.x), .double($0.frame.y), .string($0.leafId)]) }
    }

    // ── FP::_presentable — every stack ancestor presents the path's child.
    static func presentable(_ nodes: JSONObject, _ path: [String]) -> Bool {
        guard path.count > 1 else { return true }
        for i in 0..<(path.count - 1) {
            let p = nodes[path[i]]?.objectValue ?? [:]
            if (p["mode"]?.stringValue ?? "region") == "stack" {
                let kids = (p["children"]?.arrayValue ?? []).compactMap(\.stringValue)
                let top = p["top"]?.stringValue ?? kids.first
                if path[i + 1] != top { return false }
            }
        }
        return true
    }

    // ── FP::_lca — LCA of the lex-first presentable root→leaf paths.
    static func lca(_ nodes: JSONObject, _ rootId: String?, _ a: String, _ b: String) -> String? {
        func firstPath(_ leaf: String) -> [String]? {
            pathsTo(nodes, root: rootId, target: leaf)
                .filter { presentable(nodes, $0) }
                .sortedStableBy { .string($0.joined(separator: "/")) }
                .first
        }
        guard let pa = firstPath(a), let pb = firstPath(b) else { return nil }
        var n = 0
        for i in 0..<min(pa.count, pb.count) {
            if pa[i] == pb[i] { n = i + 1 } else { break }
        }
        return n == 0 ? nil : pa[n - 1]
    }

    public struct Edge {
        public var axis: String
        public var coord: Double
        public var bandLo: Double
        public var bandHi: Double
        public var spanLo: Double
        public var spanHi: Double
        public var lowCells: [String]
        public var highCells: [String]
        public var dividers: [String]
    }

    // ── FP::_raw_edge — one adjacent pair's divider, or nil (LCA-gated).
    static func rawEdge(_ nodes: JSONObject, _ rootId: String?, _ gap: Double, _ tol: Double,
                        _ c1: FPCell, _ c2: FPCell) -> Edge? {
        let lcaId = lca(nodes, rootId, c1.leafId, c2.leafId)
        let lmode = lcaId.flatMap { nodes[$0]?.objectValue?["mode"]?.stringValue } ?? (lcaId == nil ? "region" : "region")
        let fa = c1.frame
        let fb = c2.frame
        if lmode == "row", Geometry.overlapY(fa, fb) > tol {
            let (l, r) = fa.x <= fb.x ? (c1, c2) : (c2, c1)
            let lo = l.frame.maxX
            let hi = r.frame.x
            guard hi - lo >= -tol, hi - lo <= gap + tol else { return nil }
            return Edge(
                axis: "v", coord: (lo + hi) / 2, bandLo: min(lo, hi), bandHi: max(lo, hi),
                spanLo: max(l.frame.y, r.frame.y), spanHi: min(l.frame.maxY, r.frame.maxY),
                lowCells: [l.leafId], highCells: [r.leafId], dividers: lcaId.map { [$0] } ?? []
            )
        }
        if lmode == "col", Geometry.overlapX(fa, fb) > tol {
            let (t, b) = fa.y <= fb.y ? (c1, c2) : (c2, c1)
            let lo = t.frame.maxY
            let hi = b.frame.y
            guard hi - lo >= -tol, hi - lo <= gap + tol else { return nil }
            return Edge(
                axis: "h", coord: (lo + hi) / 2, bandLo: min(lo, hi), bandHi: max(lo, hi),
                spanLo: max(t.frame.x, b.frame.x), spanHi: min(t.frame.maxX, b.frame.maxX),
                lowCells: [t.leafId], highCells: [b.leafId], dividers: lcaId.map { [$0] } ?? []
            )
        }
        return nil
    }

    // ── FP::_gap_filled — a presented cell fills the perpendicular gap interval.
    static func gapFilled(_ cells: [FPCell], _ axis: String, _ coord: Double, _ lo: Double, _ hi: Double) -> Bool {
        cells.contains { c in
            let f = c.frame
            if axis == "v" {
                return f.x <= coord && coord < f.maxX && (min(f.maxY, hi) - max(f.y, lo)) > 0
            }
            return f.y <= coord && coord < f.maxY && (min(f.maxX, hi) - max(f.x, lo)) > 0
        }
    }

    // ── FP::_edges — raw pairs → per-axis coord clusters → span merge.
    static func edges(_ cells: [FPCell], _ nodes: JSONObject, _ rootId: String?,
                      _ gap: Double, _ tol: Double) -> [Edge] {
        var raws: [Edge] = []
        for i in 0..<cells.count {
            for j in (i + 1)..<cells.count {
                if let e = rawEdge(nodes, rootId, gap, tol, cells[i], cells[j]) {
                    raws.append(e)
                }
            }
        }
        // group_by(.axis) sorts by the grouping key ("h" < "v").
        var merged: [Edge] = []
        for axis in ["h", "v"] {
            let byCoord = raws.filter { $0.axis == axis }.sortedStableBy { .double($0.coord) }
            // cluster anchored to each cluster's FIRST coord.
            var clusters: [[Edge]] = []
            for e in byCoord {
                if var last = clusters.last, let anchor = last.first, abs(e.coord - anchor.coord) <= tol {
                    last.append(e)
                    clusters[clusters.count - 1] = last
                } else {
                    clusters.append([e])
                }
            }
            for cluster in clusters {
                let s = cluster.sortedStableBy { .double($0.spanLo) }
                var acc: [Edge] = []
                for e in s {
                    if var m = acc.last,
                       e.spanLo - m.spanHi <= gap + tol,
                       !gapFilled(cells, m.axis, m.coord, m.spanHi, e.spanLo) {
                        m.spanLo = min(m.spanLo, e.spanLo)
                        m.spanHi = max(m.spanHi, e.spanHi)
                        m.bandLo = min(m.bandLo, e.bandLo)
                        m.bandHi = max(m.bandHi, e.bandHi)
                        m.lowCells += e.lowCells
                        m.highCells += e.highCells
                        m.dividers += e.dividers
                        acc[acc.count - 1] = m
                    } else {
                        acc.append(e)
                    }
                }
                merged += acc
            }
        }
        merged = merged.map { e in
            var e = e
            e.lowCells = e.lowCells.map { JSONValue.string($0) }.jqUnique().compactMap(\.stringValue)
            e.highCells = e.highCells.map { JSONValue.string($0) }.jqUnique().compactMap(\.stringValue)
            e.dividers = e.dividers.map { JSONValue.string($0) }.jqUnique().compactMap(\.stringValue)
            return e
        }
        return merged.sortedStableBy { .array([.string($0.axis), .double($0.coord), .double($0.spanLo)]) }
    }

    /// Collinear floorplan edges with projected root/cell provenance.
    public static func floorplanEdges(tree: JSONValue, topo: JSONValue, tol: Double = 4) -> [Edge] {
        let T = Project.normTopology(topo)
        let proj = Project.project(tree: tree, topo: topo)
        let fpcells = cells(proj)
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        return edges(fpcells, nodes, tree.at(path: "root_id")?.stringValue, T.gap, tol)
    }

    public struct StackEntry {
        public let node: String
        public let source: JSONValue
        public let depth: Int
        public let nesting: Int
        public let top: String?
        public let members: [String]
    }

    // ── FP::_stack_nesting — stack ancestors above the lex-first path.
    static func stackNesting(_ nodes: JSONObject, _ rootId: String?, _ sid: String) -> Int {
        let path = pathsTo(nodes, root: rootId, target: sid)
            .sortedStableBy { .string($0.joined(separator: "/")) }
            .first
        guard let path else { return 0 }
        return path.dropLast().filter {
            (nodes[$0]?.objectValue?["mode"]?.stringValue ?? "region") == "stack"
        }.count
    }

    // ── FP::stacks — the queryable stack inventory, sorted by node id.
    public static func stacks(tree: JSONValue) -> [StackEntry] {
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        let rootId = tree.at(path: "root_id")?.stringValue
        return nodes
            .compactMap { (sid, node) -> StackEntry? in
                guard let n = node.objectValue,
                      (n["mode"]?.stringValue ?? "region") == "stack" else { return nil }
                let kids = (n["children"]?.arrayValue ?? []).compactMap(\.stringValue)
                return StackEntry(
                    node: sid,
                    source: n["stack_source"] ?? .null,
                    depth: kids.count,
                    nesting: stackNesting(nodes, rootId, sid),
                    top: n["top"]?.stringValue ?? kids.first,
                    members: kids
                )
            }
            .sortedStableBy { .string($0.node) }
    }
}
