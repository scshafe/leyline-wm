// Arrangement atom-grid, per-display allocation, bridge and target projections.
// Raw segment JSON preserves variant fields while typed accessors perform math.
import Foundation

extension JSONValue {
    static func number(_ d: Double) -> JSONValue {
        if d == d.rounded(), abs(d) < 9_007_199_254_740_992 {
            return .int(Int64(d))
        }
        return .double(d)
    }
}

public struct Seg {
    public var raw: JSONObject
    public var axis: String
    public var coord: Double
    public var lo: Double
    public var hi: Double

    public init?(_ v: JSONValue) {
        guard let o = v.objectValue,
              let axis = o["axis"]?.stringValue,
              let coord = o["coord"]?.numberValue,
              let lo = o["lo"]?.numberValue,
              let hi = o["hi"]?.numberValue else { return nil }
        self.raw = o
        self.axis = axis
        self.coord = coord
        self.lo = lo
        self.hi = hi
    }

    init(axis: String, coord: Double, lo: Double, hi: Double, extra: JSONObject = [:]) {
        var o = extra
        o["axis"] = .string(axis)
        o["coord"] = .number(coord)
        o["lo"] = .number(lo)
        o["hi"] = .number(hi)
        self.raw = o
        self.axis = axis
        self.coord = coord
        self.lo = lo
        self.hi = hi
    }

    public var json: JSONValue {
        var o = raw
        o["axis"] = .string(axis)
        o["coord"] = .number(coord)
        o["lo"] = .number(lo)
        o["hi"] = .number(hi)
        return .object(o)
    }
}

public enum Arrangement {
    static let tol = 4.0

    // ── helpers: TOL-deduped sorted axis, DSU ────────────────────────────
    static func dedupSorted(_ coords: [Double]) -> [Double] {
        var out: [Double] = []
        for c in coords.sorted() {
            if let last = out.last, abs(c - last) <= tol { continue }
            out.append(c)
        }
        return out
    }

    struct DSU {
        var parent: [Int: Int] = [:]

        func find(_ a: Int) -> Int {
            var cur = a
            while let p = parent[cur], p != cur { cur = p }
            return cur
        }

        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
    }

    // ── compress / covered / components / cells ──────────────────────────
    static func compress(_ arr: [Seg], _ canvas: Frame) -> (xs: [Double], ys: [Double]) {
        let vs = arr.filter { $0.axis == "v" }
        let hs = arr.filter { $0.axis == "h" }
        let xs = dedupSorted([canvas.x, canvas.maxX] + vs.map(\.coord) + hs.flatMap { [$0.lo, $0.hi] })
        let ys = dedupSorted([canvas.y, canvas.maxY] + hs.map(\.coord) + vs.flatMap { [$0.lo, $0.hi] })
        return (xs, ys)
    }

    static func covered(_ arr: [Seg], _ axis: String, _ coord: Double, _ lo: Double, _ hi: Double) -> Bool {
        let mid = (lo + hi) / 2
        return arr.contains {
            $0.axis == axis && abs($0.coord - coord) <= tol && $0.lo - tol <= mid && mid <= $0.hi + tol
        }
    }

    public struct Comp {
        public var atoms: [[Int]]
        public var i0: Int
        public var i1: Int
        public var j0: Int
        public var j1: Int
        public var filled: Bool
        public var frame: Frame
        public var displayId: Int64?
        public var path: [[Int]] = []

        public func json(extra: JSONObject = [:]) -> JSONValue {
            var o: JSONObject = [
                "atoms": .array(atoms.map { .array([.int(Int64($0[0])), .int(Int64($0[1]))]) }),
                "i0": .int(Int64(i0)), "i1": .int(Int64(i1)),
                "j0": .int(Int64(j0)), "j1": .int(Int64(j1)),
                "filled": .bool(filled),
                "frame": frame.json,
            ]
            if let displayId { o["display_id"] = .int(displayId) }
            if !path.isEmpty {
                o["path"] = .array(path.map { .array([.int(Int64($0[0])), .int(Int64($0[1]))]) })
            }
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
    }

