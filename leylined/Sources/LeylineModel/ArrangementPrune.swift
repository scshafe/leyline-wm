// Canonical prune, reclaim and native arrangement bridges. Every candidate
// respects membership conservation and minimum-size constraints before authoring.
import Foundation

extension Arrangement {
    // ── P::slide_under (parcel.jq:211) — the demoted-frame author ────────
    static func slideUnder(_ cell: Frame, _ mn: (w: Double, h: Double), _ face: String, _ R: Frame) -> Frame {
        let w = max(mn.w, cell.w)
        let h = max(mn.h, cell.h)
        var f: Frame
        switch face {
        case "left": f = Frame(x: cell.x + cell.w - w, y: cell.y, w: w, h: h)
        case "right": f = Frame(x: cell.x, y: cell.y, w: w, h: h)
        case "above": f = Frame(x: cell.x, y: cell.y + cell.h - h, w: w, h: h)
        default: f = Frame(x: cell.x, y: cell.y, w: w, h: h)
        }
        f.x = max(min(f.x, R.x + R.w - f.w), R.x)
        f.y = max(min(f.y, R.y + R.h - f.h), R.y)
        return f
    }

    // ── helpers: _span_minus / _reclaim_edit / _reclaim_grow_edit ─────────
    static func spanMinus(_ lo: Double, _ hi: Double, _ a: Double, _ b: Double) -> [(lo: Double, hi: Double)] {
        var out: [(Double, Double)] = []
        if a - lo > tol { out.append((lo, a)) }
        if hi - b > tol { out.append((b, hi)) }
        return out
    }

    static func reclaimEdit(_ segs: [Seg], _ g: Frame, _ dir: String) -> (segs: [Seg], local: Bool)? {
        let fc: (axis: String, coord: Double, a: Double, b: Double)
        switch dir {
        case "below": fc = ("h", g.maxY, g.x, g.maxX)
        case "above": fc = ("h", g.y, g.x, g.maxX)
        case "right": fc = ("v", g.maxX, g.y, g.maxY)
        default: fc = ("v", g.x, g.y, g.maxY)
        }
        let hits = segs.enumerated().filter { (_, s) in
            s.axis == fc.axis && abs(s.coord - fc.coord) <= tol
                && s.lo <= fc.a + tol && s.hi >= fc.b - tol
        }
        guard hits.count == 1, let h = hits.first else { return nil }
        let rem = spanMinus(h.element.lo, h.element.hi, fc.a, fc.b)
        var out = segs.enumerated().filter { $0.offset != h.offset }.map(\.element)
        for r in rem {
            var s = h.element
            s.lo = r.lo
            s.hi = r.hi
            out.append(s)
        }
        return (out, rem.isEmpty)
    }

    static func reclaimGrowEdit(_ segs: [Seg], _ g: Frame, _ dir: String) -> [Seg]? {
        let fc: (axis: String, coord: Double, sl: Double, sh: Double, pax: String, near: Double, far: Double, extLo: Bool)
        switch dir {
        case "below": fc = ("h", g.maxY, g.x, g.maxX, "v", g.maxY, g.y, true)
        case "above": fc = ("h", g.y, g.x, g.maxX, "v", g.y, g.maxY, false)
        case "right": fc = ("v", g.maxX, g.y, g.maxY, "h", g.maxX, g.x, true)
        default: fc = ("v", g.x, g.y, g.maxY, "h", g.x, g.maxX, false)
        }
        let hits = segs.enumerated().filter { (_, s) in
            s.axis == fc.axis && abs(s.coord - fc.coord) <= tol
                && s.lo <= fc.sl + tol && s.hi >= fc.sh - tol
        }
        guard hits.count == 1, let h = hits.first else { return nil }
        let rem = spanMinus(h.element.lo, h.element.hi, fc.sl, fc.sh)
        func qualifies(_ s: Seg) -> Bool {
            s.axis == fc.pax && s.coord > fc.sl + tol && s.coord < fc.sh - tol
                && (fc.extLo ? abs(s.lo - fc.near) <= tol : abs(s.hi - fc.near) <= tol)
        }
        guard segs.contains(where: qualifies) else { return nil }
        var out: [Seg] = []
        for (idx, s) in segs.enumerated() where idx != h.offset {
            var s = s
            if qualifies(s) {
                if fc.extLo { s.lo = fc.far } else { s.hi = fc.far }
            }
            out.append(s)
        }
        for r in rem {
            var s = h.element
            s.lo = r.lo
            s.hi = r.hi
            out.append(s)
        }
        return out
    }

