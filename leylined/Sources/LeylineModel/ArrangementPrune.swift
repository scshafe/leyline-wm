// Canonical prune, reclaim and native arrangement bridges. Every candidate
// respects membership conservation and minimum-size constraints before authoring.
import Foundation

extension Arrangement {

    // ── helpers: _span_minus / _reclaim_edit / _reclaim_grow_edit ─────────
    static func spanMinus(_ lo: Double, _ hi: Double, _ a: Double, _ b: Double) -> [(lo: Double, hi: Double)] {
        var out: [(Double, Double)] = []
        if a - lo > tol { out.append((lo, a)) }
        if hi - b > tol { out.append((b, hi)) }
        return out
    }

    /// The collinear run of segments on `axis` at `coord` that covers [a, b] without a gap,
    /// with the pieces of it that reach beyond [a, b]. A cut may be stored as abutting
    /// pieces (a reclaim keeps both halves of a crossed line) or, in an older checkpoint,
    /// as overlapping ones; nil when the run has a gap or does not cover the facing edge.
    static func facingHit(_ segs: [Seg], axis: String, coord: Double, _ a: Double, _ b: Double)
        -> (offsets: Set<Int>, remnants: [Seg])? {
        let run = segs.enumerated().filter { (_, s) in
            s.axis == axis && abs(s.coord - coord) <= tol && s.lo < b - tol && s.hi > a + tol
        }.sorted { $0.element.lo < $1.element.lo }
        guard let first = run.first, first.element.lo <= a + tol else { return nil }
        var reach = first.element.hi
        for piece in run.dropFirst() {
            guard piece.element.lo <= reach + tol else { return nil }
            reach = max(reach, piece.element.hi)
        }
        guard reach >= b - tol else { return nil }
        let remnants = mergingOverlaps(run.flatMap { piece in
            spanMinus(piece.element.lo, piece.element.hi, a, b).map { span -> Seg in
                var s = piece.element
                s.lo = span.lo
                s.hi = span.hi
                return s
            }
        })
        return (Set(run.map(\.offset)), remnants)
    }

    static func reclaimEdit(_ segs: [Seg], _ g: Frame, _ dir: String) -> (segs: [Seg], local: Bool)? {
        let fc: (axis: String, coord: Double, a: Double, b: Double)
        switch dir {
        case "below": fc = ("h", g.maxY, g.x, g.maxX)
        case "above": fc = ("h", g.y, g.x, g.maxX)
        case "right": fc = ("v", g.maxX, g.y, g.maxY)
        default: fc = ("v", g.x, g.y, g.maxY)
        }
        guard let hit = facingHit(segs, axis: fc.axis, coord: fc.coord, fc.a, fc.b) else { return nil }
        let out = segs.enumerated().filter { !hit.offsets.contains($0.offset) }.map(\.element) + hit.remnants
        return (out, hit.remnants.isEmpty)
    }

    static func reclaimGrowEdit(_ segs: [Seg], _ g: Frame, _ dir: String) -> [Seg]? {
        let fc: (axis: String, coord: Double, sl: Double, sh: Double, pax: String, near: Double, far: Double, extLo: Bool)
        switch dir {
        case "below": fc = ("h", g.maxY, g.x, g.maxX, "v", g.maxY, g.y, true)
        case "above": fc = ("h", g.y, g.x, g.maxX, "v", g.y, g.maxY, false)
        case "right": fc = ("v", g.maxX, g.y, g.maxY, "h", g.maxX, g.x, true)
        default: fc = ("v", g.x, g.y, g.maxY, "h", g.x, g.maxX, false)
        }
        guard let hit = facingHit(segs, axis: fc.axis, coord: fc.coord, fc.sl, fc.sh) else { return nil }
        func qualifies(_ s: Seg) -> Bool {
            s.axis == fc.pax && s.coord > fc.sl + tol && s.coord < fc.sh - tol
                && (fc.extLo ? abs(s.lo - fc.near) <= tol : abs(s.hi - fc.near) <= tol)
        }
        guard segs.contains(where: qualifies) else { return nil }
        var out: [Seg] = []
        for (idx, s) in segs.enumerated() where !hit.offsets.contains(idx) {
            var s = s
            if qualifies(s) {
                if fc.extLo { s.lo = fc.far } else { s.hi = fc.far }
            }
            out.append(s)
        }
        return out + hit.remnants
    }

    /// The cells on `display` whose closed frame contains the centre of `f`.
    static func cellsContaining(centreOf f: Frame, display: String, in cells: [Comp]) -> [Comp] {
        let cx = f.x + f.w / 2
        let cy = f.y + f.h / 2
        return cells.filter {
            "\($0.displayId ?? 0)" == display
                && $0.frame.x <= cx && cx <= $0.frame.maxX
                && $0.frame.y <= cy && cy <= $0.frame.maxY
        }
    }