    static func components(_ arr: [Seg], _ canvas: Frame) -> [Comp] {
        let g = compress(arr, canvas)
        let xs = g.xs
        let ys = g.ys
        let nx = xs.count - 1
        let ny = ys.count - 1
        if nx <= 0 || ny <= 0 {
            return [Comp(atoms: [[0, 0]], i0: 0, i1: 0, j0: 0, j1: 0, filled: true,
                         frame: Frame(x: canvas.x, y: canvas.y, w: canvas.w, h: canvas.h),
                         displayId: nil)]
        }
        var dsu = DSU()
        for i in 0..<nx {
            for j in 0..<ny {
                let a = i * ny + j
                if i + 1 < nx, !covered(arr, "v", xs[i + 1], ys[j], ys[j + 1]) {
                    dsu.union(a, (i + 1) * ny + j)
                }
                if j + 1 < ny, !covered(arr, "h", ys[j + 1], xs[i], xs[i + 1]) {
                    dsu.union(a, i * ny + (j + 1))
                }
            }
        }
        var comp: [Int: [[Int]]] = [:]
        for i in 0..<nx {
            for j in 0..<ny {
                comp[dsu.find(i * ny + j), default: []].append([i, j])
            }
        }
        let out = comp.values.map { atoms -> Comp in
            let i0 = atoms.map { $0[0] }.min()!
            let i1 = atoms.map { $0[0] }.max()!
            let j0 = atoms.map { $0[1] }.min()!
            let j1 = atoms.map { $0[1] }.max()!
            return Comp(
                atoms: atoms.sorted { a, b in a[0] != b[0] ? a[0] < b[0] : a[1] < b[1] },
                i0: i0, i1: i1, j0: j0, j1: j1,
                filled: atoms.count == (i1 - i0 + 1) * (j1 - j0 + 1),
                frame: Frame(x: xs[i0], y: ys[j0], w: xs[i1 + 1] - xs[i0], h: ys[j1 + 1] - ys[j0]),
                displayId: nil
            )
        }
        return out.sortedStableBy {
            .array([.double($0.frame.y), .double($0.frame.x), .double($0.frame.w), .double($0.frame.h)])
        }
    }

    public static func cells(_ arr: [Seg], _ canvas: Frame) -> [Comp] {
        components(arr, canvas).sortedStableBy { .array([.double($0.frame.y), .double($0.frame.x)]) }
    }

    // ── _partition_facts / valid ─────────────────────────────────────────
    public static func valid(_ arr: [Seg], _ canvas: Frame) -> JSONValue {
        let g = compress(arr, canvas)
        let nx = g.xs.count - 1
        let ny = g.ys.count - 1
        let comps = components(arr, canvas)
        var claimed = Set<[Int]>()
        for c in comps where c.filled {
            for i in c.i0...c.i1 {
                for j in c.j0...c.j1 { claimed.insert([i, j]) }
            }
        }
        var unclaimed: [[Int]] = []
        if nx > 0 && ny > 0 {
            for i in 0..<nx {
                for j in 0..<ny where !claimed.contains([i, j]) { unclaimed.append([i, j]) }
            }
        }
        let nonrect = comps.filter { !$0.filled }
            .map { c -> JSONValue in
                .object(["kind": .string("non_rectangular"), "frame": c.frame.json,
                         "atoms": .int(Int64(c.atoms.count)),
                         "box": .int(Int64((c.i1 - c.i0 + 1) * (c.j1 - c.j0 + 1)))])
            }
            .sortedStableBy { v in
                let f = v.objectValue?["frame"]?.objectValue ?? [:]
                return .array([f["y"] ?? .null, f["x"] ?? .null])
            }
        var gaps: [JSONValue] = []
        let gridAtoms = max(nx, 0) * max(ny, 0)
        let claimedCount = claimed.count
        if nx > 0 && ny > 0 && claimedCount != gridAtoms {
            let i0 = unclaimed.map { $0[0] }.min()!
            let i1 = unclaimed.map { $0[0] }.max()!
            let j0 = unclaimed.map { $0[1] }.min()!
            let j1 = unclaimed.map { $0[1] }.max()!
            let missing = unclaimed.reduce(0.0) { acc, a in
                acc + (g.xs[a[0] + 1] - g.xs[a[0]]) * (g.ys[a[1] + 1] - g.ys[a[1]])
            }
            gaps = [.object(["kind": .string("gap"), "missing_area": .number(missing),
                             "frame": Frame(x: g.xs[i0], y: g.ys[j0],
                                            w: g.xs[i1 + 1] - g.xs[i0],
                                            h: g.ys[j1 + 1] - g.ys[j0]).json])]
        }
        let violations = nonrect + gaps
        return .object(["ok": .bool(violations.isEmpty), "violations": .array(violations)])
    }

    // ── incident ─────────────────────────────────────────────────────────
    public static func incident(_ arr: [Seg], _ canvas: Frame, _ line: Seg) -> [Comp] {
        cells(arr, canvas).filter { c in
            let f = c.frame
            if line.axis == "v" {
                return (abs(f.x - line.coord) <= tol || abs(f.maxX - line.coord) <= tol)
                    && f.maxY > line.lo && f.y < line.hi
            }
            return (abs(f.y - line.coord) <= tol || abs(f.maxY - line.coord) <= tol)
                && f.maxX > line.lo && f.x < line.hi
        }
    }