    // ── _prune_rekey — centre-containment survivor re-key, display-scoped ─
    static func pruneRekey(_ newSegs: [Seg], _ T: NormTopology,
                           _ surv: [(key: String, value: JSONValue)]) -> JSONObject? {
        let nc = cellsMd(newSegs, T)
        var m: JSONObject = [:]
        for b in surv {
            guard let f = Frame.from(b.value.objectValue?["frame"]) else { return nil }
            let cx = f.x + f.w / 2
            let cy = f.y + f.h / 2
            let did = b.key.split(separator: ":").first.map(String.init) ?? ""
            let cand = nc.filter {
                "\($0.displayId ?? 0)" == did
                    && $0.frame.x <= cx && cx <= $0.frame.maxX
                    && $0.frame.y <= cy && cy <= $0.frame.maxY
            }
            guard cand.count == 1 else { return nil }
            let ak = anchorKey(cand[0])
            guard m[ak] == nil else { return nil }
            m[ak] = b.value
        }
        return m.count == surv.count ? m : nil
    }

    // ── _reclaim_run — the shared-gridline strip enumerator ──────────────
    struct Run {
        let spread: String
        let gdid: String
        let plo: Double
        let phi: Double
        let lo: Double
        let hi: Double
        let survivors: [Comp]
        let count: Int
    }

    static func reclaimRun(_ segs: [Seg], _ g: Frame, _ gdid: String, _ T: NormTopology, _ spread: String) -> Run? {
        let cells = cellsMd(segs, T)
        let strip = cells
            .filter { "\($0.displayId ?? 0)" == gdid }
            .filter { c in
                spread == "h"
                    ? abs(c.frame.y - g.y) <= tol && abs(c.frame.maxY - g.maxY) <= tol
                    : abs(c.frame.x - g.x) <= tol && abs(c.frame.maxX - g.maxX) <= tol
            }
            .sortedStableBy { .double(spread == "h" ? $0.frame.x : $0.frame.y) }
        guard strip.count >= 2 else { return nil }
        for i in 0..<(strip.count - 1) {
            let cur = spread == "h" ? strip[i].frame.maxX : strip[i].frame.maxY
            let nxt = spread == "h" ? strip[i + 1].frame.x : strip[i + 1].frame.y
            if abs(nxt - cur) > tol { return nil }
        }
        let plo = spread == "h" ? g.y : g.x
        let phi = spread == "h" ? g.maxY : g.maxX
        let lo = spread == "h" ? strip[0].frame.x : strip[0].frame.y
        let hi = spread == "h" ? strip[strip.count - 1].frame.maxX : strip[strip.count - 1].frame.maxY
        let survc = strip.filter { abs($0.frame.x - g.x) > tol || abs($0.frame.y - g.y) > tol }
        guard strip.count - survc.count == 1 else { return nil }
        return Run(spread: spread, gdid: gdid, plo: plo, phi: phi, lo: lo, hi: hi,
                   survivors: survc, count: survc.count)
    }

