// Arrangement atom-grid, per-display allocation, bridge and target projections.
// Raw segment JSON preserves variant fields while typed accessors perform math.
import Foundation

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

    init(axis: String, coord: Double, lo: Double, hi: Double) {
        var o: JSONObject = [:]
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
    /// Two coordinates within this many points are the same gridline, and a frame
    /// edge within it lies on its canvas edge. The planner's collinearity and
    /// adjacency tests and `Geometry.frameEq`'s default share it.
    public static let coordinateTolerance = 4.0
    static let tol = coordinateTolerance
    /// Targets are rounded to whole points before they are written, so a size or
    /// edge that misses by at most half a point still fits, and two model frames
    /// within half a point are the same frame.
    public static let fitSlack = 0.5
    /// A cut that would move by less than this is already in place.
    static let cutEpsilon = 0.000_001

    /// Whether `need` fits in `span` within the rounding slack.
    static func fits(_ need: Double, in span: Double) -> Bool { need <= span + fitSlack }

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

    /// Collinear pieces that overlap store one cut redundantly; each overlapping group becomes
    /// its union, kept at the position and fields of its first piece. Pieces that only abut stay
    /// separate, since each can move on its own. Without overlap the input is returned unchanged.
    public static func mergingOverlaps(_ segs: [Seg]) -> [Seg] {
        func overlaps(_ a: Seg, _ b: Seg) -> Bool {
            a.axis == b.axis && abs(a.coord - b.coord) <= tol && min(a.hi, b.hi) - max(a.lo, b.lo) > tol
        }
        var out: [Seg] = []
        for seg in segs {
            var merged = seg, index = out.count
            while let hit = out.indices.first(where: { overlaps(out[$0], merged) }) {
                let kept = out.remove(at: hit)
                var union = hit < index ? kept : merged
                union.lo = min(kept.lo, merged.lo); union.hi = max(kept.hi, merged.hi)
                merged = union; index = min(index, hit)
            }
            out.insert(merged, at: min(index, out.count))
        }
        return out
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

        public func json() -> JSONValue {
            var o: JSONObject = [
                "atoms": .array(atoms.map { .array([.int(Int64($0[0])), .int(Int64($0[1]))]) }),
                "i0": .int(Int64(i0)), "i1": .int(Int64(i1)),
                "j0": .int(Int64(j0)), "j1": .int(Int64(j1)),
                "filled": .bool(filled),
                "frame": frame.json,
            ]
            if let displayId { o["display_id"] = .int(displayId) }
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

    /// `components` already orders by (y, x, w, h); a stable (y, x) re-sort is the identity.
    public static func cells(_ arr: [Seg], _ canvas: Frame) -> [Comp] {
        components(arr, canvas)
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

    // ── _inset_interior / _segment_in_rect ───────────────────────────────
    public static func insetInterior(_ f: Frame, _ canvas: Frame, _ gap: Double) -> Frame {
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

    /// The cells of `segments` under a JSON topology (normalised here).
    public static func cellsMd(_ segments: [Seg], topology: JSONValue) -> [Comp] {
        cellsMd(segments, Project.normTopology(topology))
    }

    /// The cells of a parcel's own `segments` under a JSON topology.
    public static func bagCells(_ bag: JSONValue, topology: JSONValue) -> [Comp] {
        cellsMd(parseSegs(bag.at(path: "segments")), topology: topology)
    }

    /// Whether `segments` partition every display of `topology` into rectangles.
    public static func segmentsValid(_ segments: [Seg], topology: JSONValue) -> Bool {
        validMd(segments, Project.normTopology(topology)).at(path: "ok")?.boolValue == true
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

    // ── anchor / rekey ───────────────────────────────────────────────────
    /// The canonical `display:i0:j0` binding anchor of a grid cell.
    public static func anchorKey(_ c: Comp) -> String {
        "\(c.displayId ?? 0):\(c.i0):\(c.j0)"
    }

    static func entryTopWid(_ e: JSONValue?) -> Int64? {
        guard let o = e?.objectValue else { return nil }
        if let c0 = o["contents"]?.arrayValue?.first?.objectValue?["window_id"], let w = c0.intValue {
            return w
        }
        return o["window_id"].flatMap { $0 == .null ? nil : $0.intValue }
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
                let ov = Geometry.intersectionArea(c.frame, v.frame)
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
            if let w0 = arr[0].objectValue?["window_id"], let wid = w0.intValue {
                acc[String(wid)] = arr[0]
            }
            for s in arr.dropFirst() {
                guard let w = s.objectValue?["window_id"], let wid = w.intValue else { continue }
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
            guard let b, let w = b.objectValue?["window_id"], let wid = w.intValue else { return }
            acc[String(wid)] = b
        }
    }

    // ── arrangement_targets_rec ──────────────────────────────────────────
    static func emitAt(_ segments: [Seg], _ bindings: JSONObject, _ offTop: [JSONValue],
                       _ cv: Frame, _ did: Int64) -> JSONObject {
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
                                 nested["off_top"]?.arrayValue ?? [], c.frame, 0)
                acc.merge(sub) { _, new in new }
            } else {
                emitLeafEntry(into: &acc, entry, dropNested: true)
            }
        }
        for o in offTop {
            guard let w = o.objectValue?["window_id"], let wid = w.intValue else { continue }
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
            let sub = emitAt(bag.segments, bindings, [], rect, bag.displayId ?? 0)
            acc.merge(sub) { _, new in new }
        }
        for o in bridge.at(path: "off_top")?.arrayValue ?? [] {
            guard let w = o.objectValue?["window_id"], let wid = w.intValue else { continue }
            acc[String(wid)] = o
        }
        return .object(stripMinSize(acc))
    }
}