    // ── _inset_interior / _segment_in_rect ───────────────────────────────
    static func insetInterior(_ f: Frame, _ canvas: Frame, _ gap: Double) -> Frame {
        let hg = gap / 2
        let nx0 = abs(f.x - canvas.x) <= tol ? f.x : f.x + hg
        let nx1 = abs(f.maxX - canvas.maxX) <= tol ? f.maxX : f.maxX - hg
        let ny0 = abs(f.y - canvas.y) <= tol ? f.y : f.y + hg
        let ny1 = abs(f.maxY - canvas.maxY) <= tol ? f.maxY : f.maxY - hg
        return Frame(x: nx0, y: ny0, w: nx1 - nx0, h: ny1 - ny0)
    }

    static func segmentInRect(_ seg: Seg, _ rect: Frame) -> Bool {
        let x0 = rect.x - tol
        let x1 = rect.maxX + tol
        let y0 = rect.y - tol
        let y1 = rect.maxY + tol
        if seg.axis == "v" {
            return seg.coord >= x0 && seg.coord <= x1 && seg.lo >= y0 && seg.hi <= y1
        }
        return seg.coord >= y0 && seg.coord <= y1 && seg.lo >= x0 && seg.hi <= x1
    }

    // ── per-display bags ─────────────────────────────────────────────────
    public struct Bag {
        public let displayId: Int64?
        public let segments: [Seg]
        public let rect: Frame?
    }

    public static func canvasList(_ T: NormTopology) -> [Bag] {
        T.displays.map {
            Bag(displayId: $0.id, segments: [],
                rect: Geometry.inset(Project.displayUsable(T, $0.id), by: T.outerGap))
        }
    }

    static func segmentPoint(_ seg: Seg) -> Frame {
        let (cx, cy) = seg.axis == "v"
            ? (seg.coord, (seg.lo + seg.hi) / 2)
            : ((seg.lo + seg.hi) / 2, seg.coord)
        return Frame(x: cx - tol, y: cy - tol, w: 2 * tol, h: 2 * tol)
    }

    public static func bagsWithRejected(_ segments: [Seg], _ T: NormTopology) -> (bags: [Bag], rejected: [Seg]) {
        let cv = canvasList(T)
        var homes: [Int64: [Seg]] = [:]
        var rejected: [Seg] = []
        for seg in segments {
            let home = Geometry.assignDisplay(segmentPoint(seg), T.displays)
            let hb = cv.first { $0.displayId == home }
            if let home, let hb, let rect = hb.rect, segmentInRect(seg, rect) {
                homes[home, default: []].append(seg)
            } else {
                rejected.append(seg)
            }
        }
        let bags = cv.map {
            Bag(displayId: $0.displayId,
                segments: $0.displayId.flatMap { homes[$0] } ?? [],
                rect: $0.rect)
        }
        return (bags, rejected)
    }

    public static func bags(_ segments: [Seg], _ T: NormTopology) -> [Bag] {
        bagsWithRejected(segments, T).bags
    }

    public static func cellsMd(_ segments: [Seg], _ T: NormTopology) -> [Comp] {
        var out: [Comp] = []
        for bag in bags(segments, T) {
            guard let rect = bag.rect else { continue }
            for var c in cells(bag.segments, rect) {
                c.displayId = bag.displayId
                out.append(c)
            }
        }
        return out.sortedStableBy {
            .array([$0.displayId.map { JSONValue.int($0) } ?? .null,
                    .double($0.frame.y), .double($0.frame.x)])
        }
    }

    public static func validMd(_ segments: [Seg], _ T: NormTopology) -> JSONValue {
        var pd: [JSONValue] = []
        var allOk = true
        for bag in bags(segments, T) {
            guard let rect = bag.rect else { continue }
            let v = valid(bag.segments, rect)
            let ok = v.objectValue?["ok"]?.boolValue ?? false
            allOk = allOk && ok
            pd.append(.object([
                "display_id": bag.displayId.map { JSONValue.int($0) } ?? .null,
                "ok": .bool(ok),
                "violations": v.objectValue?["violations"] ?? .array([]),
            ]))
        }
        return .object(["ok": .bool(allOk), "per_display": .array(pd)])
    }