    // ── _reclaim_spread_edit — even/proportional run re-spacing ──────────
    static func reclaimSpreadEdit(_ segs: [Seg], _ g: Frame, _ gdid: String, _ T: NormTopology,
                                  _ spread: String, _ binds: JSONObject, _ mode: String)
        -> (segs: [Seg], run: Run)? {
        guard let run = reclaimRun(segs, g, gdid, T, spread) else { return nil }
        let dax = spread == "h" ? "v" : "h"
        let gap = T.gap
        let interior = segs.enumerated().filter { (_, s) in
            s.axis == dax && s.coord > run.lo + tol && s.coord < run.hi - tol
                && s.lo < run.phi - tol && s.hi > run.plo + tol
        }
        guard !interior.isEmpty,
              !interior.contains(where: { $0.element.raw["relation"]?.stringValue == "pinned" }),
              !interior.contains(where: { $0.element.lo < run.plo - gap - tol || $0.element.hi > run.phi + tol })
        else { return nil }
        let N = run.count
        let sizes = run.survivors.map { spread == "h" ? $0.frame.w : $0.frame.h }
        let weights = mode == "proportional" ? sizes : Array(repeating: 1.0, count: N)
        let wsum = weights.reduce(0, +)
        let newsizes = (0..<N).map { (run.hi - run.lo) * (weights[$0] / wsum) }
        for k in 0..<N {
            let e = binds[anchorKey(run.survivors[k])]?.objectValue
            let ms = (e?["min_size"] ?? e?["contents"]?.arrayValue?.first?.objectValue?["min_size"])?.objectValue ?? [:]
            let mn = spread == "h" ? (ms["w"]?.numberValue ?? 0) : (ms["h"]?.numberValue ?? 0)
            if newsizes[k] + tol < mn { return nil }
        }
        let ikeys = Set(interior.map(\.offset))
        let spanLo = interior.map(\.element.lo).min()!
        let spanHi = interior.map(\.element.hi).max()!
        let coords: [Double]
        if mode == "even" {
            coords = (1..<N).map { run.lo + Double($0) * ((run.hi - run.lo) / Double(N)) }
        } else {
            var acc = run.lo
            var ds: [Double] = []
            for k in 0..<(N - 1) {
                acc += newsizes[k]
                ds.append(acc)
            }
            coords = ds
        }
        var out = segs.enumerated().filter { !ikeys.contains($0.offset) }.map(\.element)
        out += coords.map { Seg(axis: dax, coord: $0, lo: spanLo, hi: spanHi) }
        return (out, run)
    }

    // ── _reclaim_even_rekey — ordinal run re-key + centre re-key for the rest ─
    static func reclaimEvenRekey(_ newSegs: [Seg], _ T: NormTopology,
                                 _ surv: [(key: String, value: JSONValue)], _ run: Run) -> JSONObject? {
        let nc = cellsMd(newSegs, T)
        let runcells = nc
            .filter { "\($0.displayId ?? 0)" == run.gdid }
            .filter { c in
                run.spread == "h"
                    ? c.frame.x >= run.lo - tol && c.frame.maxX <= run.hi + tol
                        && c.frame.y >= run.plo - tol && c.frame.maxY <= run.phi + tol
                    : c.frame.y >= run.lo - tol && c.frame.maxY <= run.hi + tol
                        && c.frame.x >= run.plo - tol && c.frame.maxX <= run.phi + tol
            }
            .sortedStableBy { .double(run.spread == "h" ? $0.frame.x : $0.frame.y) }
        let ranch = run.survivors.map { anchorKey($0) }
        guard runcells.count == ranch.count else { return nil }
        var runmap: JSONObject = [:]
        for i in 0..<ranch.count {
            guard let sb = surv.first(where: { $0.key == ranch[i] }) else { continue }
            runmap[anchorKey(runcells[i])] = sb.value
        }
        guard runmap.count == ranch.count else { return nil }
        let rest = surv.filter { !ranch.contains($0.key) }
        var m = runmap
        for b in rest {
            guard let f = Frame.from(b.value.objectValue?["frame"]) else { return nil }
            let cx = f.x + f.w / 2
            let cy = f.y + f.h / 2
            let did = b.key.split(separator: ":").first.map(String.init) ?? ""
            let cand = nc.filter {
                "\($0.displayId ?? 0)" == did
                    && $0.frame.x <= cx && cx <= $0.frame.maxX
                    && $0.frame.y <= cy && cy <= $0.frame.maxY
            }
            guard cand.count == 1 else { return nil }
            let ak = anchorKey(cand[0])
            guard m[ak] == nil else { return nil }
            m[ak] = b.value
        }
        return m.count == surv.count ? m : nil
    }

    // ── _absorber_of ─────────────────────────────────────────────────────
    static func absorberOf(_ candSegs: [Seg], _ candBinds: JSONObject,
                           _ gf: Frame, _ gdid: String, _ T: NormTopology) -> JSONValue {
        let gcx = gf.x + gf.w / 2
        let gcy = gf.y + gf.h / 2
        let acell = cellsMd(candSegs, T).first {
            "\($0.displayId ?? 0)" == gdid
                && $0.frame.x <= gcx && gcx <= $0.frame.maxX
                && $0.frame.y <= gcy && gcy <= $0.frame.maxY
        }
        guard let acell, let wid = candBinds[anchorKey(acell)]?.objectValue?["window_id"], wid != .null else {
            return .null
        }
        return wid
    }