    /// Re-key each entry onto the one cell of its own display that contains its
    /// frame's centre; nil when a frame is missing, ambiguous or a cell is claimed twice.
    static func centreRekey(_ entries: [(key: String, value: JSONValue)], into seed: JSONObject,
                            cells: [Comp]) -> JSONObject? {
        var m = seed
        for b in entries {
            guard let f = Frame.from(b.value.objectValue?["frame"]) else { return nil }
            let did = b.key.split(separator: ":").first.map(String.init) ?? ""
            let cand = cellsContaining(centreOf: f, display: did, in: cells)
            guard cand.count == 1 else { return nil }
            let ak = anchorKey(cand[0])
            guard m[ak] == nil else { return nil }
            m[ak] = b.value
        }
        return m
    }

    // ── _prune_rekey — centre-containment survivor re-key, display-scoped ─
    static func pruneRekey(_ newSegs: [Seg], _ T: NormTopology,
                           _ surv: [(key: String, value: JSONValue)]) -> JSONObject? {
        guard let m = centreRekey(surv, into: [:], cells: cellsMd(newSegs, T)) else { return nil }
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
                   survivors: survc)
    }

    // ── _reclaim_spread_edit — even run re-spacing ───────────────────────
    static func reclaimSpreadEdit(_ segs: [Seg], _ g: Frame, _ gdid: String, _ T: NormTopology,
                                  _ spread: String, _ binds: JSONObject)
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
        let N = run.survivors.count
        let newsize = (run.hi - run.lo) * (1.0 / Double(N))
        for k in 0..<N {
            let e = binds[anchorKey(run.survivors[k])]?.objectValue
            let ms = (e?["min_size"] ?? e?["contents"]?.arrayValue?.first?.objectValue?["min_size"])?.objectValue ?? [:]
            let mn = spread == "h" ? (ms["w"]?.numberValue ?? 0) : (ms["h"]?.numberValue ?? 0)
            if newsize + tol < mn { return nil }
        }
        let ikeys = Set(interior.map(\.offset))
        let spanLo = interior.map(\.element.lo).min()!
        let spanHi = interior.map(\.element.hi).max()!
        let coords = (1..<N).map { run.lo + Double($0) * ((run.hi - run.lo) / Double(N)) }
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
        guard let m = centreRekey(rest, into: runmap, cells: nc) else { return nil }
        return m.count == surv.count ? m : nil
    }

    // ── _absorber_of ─────────────────────────────────────────────────────
    static func absorberOf(_ candSegs: [Seg], _ candBinds: JSONObject,
                           _ gf: Frame, _ gdid: String, _ T: NormTopology) -> JSONValue {
        let acell = cellsContaining(centreOf: gf, display: gdid, in: cellsMd(candSegs, T)).first
        guard let acell, let wid = candBinds[anchorKey(acell)]?.objectValue?["window_id"] else { return .null }
        return wid
    }

    // ── bridge_arrangement_native — the line-native re-stamp ─────────────
    public static func bridgeArrangementNative(store: JSONValue, topo: JSONValue, frameCanvas: Frame? = nil) -> JSONValue {
        let T = Project.normTopology(topo)
        let gap = T.gap
        var segs = mergingOverlaps(parseSegs(store.at(path: "segments")))
        var pri = store.at(path: "bindings")?.objectValue ?? [:]
        if frameCanvas == nil {
            // Known floors move a display's lines when every floor then fits (nested parcels refit
            // below). Otherwise the cut stays and minimum growth or overload resolution decides.
            for bag in bags(segs, T) {
                guard let rect = bag.rect, let display = bag.displayId, !bag.segments.isEmpty else { continue }
                let prefix = "\(display):"
                let local: JSONValue = .object(["segments": .array(bag.segments.map(\.json)),
                    "bindings": .object(pri.filter { $0.key.hasPrefix(prefix) })])
                guard let fitted = fittingOwnerMinimums(local, canvas: rect, frameCanvas: rect, gap: gap, displayID: display)
                        ?? fittingOwnerMinimums(local, canvas: rect, frameCanvas: rect, gap: gap, displayID: display, partial: true),
                      fitted != local else { continue }
                let split = bagsWithRejected(segs, T)
                segs = split.bags.filter { $0.displayId != display }.flatMap(\.segments) + split.rejected
                    + parseSegs(fitted.at(path: "segments"))
                pri = pri.filter { !$0.key.hasPrefix(prefix) }
                for (anchor, binding) in fitted.at(path: "bindings")?.objectValue ?? [:] { pri[anchor] = binding }
            }
        }

        struct NCell {
            let anchor: String
            let frame: Frame
            let allocation: Frame
            let rect: Frame
            let segments: [Seg]
        }
        var ncells: [NCell] = []
        for bag in bags(segs, T) {
            guard let r = bag.rect else { continue }
            for var c in cells(bag.segments, r) {
                c.displayId = bag.displayId
                ncells.append(NCell(anchor: anchorKey(c), frame: insetInterior(c.frame, frameCanvas ?? r, gap), allocation: c.frame,
                                    rect: r, segments: bag.segments))
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
                    ?? fittingOwnerMinimums(transformed, canvas: c.allocation, frameCanvas: frameCanvas ?? c.rect, gap: gap, partial: true)
                var entry = b
                entry["nested"] = bridgeArrangementNative(store: fitted ?? transformed,
                    topo: localTopology(canvas: c.allocation, displayID: 0, gap: gap), frameCanvas: frameCanvas ?? c.rect)
                entry["allocated_frame"] = c.allocation.json
                entry["frame"] = c.frame.json
                bindings[c.anchor] = .object(entry)
                continue
            }
            let minPair = allocationMinimum(.object(b), frame: c.allocation, gap: gap)
            var f = Project.reachBump(c.frame, minPair)
            var overlaps = false
            if f.w > c.frame.w + fitSlack || f.h > c.frame.h + fitSlack,
               let grown = minimumGrowth(allocation: c.allocation, frame: c.frame, canvas: c.rect,
                                         frameCanvas: frameCanvas ?? c.rect, segments: c.segments, minimum: minPair, gap: gap)
                ?? displacedGrowth(frame: c.frame, frameCanvas: frameCanvas ?? c.rect, minimum: minPair) {
                f = grown; overlaps = true
            }
            let ms = b["min_size"] ?? b["contents"]?.arrayValue?.first?.objectValue?["min_size"]
            var member: JSONObject = [
                "window_id": b["window_id"] ?? .null,
                "presented": .bool(true),
                "frame": f.json,
            ]
            if let ms, ms != .null { member["min_size"] = ms }
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
            if overlaps { entry["minimum_fit"] = .string("overlap") }
            else if entry["minimum_fit"] == .string("overlap") { entry.removeValue(forKey: "minimum_fit") }
            bindings[c.anchor] = .object(entry)
        }
        return .object([
            "segments": .array(segs.map(\.json)),
            "bindings": .object(bindings),
            "off_top": store.at(path: "off_top") ?? .array([]),
        ])
    }

    // ── bridge_arrangement_native_prune — the dispatch ───────────────────
    public static func bridgeArrangementNativePrune(store: JSONValue, goners: [Int64], topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let segs = parseSegs(store.at(path: "segments"))
        let binds = store.at(path: "bindings")?.objectValue ?? [:]
        guard goners.count == 1 else { return .null }
        let gw = goners[0]
        let entries = Array(binds)  // jq: to_entries — insertion order
        guard let ge = entries.first(where: { $0.value.objectValue?["window_id"]?.intValue == gw })
        else { return .null }
        let curCells = cellsMd(segs, T)
        guard let gcell = curCells.first(where: { anchorKey($0) == ge.key }) else { return .null }
        let gf = gcell.frame
        let ncells0 = curCells.count
        let surv = entries.filter { $0.value.objectValue?["window_id"]?.intValue != gw }
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
        for sp in ["h", "v"] {
            guard let e = reclaimSpreadEdit(segs, gf, gdid, T, sp, binds), gated(e.segs),
                  let rk = reclaimEvenRekey(e.segs, T, surv, e.run) else { continue }
            var sabs: JSONValue = .null
            if e.run.survivors.count == 1 {
                sabs = binds[anchorKey(e.run.survivors[0])]?.objectValue?["window_id"] ?? .null
            }
            spreadCands.append(Cand(dir: "spread-\(sp)", local: false, segs: e.segs,
                                    binds: rk, spreadAbsorber: sabs))
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

        guard let pick = spreadCands.first ?? pool.sortedStableBy({ .int(Int64(ord[$0.dir] ?? 9)) }).first
        else { return .null }

        let absorber: JSONValue = pick.dir.hasPrefix("spread")
            ? pick.spreadAbsorber
            : absorberOf(pick.segs, pick.binds, gf, gdid, T)

        let authored = JSONValue.object([
            "segments": .array(pick.segs.map(\.json)),
            "bindings": .object(pick.binds),
            "off_top": .array([]),
        ])
        return .object([
            "arr": bridgeArrangementNative(store: authored, topo: topo),
            "absorber": absorber,
        ])
    }

}