    // ── from_floorplan (composes the floorplan lens) ─────────────────────
    public static func fromFloorplan(tree: JSONValue, topo: JSONValue) -> [Seg] {
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        let edges = Floorplan.floorplanEdges(tree: tree, topo: topo, tol: tol)
        var segs: [Seg] = edges.map { e in
            let pinned = !e.dividers.isEmpty && e.dividers.allSatisfy {
                (nodes[$0]?.objectValue?["ratio_source"]?.stringValue ?? "computed") == "pinned"
            }
            return Seg(axis: e.axis, coord: e.coord, lo: e.spanLo, hi: e.spanHi,
                       extra: pinned ? ["relation": .string("pinned")] : [:])
        }
        let T = Project.normTopology(topo)
        let gap = T.gap
        segs = segs.map { seg in
            var seg = seg
            let home = Geometry.assignDisplay(segmentPoint(seg), T.displays)
            let r = Geometry.inset(Project.displayUsable(T, home), by: T.outerGap)
            if gap > 0, let r {
                let hg = gap / 2
                let (b0, b1) = seg.axis == "v" ? (r.y, r.maxY) : (r.x, r.maxX)
                if abs(seg.lo - b0) > tol { seg.lo -= hg }
                if abs(seg.hi - b1) > tol { seg.hi += hg }
            }
            return seg
        }
        return segs.sortedStableBy { .array([.string($0.axis), .double($0.coord), .double($0.lo)]) }
    }

    public static func equiv(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let cv = Project.canvasRect(T)
        let segs = fromFloorplan(tree: tree, topo: topo)
        let frames = cells(segs, cv).map { insetInterior($0.frame, cv, T.gap) }
        return .array(frames
            .sortedStableBy { .array([.double($0.x), .double($0.y), .double($0.w), .double($0.h)]) }
            .map(\.json))
    }

    public static func bridgeMdEquiv(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let segs = fromFloorplan(tree: tree, topo: topo)
        var frames: [Frame] = []
        for bag in bags(segs, T) {
            guard let rect = bag.rect else { continue }
            frames += cells(bag.segments, rect).map { insetInterior($0.frame, rect, T.gap) }
        }
        return .array(frames
            .sortedStableBy { .array([.double($0.x), .double($0.y), .double($0.w), .double($0.h)]) }
            .map(\.json))
    }

    // ── anchor / rekey ───────────────────────────────────────────────────
    static func anchorKey(_ c: Comp) -> String {
        "\(c.displayId ?? 0):\(c.i0):\(c.j0)"
    }

    static func entryTopWid(_ e: JSONValue?) -> Int64? {
        guard let o = e?.objectValue else { return nil }
        if let c0 = o["contents"]?.arrayValue?.first?.objectValue?["window_id"], let w = c0.intValue {
            return w
        }
        return o["window_id"].flatMap { $0 == .null ? nil : $0.intValue }
    }

    static func isectArea(_ a: Frame, _ b: Frame) -> Double {
        let iw = min(a.maxX, b.maxX) - max(a.x, b.x)
        let ih = min(a.maxY, b.maxY) - max(a.y, b.y)
        return iw > 0 && ih > 0 ? iw * ih : 0
    }

    static func rekeyResolve(_ cells: [(lk: String, frame: Frame)], _ b: JSONObject) -> JSONObject {
        var claimed = Set<String>()
        for c in cells where entryTopWid(b[c.lk]) != nil {
            claimed.insert(c.lk)
        }
        let U = cells.filter { entryTopWid(b[$0.lk]) == nil }
        var V: [(wid: Int64, frame: Frame, entry: JSONValue)] = []
        for (bk, bv) in b {  // jq: $b | to_entries[] — insertion order (stable-sort tie-break)
            guard let wid = entryTopWid(bv), !claimed.contains(bk),
                  (bv.objectValue?["nested"]?.objectValue?["segments"]?.arrayValue ?? []).isEmpty,
                  let frame = Frame.from(bv.objectValue?["contents"]?.arrayValue?.first?.objectValue?["frame"]
                      ?? bv.objectValue?["frame"]) else { continue }
            V.append((wid, frame, bv))
        }
        var pairs: [(ov: Double, ck: String, wid: Int64, entry: JSONValue)] = []
        for c in U {
            for v in V {
                let ov = isectArea(c.frame, v.frame)
                if ov > 0 { pairs.append((ov, c.lk, v.wid, v.entry)) }
            }
        }
        let sorted = pairs.sortedStableBy { .array([.double(-$0.ov), .int($0.wid), .string($0.ck)]) }
        var usedC = Set<String>()
        var usedW = Set<Int64>()
        var map: JSONObject = [:]
        for p in sorted where !usedC.contains(p.ck) && !usedW.contains(p.wid) {
            usedC.insert(p.ck)
            usedW.insert(p.wid)
            map[p.ck] = p.entry
        }
        return map
    }