    // ── bridge_arrangement_native — the line-native re-stamp ─────────────
    public static func bridgeArrangementNative(store: JSONValue, topo: JSONValue, frameCanvas: Frame? = nil) -> JSONValue {
        let T = Project.normTopology(topo)
        let gap = T.gap
        let segs = parseSegs(store.at(path: "segments"))
        let pri = store.at(path: "bindings")?.objectValue ?? [:]

        struct NCell {
            let anchor: String
            let frame: Frame
            let allocation: Frame
            let rect: Frame
        }
        var ncells: [NCell] = []
        for bag in bags(segs, T) {
            guard let r = bag.rect else { continue }
            for var c in cells(bag.segments, r) {
                c.displayId = bag.displayId
                ncells.append(NCell(anchor: anchorKey(c), frame: insetInterior(c.frame, frameCanvas ?? r, gap), allocation: c.frame, rect: r))
            }
        }
        let fallback = rekeyResolve(ncells.map { (lk: $0.anchor, frame: $0.frame) }, pri)

        var bindings: JSONObject = [:]
        for c in ncells {
            guard let b = (pri[c.anchor] ?? fallback[c.anchor])?.objectValue else { continue }
            if let nested = b["nested"], nested.objectValue != nil {
                let old = Frame.from(b["allocated_frame"]) ?? c.allocation
                let transformed = transformedOwnerBag(nested, from: old, to: c.allocation)
                let fitted = fittingOwnerMinimums(transformed, canvas: c.allocation, frameCanvas: frameCanvas ?? c.rect, gap: gap)
                var entry = b
                entry["nested"] = bridgeArrangementNative(store: fitted ?? transformed,
                    topo: localTopology(canvas: c.allocation, displayID: 0, gap: gap), frameCanvas: frameCanvas ?? c.rect)
                entry["allocated_frame"] = c.allocation.json
                entry["frame"] = c.frame.json
                bindings[c.anchor] = .object(entry)
                continue
            }
            let minPair = allocationMinimum(.object(b), frame: c.allocation, gap: gap)
            let dfaces = (b["demotable_faces"]?.arrayValue ?? []).compactMap(\.stringValue)
            let belowW = c.frame.w + tol < minPair.w
            let belowH = c.frame.h + tol < minPair.h
            var dface: String?
            if !dfaces.isEmpty && belowW != belowH {
                dface = belowW
                    ? dfaces.first { $0 == "left" || $0 == "right" }
                    : dfaces.first { $0 == "above" || $0 == "below" }
            }
            var under: JSONValue = .null
            if let df = dface {
                let cf = c.frame
                let step = gap + 1
                let p: (x: Double, y: Double)
                switch df {
                case "left": p = (cf.x - step, cf.y + cf.h / 2)
                case "right": p = (cf.x + cf.w + step, cf.y + cf.h / 2)
                case "above": p = (cf.x + cf.w / 2, cf.y - step)
                default: p = (cf.x + cf.w / 2, cf.y + cf.h + step)
                }
                let myDid = c.anchor.split(separator: ":").first
                let nc = ncells.first {
                    $0.anchor != c.anchor
                        && $0.anchor.split(separator: ":").first == myDid
                        && $0.frame.x - tol <= p.x && p.x <= $0.frame.maxX + tol
                        && $0.frame.y - tol <= p.y && p.y <= $0.frame.maxY + tol
                }
                if let nc, let w = pri[nc.anchor]?.objectValue?["window_id"], w != .null {
                    under = w
                }
            }
            let f: Frame
            var dx: JSONObject = [:]
            if let df = dface, under != .null {
                f = slideUnder(c.frame, minPair, df, c.rect)
                dx = ["demoted": .bool(true), "under": under]
            } else {
                f = Project.reachBump(c.frame, minPair)
            }
            let ms = b["min_size"] ?? b["contents"]?.arrayValue?.first?.objectValue?["min_size"]
            var member: JSONObject = [
                "window_id": b["window_id"] ?? .null,
                "presented": .bool(true),
                "frame": f.json,
            ]
            if let ms, ms != .null { member["min_size"] = ms }
            for (k, v) in dx { member[k] = v }
            let isStack = (b["contents"]?.arrayValue?.count ?? 0) > 1
            if isStack {
                member["effect_frame"] = f.json
                member["stack_top_window_id"] = member["window_id"] ?? .null
            }
            var entry = member
            let surplus = (b["contents"]?.arrayValue ?? []).dropFirst().map { value -> JSONValue in
                var hidden = value.objectValue ?? [:]
                hidden["presented"] = .bool(false); hidden["frame"] = .null
                hidden["effect_frame"] = f.json; hidden["stack_top_window_id"] = member["window_id"] ?? .null
                return .object(hidden)
            }
            entry["contents"] = .array([.object(member)] + surplus)
            if !surplus.isEmpty {
                entry["top_window_id"] = member["window_id"] ?? .null
                entry["stack_source"] = b["stack_source"] ?? .string("overload")
            }
            for field in ["overload_reason", "overload_restore", "overload_restore_canvas", "minimum_fit"] {
                if let value = b[field] { entry[field] = value }
            }
            if !dfaces.isEmpty {
                entry["demotable_faces"] = b["demotable_faces"] ?? .array([])
            }
            bindings[c.anchor] = .object(entry)
        }
        var result: JSONObject = [
            "segments": .array(segs.map(\.json)),
            "bindings": .object(bindings),
            "off_top": store.at(path: "off_top") ?? .array([]),
        ]
        if let promotions = store.at(path: "promotions"), promotions.arrayValue?.isEmpty == false {
            result["promotions"] = promotions
        }
        return .object(result)
    }

    // ── bridge_arrangement_native_prune — the dispatch ───────────────────
    public static func bridgeArrangementNativePrune(store: JSONValue, goners: [Int64],
                                                    focused: JSONValue, topo: JSONValue,
                                                    policy: String?) -> JSONValue {
        let T = Project.normTopology(topo)
        let pol = policy ?? "absorber"
        let fw: Int64? = {
            switch focused {
            case .string(let s):
                return Int64(s.hasPrefix("w:") ? String(s.dropFirst(2)) : s)
            case .int(let i):
                return i
            case .double(let d) where d == d.rounded():
                return Int64(d)
            default:
                return nil
            }
        }()
        let segs = parseSegs(store.at(path: "segments"))
        let binds = store.at(path: "bindings")?.objectValue ?? [:]
        guard goners.count == 1 else { return .null }
        let gw = goners[0]
        let sortedBinds = Array(binds)  // jq: to_entries — insertion order (name is historical)
        guard let ge = sortedBinds.first(where: { $0.value.objectValue?["window_id"]?.intValue == gw })
        else { return .null }
        let curCells = cellsMd(segs, T)
        guard let gcell = curCells.first(where: { anchorKey($0) == ge.key }) else { return .null }
        let gf = gcell.frame
        let ncells0 = curCells.count
        let surv = sortedBinds.filter { $0.value.objectValue?["window_id"]?.intValue != gw }
            .map { (key: $0.key, value: $0.value) }
        let gdid = ge.key.split(separator: ":").first.map(String.init) ?? ""

        struct Cand {
            let dir: String
            let local: Bool
            let segs: [Seg]
            let binds: JSONObject
            let spreadAbsorber: JSONValue
        }

        func gated(_ e: [Seg]) -> Bool {
            guard validMd(e, T).objectValue?["ok"]?.boolValue == true else { return false }
            return cellsMd(e, T).count == ncells0 - 1
        }

        var spreadCands: [Cand] = []
        if pol == "even" || pol == "proportional" {
            for sp in ["h", "v"] {
                guard let e = reclaimSpreadEdit(segs, gf, gdid, T, sp, binds, pol), gated(e.segs),
                      let rk = reclaimEvenRekey(e.segs, T, surv, e.run) else { continue }
                var sabs: JSONValue = .null
                if e.run.count == 1 {
                    sabs = binds[anchorKey(e.run.survivors[0])]?.objectValue?["window_id"] ?? .null
                }
                spreadCands.append(Cand(dir: "spread-\(sp)", local: false, segs: e.segs,
                                        binds: rk, spreadAbsorber: sabs))
            }
        }

        let dirs = ["below", "above", "right", "left"]
        var simpleCands: [Cand] = []
        for dir in dirs {
            guard let e = reclaimEdit(segs, gf, dir), gated(e.segs),
                  let rk = pruneRekey(e.segs, T, surv) else { continue }
            simpleCands.append(Cand(dir: dir, local: e.local, segs: e.segs, binds: rk, spreadAbsorber: .null))
        }
        var growCands: [Cand] = []
        if simpleCands.isEmpty {
            for dir in dirs {
                guard let e = reclaimGrowEdit(segs, gf, dir), gated(e),
                      let rk = pruneRekey(e, T, surv) else { continue }
                growCands.append(Cand(dir: dir, local: false, segs: e, binds: rk, spreadAbsorber: .null))
            }
        }
        let validCands = simpleCands.isEmpty ? growCands : simpleCands
        let loc = validCands.filter(\.local)
        let pool = loc.isEmpty ? validCands : loc
        let ord = ["below": 0, "above": 1, "right": 2, "left": 3]

        var focusPick: Cand?
        if pol == "focus", let fw {
            focusPick = pool.first { absorberOf($0.segs, $0.binds, gf, gdid, T).intValue == fw }
        }

        let pick: Cand?
        if let s = spreadCands.first {
            pick = s
        } else if let f = focusPick {
            pick = f
        } else {
            pick = pool.sortedStableBy { .int(Int64(ord[$0.dir] ?? 9)) }.first
        }
        guard let pick else { return .null }

        let absorber: JSONValue = pick.dir.hasPrefix("spread")
            ? pick.spreadAbsorber
            : absorberOf(pick.segs, pick.binds, gf, gdid, T)

        let authored = JSONValue.object([
            "segments": .array(pick.segs.map(\.json)),
            "bindings": .object(pick.binds),
            "off_top": .array([]),
            "promotions": .array([]),
        ])
        return .object([
            "arr": bridgeArrangementNative(store: authored, topo: topo),
            "absorber": absorber,
        ])
    }