    // ── bridge_arrangement ───────────────────────────────────────────────
    public static func bridgeArrangement(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let segs = fromFloorplan(tree: tree, topo: topo)
        let proj = Project.project(tree: tree, topo: topo)
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        let mdCells = cellsMd(segs, T)

        // leaves iterate in leaf_id-sorted order (jq's insertion order there).
        var bound: [(entry: JSONObject, presented: Bool, frame: Frame?)] = []
        for lid in proj.leaves.keys.sorted() {
            let leaf = proj.leaves[lid]!
            guard let widV = nodes[lid]?.objectValue?["window_id"], widV != .null else { continue }
            var e: JSONObject = [
                "window_id": widV,
                "presented": .bool(leaf.presented),
                "frame": leaf.desiredFrame?.json ?? .null,
            ]
            if let ms = nodes[lid]?.objectValue?["min_size"], ms != .null {
                e["min_size"] = ms
            }
            bound.append((e, leaf.presented, leaf.desiredFrame))
        }

        var bindings: JSONObject = [:]
        for b in bound where b.presented && b.frame != nil {
            let f = b.frame!
            let cx = f.x + f.w / 2
            let cy = f.y + f.h / 2
            guard let cell = mdCells.first(where: {
                $0.frame.x <= cx && cx <= $0.frame.maxX && $0.frame.y <= cy && cy <= $0.frame.maxY
            }) else { continue }
            var e = b.entry
            e["contents"] = .array([.object(b.entry)])
            bindings[anchorKey(cell)] = .object(e)
        }
        let offTop = bound.filter { !($0.presented && $0.frame != nil) }.map { JSONValue.object($0.entry) }
        return .object([
            "segments": .array(segs.map(\.json)),
            "bindings": .object(bindings),
            "off_top": .array(offTop),
        ])
    }

    // ── bridge_arrangement_folded ────────────────────────────────────────
    public static func bridgeArrangementFolded(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        let base = bridgeArrangement(tree: tree, topo: topo).objectValue ?? [:]
        let proj = Project.project(tree: tree, topo: topo)

        func isLeaf(_ id: String) -> Bool {
            (nodes[id]?.objectValue?["children"]?.arrayValue ?? []).isEmpty
        }

        var folds: [(top: Int64, surplus: [Int64])] = []
        for s in Floorplan.stacks(tree: tree) {
            let seeds = s.top.map { [$0] } ?? []
            _ = seeds
            let dleaves = Floorplan.closure(nodes, seeds: [s.node]).sorted().filter {
                isLeaf($0) && (nodes[$0]?.objectValue?["window_id"].map { $0 != .null } ?? false)
            }
            let presented = dleaves.filter { proj.leaves[$0]?.presented == true }
            let hidden = dleaves.filter { proj.leaves[$0]?.presented != true }
            let top = presented.compactMap { nodes[$0]?.objectValue?["window_id"]?.intValue }.first
            let surplus = hidden.compactMap { nodes[$0]?.objectValue?["window_id"]?.intValue }.sorted()
            if let top, !surplus.isEmpty { folds.append((top, surplus)) }
        }

        var bindings2: JSONObject = [:]
        for (k, v) in base["bindings"]?.objectValue ?? [:] {
            let topWid = entryTopWid(v)
            if let f = folds.first(where: { $0.top == topWid }) {
                var o = v.objectValue ?? [:]
                var contents = o["contents"]?.arrayValue ?? [{
                    var bare = o
                    bare.removeValue(forKey: "contents")
                    bare.removeValue(forKey: "nested")
                    return .object(bare)
                }()]
                contents += f.surplus.map {
                    .object(["window_id": .int($0), "presented": .bool(false), "frame": .null])
                }
                o["contents"] = .array(contents)
                bindings2[k] = .object(o)
            } else {
                bindings2[k] = v
            }
        }
        let routed = Set(folds.flatMap(\.surplus))
        let offTop2 = (base["off_top"]?.arrayValue ?? []).filter {
            guard let w = $0.objectValue?["window_id"]?.intValue else { return true }
            return !routed.contains(w)
        }
        return .object([
            "segments": base["segments"] ?? .array([]),
            "bindings": .object(bindings2),
            "off_top": .array(offTop2),
        ])
    }

    // ── arrangement_targets (depth-0 emitter) ────────────────────────────
    public static func parseSegs(_ v: JSONValue?) -> [Seg] {
        (v?.arrayValue ?? []).compactMap { Seg($0) }
    }

    static func stripMinSize(_ m: JSONObject) -> JSONObject {
        m.mapValues { v in
            guard var o = v.objectValue else { return v }
            o.removeValue(forKey: "min_size")
            return .object(o)
        }
    }