    // ── store_valid — the write-gate admission predicate ─────────────────
    public static func storeValid(store: JSONValue) -> JSONValue {
        let topoV = store.at(path: "topology") ?? .object([:])
        let T = Project.normTopology(topoV)
        let partition = validMd(parseSegs(store.at(path: "segments")), T)
        let cellInconsistent = (store.at(path: "bindings")?.objectValue ?? [:]).values.contains { v in
            guard let o = v.objectValue, let cs = o["contents"]?.arrayValue, !cs.isEmpty else { return false }
            let bare = o["window_id"].flatMap { $0 == .null ? nil : $0.intValue }
            let top = cs[0].objectValue?["window_id"].flatMap { $0 == .null ? nil : $0.intValue }
            return bare != top
        }
        let hasPromotions = !(store.at(path: "promotions")?.arrayValue ?? []).isEmpty
        var dropped: JSONValue = .array([])
        if hasPromotions {
            var flat = Set<Int64>()
            func walk(_ v: JSONValue) {
                switch v {
                case .object(let o):
                    if let w = o["window_id"]?.intValue,
                       o["window_id"].map({ if case .int = $0 { return true } else if case .double = $0 { return true } else { return false } }) == true {
                        flat.insert(w)
                    }
                    o.values.forEach(walk)
                case .array(let a):
                    a.forEach(walk)
                default:
                    break
                }
            }
            walk(store)
            let derived = deriveNested(arr: store, topo: topoV)
            let emitted = Set((arrangementTargetsRec(bridge: derived, topo: topoV).objectValue ?? [:])
                .keys.compactMap { Int64($0) })
            dropped = .array(flat.subtracting(emitted).sorted().map { .int($0) })
        }
        let droppedEmpty = (dropped.arrayValue ?? []).isEmpty
        return .object([
            "ok": .bool((partition.objectValue?["ok"]?.boolValue == true)
                && !cellInconsistent && (dropped == .null || droppedEmpty)),
            "partition": partition,
            "cell_inconsistent": .bool(cellInconsistent),
            "has_promotions": .bool(hasPromotions),
            "promotion_dropped_window_ids": dropped,
        ])
    }
}