    static func emitLeafEntry(into acc: inout JSONObject, _ entry: JSONValue?, dropNested: Bool) {
        guard let entry, entry != .null else { return }
        let cs = entry.objectValue?["contents"]
        if let arr = cs?.arrayValue, arr.count > 1 {
            if let w0 = arr[0].objectValue?["window_id"], w0 != .null, let wid = w0.intValue {
                acc[String(wid)] = arr[0]
            }
            for s in arr.dropFirst() {
                guard let w = s.objectValue?["window_id"], w != .null, let wid = w.intValue else { continue }
                var o = s.objectValue ?? [:]
                o["presented"] = .bool(false)
                o["frame"] = .null
                acc[String(wid)] = .object(o)
            }
        } else {
            var b: JSONValue?
            if let arr = cs?.arrayValue, !arr.isEmpty {
                b = arr[0]
            } else {
                var o = entry.objectValue ?? [:]
                o.removeValue(forKey: "contents")
                if dropNested { o.removeValue(forKey: "nested") }
                b = .object(o)
            }
            guard let b, let w = b.objectValue?["window_id"], w != .null, let wid = w.intValue else { return }
            acc[String(wid)] = b
        }
    }

    public static func arrangementTargets(bridge: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let b = bridge.at(path: "bindings")?.objectValue ?? [:]
        let cs = cellsMd(parseSegs(bridge.at(path: "segments")), T).map { (lk: anchorKey($0), frame: $0.frame) }
        let fallback = rekeyResolve(cs, b)
        var acc: JSONObject = [:]
        for c in cs {
            emitLeafEntry(into: &acc, b[c.lk] ?? fallback[c.lk], dropNested: false)
        }
        for o in bridge.at(path: "off_top")?.arrayValue ?? [] {
            guard let w = o.objectValue?["window_id"], w != .null, let wid = w.intValue else { continue }
            acc[String(wid)] = o
        }
        return .object(stripMinSize(acc))
    }

    // ── stack attributes ─────────────────────────────────────────────────
    static func topRegionOrigin(_ nodes: JSONObject, _ proj: ProjectResult, _ topId: String?) -> (x: Double, y: Double)? {
        guard let topId else { return nil }
        let frames = Floorplan.closure(nodes, seeds: [topId]).sorted().compactMap { id -> Frame? in
            guard (nodes[id]?.objectValue?["children"]?.arrayValue ?? []).isEmpty,
                  proj.leaves[id]?.presented == true else { return nil }
            return proj.leaves[id]?.desiredFrame
        }
        guard !frames.isEmpty else { return nil }
        return (frames.map(\.x).min()!, frames.map(\.y).min()!)
    }

    public static func cellsStack(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let segs = fromFloorplan(tree: tree, topo: topo)
        let mdCells = cellsMd(segs, T)
        let nodes = tree.at(path: "nodes")?.objectValue ?? [:]
        let proj = Project.project(tree: tree, topo: topo)
        let attrs = Floorplan.stacks(tree: tree).map { s in
            (origin: topRegionOrigin(nodes, proj, s.top), stack: s)
        }
        let out = mdCells.map { c -> JSONValue in
            let hit = attrs.first {
                guard let o = $0.origin else { return false }
                return abs(o.x - c.frame.x) <= tol && abs(o.y - c.frame.y) <= tol
            }
            let stackJson: JSONValue = hit.map {
                .object(["members": .array($0.stack.members.map { .string($0) }),
                         "top": $0.stack.top.map { .string($0) } ?? .null,
                         "source": $0.stack.source,
                         "depth": .int(Int64($0.stack.depth))])
            } ?? .null
            return c.json(extra: ["stack": stackJson])
        }
        return .array(out)
    }

    public static func validStack(tree: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        return validMd(fromFloorplan(tree: tree, topo: topo), T)
    }

    // ── the nesting lens ─────────────────────────────────────────────────
    static func segInteriorTo(_ seg: Seg, _ R: Frame) -> Bool {
        if seg.axis == "v" {
            return R.x + tol < seg.coord && seg.coord < R.maxX - tol
                && seg.lo >= R.y - tol && seg.hi <= R.maxY + tol
        }
        return R.y + tol < seg.coord && seg.coord < R.maxY - tol
            && seg.lo >= R.x - tol && seg.hi <= R.maxX + tol
    }

    static func bboxContains(_ outer: Frame, _ inner: Frame) -> Bool {
        outer.x - tol <= inner.x && inner.maxX <= outer.maxX + tol
            && outer.y - tol <= inner.y && inner.maxY <= outer.maxY + tol
            && outer.w * outer.h > inner.w * inner.h
    }

    static func promotionParent(_ p: JSONValue, _ promos: [JSONValue]) -> JSONValue {
        guard let pcm = Frame.from(p.objectValue?["coord_map"]) else { return .null }
        let candidates = promos.filter { q in
            guard !JQOrder.equal(q.objectValue?["id"] ?? .null, p.objectValue?["id"] ?? .null),
                  let qcm = Frame.from(q.objectValue?["coord_map"]) else { return false }
            return bboxContains(qcm, pcm)
        }
        let best = candidates.sortedStableBy { q in
            let f = Frame.from(q.objectValue?["coord_map"])!
            return .double(f.w * f.h)
        }.first
        return best?.objectValue?["id"] ?? .null
    }

    static func frameMinInRect(_ frame: JSONValue?, _ R: Frame) -> Bool {
        guard let f = Frame.from(frame) else { return false }
        return f.x >= R.x - tol && f.x < R.maxX - tol && f.y >= R.y - tol && f.y < R.maxY - tol
    }

    static func regionCell(_ segs: [Seg], _ R: Frame, _ top: Bool, _ T: NormTopology, _ canvas: Frame?) -> Comp? {
        let cs: [Comp]
        if top {
            cs = cellsMd(segs, T)
        } else {
            guard let canvas else { return nil }
            cs = cells(segs, canvas).map { c in
                var c = c
                c.displayId = 0
                return c
            }
        }
        return cs.first {
            abs($0.frame.x - R.x) <= tol && abs($0.frame.y - R.y) <= tol
                && abs($0.frame.w - R.w) <= tol && abs($0.frame.h - R.h) <= tol
        }
    }

    static func rehomeBlockBindings(_ block: [(key: String, binding: JSONValue)], _ interior: [Seg], _ R: Frame) -> JSONObject {
        let ccells = cells(interior, R).map { c -> Comp in
            var c = c
            c.displayId = 0
            return c
        }
        var out: JSONObject = [:]
        for bk in block {  // jq: reduce $block[] — caller order (to_entries insertion)
            guard let f = Frame.from(bk.binding.objectValue?["frame"]) else { continue }
            let bcx = f.x + f.w / 2
            let bcy = f.y + f.h / 2
            guard let cc = ccells.first(where: {
                $0.frame.x <= bcx && bcx <= $0.frame.maxX && $0.frame.y <= bcy && bcy <= $0.frame.maxY
            }) else { continue }
            let ck = anchorKey(cc)
            if let existing = out[ck] {
                func electKey(_ v: JSONValue) -> JSONValue {
                    let o = v.objectValue ?? [:]
                    return .array([
                        .int(Int64(-Floorplan.descriptorSpecificity(o["binding"]))),
                        o["binding"]?.objectValue?["ordinal"] ?? .int(1_000_000),
                        o["window_id"] ?? .int(1_000_000),
                    ])
                }
                let winner = [existing, bk.binding].sortedStableBy(electKey).first!
                out[ck] = winner
            } else {
                out[ck] = bk.binding
            }
        }
        return out
    }

    struct NestBag {
        var segments: [Seg]
        var bindings: JSONObject
        var offTop: [JSONValue]
    }

    static func deriveAt(_ bag: NestBag, _ promos: [JSONValue], _ parentId: JSONValue,
                         _ top: Bool, _ T: NormTopology, _ canvas: Frame?) -> NestBag {
        let here = promos
            .filter { JQOrder.equal(promotionParent($0, promos), parentId) }
            .sortedStableBy { q in
                let f = Frame.from(q.objectValue?["coord_map"])!
                return .double(f.w * f.h)
            }
        if here.isEmpty { return bag }
        let levelSegs = bag.segments.filter { s in
            !here.contains { p in
                guard let R = Frame.from(p.objectValue?["coord_map"]) else { return false }
                return segInteriorTo(s, R)
            }
        }
        var acc = bag
        acc.segments = levelSegs
        for p in here {
            guard let R = Frame.from(p.objectValue?["coord_map"]) else { continue }
            let interior = bag.segments.filter { segInteriorTo($0, R) }
            guard let cell = regionCell(levelSegs, R, top, T, canvas) else { continue }
            let key = anchorKey(cell)
            let block = acc.bindings
                .filter { (_, v) in
                    v.objectValue?["presented"]?.boolValue == true
                        && (v.objectValue?["frame"].map { $0 != .null } ?? false)
                        && frameMinInRect(v.objectValue?["frame"], R)
                }
                .map { (key: $0.key, binding: $0.value) }
            let relocated = rehomeBlockBindings(block, interior, R)
            let child = deriveAt(
                NestBag(segments: interior, bindings: relocated, offTop: []),
                promos, p.objectValue?["id"] ?? .null, false, T, R
            )
            for bkey in block.map(\.key) {
                acc.bindings.removeValue(forKey: bkey)
            }
            acc.bindings[key] = .object(["nested": .object([
                "segments": .array(child.segments.map(\.json)),
                "bindings": .object(child.bindings),
                "off_top": .array(child.offTop),
            ])])
        }
        return acc
    }

    public static func deriveNested(arr: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let promos = (arr.at(path: "promotions")?.arrayValue ?? []).filter {
            let cm = $0.objectValue?["coord_map"]?.objectValue
            return cm?["w"]?.numberValue != nil && cm?["h"]?.numberValue != nil
                && (cm?["w"].map { if case .string = $0 { return false } else { return true } } ?? false)
                && (cm?["h"].map { if case .string = $0 { return false } else { return true } } ?? false)
        }
        if promos.isEmpty { return arr }
        let d = deriveAt(
            NestBag(segments: parseSegs(arr.at(path: "segments")),
                    bindings: arr.at(path: "bindings")?.objectValue ?? [:],
                    offTop: arr.at(path: "off_top")?.arrayValue ?? []),
            promos, .null, true, T, nil
        )
        return .object([
            "segments": .array(d.segments.map(\.json)),
            "bindings": .object(d.bindings),
            "off_top": .array(d.offTop),
        ])
    }

    // ── cells_rec ────────────────────────────────────────────────────────
    static func cellsRecAt(_ segments: [Seg], _ bindings: JSONObject,
                           _ cv: Frame, _ did: Int64, _ path: [[Int]]) -> [Comp] {
        var out: [Comp] = []
        for var c in cells(segments, cv) {
            c.displayId = did
            let localkey = "\(did):\(c.i0):\(c.j0)"
            let kid = bindings[localkey]?.objectValue?["nested"]?.objectValue
            if let kid, !(kid["segments"]?.arrayValue ?? []).isEmpty {
                out += cellsRecAt(parseSegs(kid["segments"]), kid["bindings"]?.objectValue ?? [:],
                                  c.frame, 0, path + [[c.i0, c.j0]])
            } else {
                c.path = path
                out.append(c)
            }
        }
        return out
    }

    public static func cellsRec(arr: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let bindings = arr.at(path: "bindings")?.objectValue ?? [:]
        var out: [Comp] = []
        for bag in bags(parseSegs(arr.at(path: "segments")), T) {
            guard let rect = bag.rect else { continue }
            out += cellsRecAt(bag.segments, bindings, rect, bag.displayId ?? 0, [])
        }
        let sorted = out.sortedStableBy {
            .array([$0.displayId.map { JSONValue.int($0) } ?? .null,
                    .double($0.frame.y), .double($0.frame.x)])
        }
        return .array(sorted.map { $0.json() })
    }

    // ── arrangement_targets_rec ──────────────────────────────────────────
    static func emitAt(_ segments: [Seg], _ bindings: JSONObject, _ offTop: [JSONValue],
                       _ cv: Frame, _ did: Int64, _ path: [[Int]]) -> JSONObject {
        let cs = cells(segments, cv).map { c -> (lk: String, frame: Frame) in
            ("\(did):\(c.i0):\(c.j0)", c.frame)
        }
        let fallback = rekeyResolve(cs, bindings)
        var acc: JSONObject = [:]
        for c in cs {
            let entry = bindings[c.lk] ?? fallback[c.lk]
            let nested = entry?.objectValue?["nested"]?.objectValue
            if let nested, !(nested["segments"]?.arrayValue ?? []).isEmpty {
                let sub = emitAt(parseSegs(nested["segments"]), nested["bindings"]?.objectValue ?? [:],
                                 nested["off_top"]?.arrayValue ?? [], c.frame, 0, path)
                acc.merge(sub) { _, new in new }
            } else {
                emitLeafEntry(into: &acc, entry, dropNested: true)
            }
        }
        for o in offTop {
            guard let w = o.objectValue?["window_id"], w != .null, let wid = w.intValue else { continue }
            acc[String(wid)] = o
        }
        return acc
    }

    public static func arrangementTargetsRec(bridge: JSONValue, topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let bindings = bridge.at(path: "bindings")?.objectValue ?? [:]
        var acc: JSONObject = [:]
        for bag in bags(parseSegs(bridge.at(path: "segments")), T) {
            guard let rect = bag.rect else { continue }
            let sub = emitAt(bag.segments, bindings, [], rect, bag.displayId ?? 0, [])
            acc.merge(sub) { _, new in new }
        }
        for o in bridge.at(path: "off_top")?.arrayValue ?? [] {
            guard let w = o.objectValue?["window_id"], w != .null, let wid = w.intValue else { continue }
            acc[String(wid)] = o
        }
        return .object(stripMinSize(acc))
    }

    public static func anchorKeyPublic(_ cell: JSONValue) -> String {
        let o = cell.objectValue ?? [:]
        let did = o["display_id"]?.intValue ?? 0
        return "\(did):\(o["i0"]?.intValue ?? 0):\(o["j0"]?.intValue ?? 0)"
    }
}
