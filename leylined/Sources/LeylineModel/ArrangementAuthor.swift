// Step-6 arrangement additions: the valve/conservation lens wrappers (pure
// composition over Balance — zero forked feasibility math), the S-P4 native
// adopt author with its full-set conservation teeth, stamp_demotable (the
// z-demotion author gate), and the carry cluster (is_flat/is_carryable/
// carry_promos/carryable_windows — native_noop's fire condition).
import Foundation

extension Arrangement {
    // ── arrangement::valve — B::valve projected through cells_stack ──────
    public static func valveLens(tree: JSONValue, topo: JSONValue, foc: JSONValue, config: JSONValue) -> JSONValue {
        let v = Balance.valve(tree: tree, topo: topo, foc: foc, config: config)
        return .object([
            "arrangement": cellsStack(tree: v.tree, topo: topo),
            "facts": .array(v.facts),
        ])
    }

    // ── arrangement::conservation — B::conservation re-expressed ─────────
    public static func conservationLens(tree: JSONValue, topo: JSONValue, foc: JSONValue, config: JSONValue) -> JSONValue {
        let c = Balance.conservation(tree: tree, topo: topo, foc: foc, config: config).objectValue ?? [:]
        return .object([
            "ok": c["ok"] ?? .bool(false),
            "bound": c["managed"] ?? .array([]),
            "presented": c["presented"] ?? .array([]),
            "stacked": c["hidden"] ?? .array([]),
            "vacant": .array([]),
            "unexplained": c["unexplained"] ?? .array([]),
            "overflowing": c["overflowing"] ?? .array([]),
        ])
    }

    // ── home_display ──────────────────────────────────────────────────────
    public static func homeDisplay(_ frame: JSONValue, _ T: NormTopology) -> Int64? {
        guard let f = Frame.from(frame) else {
            return Geometry.assignDisplay(Frame(x: 0, y: 0, w: 0, h: 0), T.displays)
        }
        return Geometry.assignDisplay(f, T.displays)
    }

    /// @canonical observed_bindings_stay_on_display
    /// Returns true only when each managed observed window has exactly one stored
    /// binding and its canonical observed home display still matches that binding.
    /// A false result deliberately routes ArrangementStrategy through Autotile.sync,
    /// where the existing cross-display rehome operation is authored.
    /// related: parcel/strategies/arrangement.jq native_noop
    public static func observedBindingsStayOnDisplay(
        store: JSONValue, observed: [JSONValue], managed: [Int64], topology: NormTopology
    ) -> Bool {
        let bindings = store.at(path: "bindings")?.objectValue ?? [:]
        var bound: [Int64: (count: Int, display: String)] = [:]
        for (key, binding) in bindings {
            guard let windowId = binding.objectValue?["window_id"]?.intValue else { continue }
            let prior = bound[windowId]
            bound[windowId] = (
                count: (prior?.count ?? 0) + 1,
                display: key.split(separator: ":").first.map(String.init) ?? ""
            )
        }
        var seen: [Int64: (count: Int, display: String)] = [:]
        for window in observed {
            guard let windowId = window.objectValue?["window_id"]?.intValue,
                  let display = homeDisplay(window.objectValue?["frame"] ?? .null, topology) else { continue }
            let prior = seen[windowId]
            seen[windowId] = (count: (prior?.count ?? 0) + 1, display: String(display))
        }
        for windowId in managed {
            guard let binding = bound[windowId], binding.count == 1,
                  let observation = seen[windowId], observation.count == 1,
                  binding.display == observation.display else {
                return false
            }
        }
        return true
    }

    static func stripBinds(_ m: JSONObject) -> JSONObject {
        var out: JSONObject = [:]
        for (k, v) in m {
            guard let wid = v.objectValue?["window_id"], wid != .null else { continue }
            out[k] = .object(["window_id": wid])
        }
        return out
    }

    // ── bridge_arrangement_native_adopt (S-P4) ───────────────────────────
    /// Insert arrivals with one canonical native author; unsafe batches return null atomically.
    /// `largest_first` uses raw area/top/left/key order and a known-minimum feasible cut.
    /// The resident enables overload conservation; omitted allowOverload preserves the
    /// frozen flat compatibility refusal corpus. focus_chain remains an oracle policy.
    public static func bridgeArrangementNativeAdopt(store: JSONValue, newcomers: [Int64],
                                                    ndid: Int64, focused: JSONValue,
                                                    topo: JSONValue, insertionPolicy: String = "focus_chain",
                                                    newcomerMinimums: [Int64: JSONValue] = [:],
                                                    allowOverload: Bool = false) -> JSONValue {
        guard insertionPolicy == "focus_chain" || insertionPolicy == "largest_first" else { return .null }
        if insertionPolicy == "largest_first" {
            return adoptLargestFirst(store: store, newcomers: newcomers, displayID: ndid, topo: topo,
                newcomerMinimums: newcomerMinimums, allowOverload: allowOverload, focused: focused)
        }

        let T = Project.normTopology(topo)
        let segs = parseSegs(store.at(path: "segments"))
        let binds = store.at(path: "bindings")?.objectValue ?? [:]
        let nds = String(ndid)
        guard newcomers.count == 1 else { return .null }
        let nw = newcomers[0]
        let mdCells = cellsMd(segs, T)
        let surv = binds  // jq: to_entries — insertion order
            .filter { $0.value.objectValue?["window_id"].map { $0 != .null } ?? false }
        let want = (surv.compactMap { $0.value.objectValue?["window_id"]?.intValue } + [nw]).sorted()

        let fw: Int64? = {
            if let s = focused.stringValue {
                return Int64(s.hasPrefix("w:") ? String(s.dropFirst(2)) : s)
            }
            return focused.intValue
        }()
        let bnd = mdCells
            .filter { "\($0.displayId ?? 0)" == nds }
            .compactMap { c -> (c: Comp, k: String, w: Int64)? in
                let k = anchorKey(c)
                guard let w = binds[k]?.objectValue?["window_id"]?.intValue else { return nil }
                return (c, k, w)
            }
        let anchor = bnd.first { $0.w == fw } ?? bnd.sortedStableBy { .string($0.k) }.first
        guard let anchor else { return .null }

        let af = anchor.c.frame
        let axis = af.w >= af.h ? "v" : "h"
        let sp: (coord: Double, lo: Double, hi: Double) = axis == "v"
            ? (af.x + af.w / 2, af.y, af.maxY)
            : (af.y + af.h / 2, af.x, af.maxX)
        let segs2 = segs + [Seg(axis: axis, coord: sp.coord, lo: sp.lo, hi: sp.hi)]
        let nc = cellsMd(segs2, T)
        let ord = nc.filter {
            $0.frame.x >= af.x - tol && $0.frame.y >= af.y - tol
                && $0.frame.maxX <= af.maxX + tol && $0.frame.maxY <= af.maxY + tol
        }.sortedStableBy { .double(axis == "v" ? $0.frame.x : $0.frame.y) }
        guard ord.count == 2 else { return .null }

        // Occupant by centre containment of its STORED frame in the anchor cell.
        let occ = surv.first { (_, v) in
            guard let f = Frame.from(v.objectValue?["frame"]) else { return false }
            let cx = f.x + f.w / 2
            let cy = f.y + f.h / 2
            return cx >= af.x && cx <= af.maxX && cy >= af.y && cy <= af.maxY
        }
        guard let occ, let occWid = occ.value.objectValue?["window_id"]?.intValue else { return .null }
        let others = surv.filter { $0.value.objectValue?["window_id"]?.intValue != occWid }
            .map { (key: $0.key, value: $0.value) }
        guard let om = pruneRekey(segs2, T, others) else { return .null }

        var binds2 = stripBinds(om)
        binds2[anchorKey(ord[0])] = .object(["window_id": .int(occWid)])
        binds2[anchorKey(ord[1])] = .object(["window_id": .int(nw)])


        let got = binds2.compactMap { $0.value.objectValue?["window_id"]?.intValue }.sorted()
        guard got == want,
              validMd(segs2, T).objectValue?["ok"]?.boolValue == true else { return .null }
        let cellAnchors = Set(cellsMd(segs2, T).map { anchorKey($0) })
        guard Set(binds2.keys).subtracting(cellAnchors).isEmpty else { return .null }

        let out = bridgeArrangementNative(
            store: .object(["segments": .array(segs2.map(\.json)),
                            "bindings": .object(binds2),
                            "off_top": .array([]), "promotions": .array([])]),
            topo: topo
        )
        // Amend. D belt: the newcomer must land on ndid.
        let nwDid = (out.at(path: "bindings")?.objectValue ?? [:])
            .first { $0.value.objectValue?["window_id"]?.intValue == nw }?
            .key.split(separator: ":").first.map(String.init)
        guard nwDid == nds else { return .null }

        return out
    }

    // @canonical largest_first_insertion_target -- raw allocated cells, never AX frames.
    static func largestFirstInsertionRank(frame: Frame, key: String) -> JSONValue {
        .array([.double(-(frame.w * frame.h)), .double(frame.y), .double(frame.x), .string(key)])
    }

    /// @canonical largest_first_insertion_author -- the existing author handles nested and crowded cases.
    /// Compatibility fixtures omit allowOverload; the resident explicitly enables managed overload.
    private static func adoptLargestFirst(store: JSONValue, newcomers: [Int64], displayID: Int64,
                                         topo: JSONValue, newcomerMinimums: [Int64: JSONValue],
                                         allowOverload: Bool, focused: JSONValue) -> JSONValue {
        let initial = allocatedWindowIDs(store, topo: topo)
        let focusedID = focused.intValue ?? focused.stringValue.flatMap { Int64($0.hasPrefix("w:") ? String($0.dropFirst(2)) : $0) }
        guard !newcomers.isEmpty, Set(newcomers).count == newcomers.count, newcomers.allSatisfy({ $0 > 0 }),
              Set(initial).count == initial.count, Set(initial).isDisjoint(with: newcomers),
              allowOverload || isFlat(store),
              validMd(parseSegs(store.at(path: "segments")), Project.normTopology(topo)).at(path: "ok")?.boolValue == true,
              Project.normTopology(topo).displays.contains(where: { $0.id == displayID }) else { return .null }
        var result = store
        for id in newcomers {
            let candidates = allocatedCells(result, topo: topo).filter { $0.displayID == displayID }
            guard let anchor = candidates.sortedStableBy({ largestFirstInsertionRank(frame: $0.frame,
                key: ($0.ownerPath + [$0.anchor]).joined(separator: "/")) }).first,
                  var owner = ownerBag(result, path: anchor.ownerPath)?.objectValue,
                  var bindings = owner["bindings"]?.objectValue else { return .null }
            let minimum = newcomerMinimums[id] ?? .object([:])
            guard Minsize.validStore(.object(["newcomer": minimum])) else { return .null }
            let oldMin = allocationMinimum(anchor.binding, frame: anchor.frame, gap: Project.normTopology(topo).gap)
            let newMin = Project.leafFitMin(["min_size": minimum])
            let vertical = anchor.frame.w >= anchor.frame.h
            let displayCanvas = bags(parseSegs(result.at(path: "segments")), Project.normTopology(topo))
                .first(where: { $0.displayId == displayID })?.rect ?? anchor.canvas
            let cut = feasibleCut(canvas: anchor.frame, vertical: vertical,
                proposed: vertical ? anchor.frame.x + anchor.frame.w / 2 : anchor.frame.y + anchor.frame.h / 2,
                lowMinimum: vertical ? oldMin.w : oldMin.h, highMinimum: vertical ? newMin.w : newMin.h,
                lowPerpendicularMinimum: vertical ? oldMin.h : oldMin.w,
                highPerpendicularMinimum: vertical ? newMin.h : newMin.w,
                gap: Project.normTopology(topo).gap, ownerCanvas: displayCanvas)
            if let cut {
                let localDisplay: Int64 = anchor.ownerPath.isEmpty ? displayID : 0
                let local = anchor.ownerPath.isEmpty ? topo : localTopology(canvas: anchor.canvas, displayID: 0,
                    gap: Project.normTopology(topo).gap)
                let segments = parseSegs(owner["segments"]) + [Seg(axis: vertical ? "v" : "h", coord: cut,
                    lo: vertical ? anchor.frame.y : anchor.frame.x, hi: vertical ? anchor.frame.maxY : anchor.frame.maxX)]
                let cells = cellsMd(segments, Project.normTopology(local))
                var rebound: JSONObject = [:]
                for existing in allocatedCells(result, topo: topo) where existing.ownerPath == anchor.ownerPath {
                    guard let cell = cells.first(where: { $0.displayId == (anchor.ownerPath.isEmpty ? existing.displayID : localDisplay)
                        && $0.frame.x <= existing.frame.x + 1 && existing.frame.x + 1 < $0.frame.maxX
                        && $0.frame.y <= existing.frame.y + 1 && existing.frame.y + 1 < $0.frame.maxY }) else { return .null }
                    rebound[anchorKey(cell)] = existing.binding
                }
                // Nested siblings are opaque allocations, so rekey their complete binding by old origin.
                let oldCells = cellsMd(parseSegs(owner["segments"]), Project.normTopology(local))
                for (key, value) in bindings where value.at(path: "nested") != nil {
                    guard let oldCell = oldCells.first(where: { anchorKey($0) == key }),
                          let cell = cells.first(where: { $0.displayId == oldCell.displayId
                            && $0.frame.x <= oldCell.frame.x + 1 && oldCell.frame.x + 1 < $0.frame.maxX
                            && $0.frame.y <= oldCell.frame.y + 1 && oldCell.frame.y + 1 < $0.frame.maxY }) else { return .null }
                    rebound[anchorKey(cell)] = value
                }
                guard let high = cells.first(where: { $0.displayId == localDisplay
                    && abs((vertical ? $0.frame.x : $0.frame.y) - cut) <= tol
                    && (vertical ? abs($0.frame.y - anchor.frame.y) <= tol : abs($0.frame.x - anchor.frame.x) <= tol) }) else { return .null }
                var newcomer: JSONObject = ["window_id": .int(id)]
                if minimum.objectValue?.isEmpty == false { newcomer["min_size"] = minimum }
                rebound[anchorKey(high)] = .object(newcomer)
                owner["segments"] = .array(segments.map(\.json)); owner["bindings"] = .object(rebound)
            } else {
                guard allowOverload else { return .null }
                var binding = anchor.binding.objectValue ?? [:]
                var members = binding["contents"]?.arrayValue ?? [anchor.binding]
                var newcomer: JSONObject = ["window_id": .int(id), "presented": .bool(false), "frame": .null]
                if minimum.objectValue?.isEmpty == false { newcomer["min_size"] = minimum }
                if focusedID == id {
                    members.insert(.object(newcomer), at: 0); binding["window_id"] = .int(id)
                    binding["min_size"] = minimum
                } else { members.append(.object(newcomer)) }
                binding["contents"] = .array(members); binding["top_window_id"] = binding["window_id"]
                binding["stack_source"] = .string("overload")
                binding["overload_reason"] = .string("minimum_interval_empty")
                bindings[anchor.anchor] = .object(binding); owner["bindings"] = .object(bindings)
            }
            guard let replaced = replacingOwnerBag(result, path: anchor.ownerPath, bag: .object(owner)) else { return .null }
            result = bridgeArrangementNative(store: replaced, topo: topo)
            if allowOverload {
                guard let resolved = resolvingAutomaticOverload(store: result, topo: topo, focused: focusedID) else { return .null }
                result = resolved
            }
            let all = allocatedWindowIDs(result, topo: topo)
            guard Set(all).count == all.count, Set(all) == Set(initial + newcomers.prefix(through: newcomers.firstIndex(of: id)!)) else { return .null }
            if !allowOverload {
                let targets = arrangementTargetsRec(bridge: result, topo: topo)
                for cell in allocatedCells(result, topo: topo) {
                    guard let top = cell.topWindowID, let frame = Frame.from(targets.at(path: "\(top).frame")),
                          frame.x >= cell.frame.x - 0.5, frame.y >= cell.frame.y - 0.5,
                          frame.maxX <= cell.frame.maxX + 0.5, frame.maxY <= cell.frame.maxY + 0.5 else { return .null }
                }
            }
        }
        return result
    }

    // ── stamp_demotable — the z-demotion author gate ─────────────────────
    public static func stampDemotable(store: JSONValue, obs: [JSONValue], topo: JSONValue) -> JSONValue {
        let T = Project.normTopology(topo)
        let cells = cellsMd(parseSegs(store.at(path: "segments")), T)
        var ident: JSONObject = [:]
        for w in obs {
            guard let o = w.objectValue, let wid = o["window_id"]?.intValue else { continue }
            if let id = o["pid"] ?? o["bundle_id"] ?? o["app"], id != .null {
                ident[String(wid)] = id
            }
        }
        var s = store.objectValue ?? [:]
        var bindings = s["bindings"]?.objectValue ?? [:]
        for (ak, v) in bindings {
            guard var b = v.objectValue else { continue }
            b.removeValue(forKey: "demotable_faces")
            let wid = b["window_id"]?.intValue
            let cell = cells.first { anchorKey($0) == ak }
            let me = wid.flatMap { ident[String($0)] }
            var faces: [String] = []
            if let wid, let cell, let me {
                _ = wid
                let f = cell.frame
                let did = ak.split(separator: ":").first.map(String.init) ?? ""
                let probes: [(String, Double, Double)] = [
                    ("left", f.x - 1, f.y + f.h / 2),
                    ("right", f.maxX + 1, f.y + f.h / 2),
                    ("above", f.x + f.w / 2, f.y - 1),
                    ("below", f.x + f.w / 2, f.maxY + 1),
                ]
                for (face, px, py) in probes {
                    let ncell = cells.first {
                        "\($0.displayId ?? 0)" == did && anchorKey($0) != ak
                            && $0.frame.x - tol <= px && px <= $0.frame.maxX + tol
                            && $0.frame.y - tol <= py && py <= $0.frame.maxY + tol
                    }
                    guard let ncell,
                          let ow = bindings[anchorKey(ncell)]?.objectValue?["window_id"]?.intValue,
                          let other = ident[String(ow)], JQOrder.equal(other, me) else { continue }
                    faces.append(face)
                }
            }
            if !faces.isEmpty {
                b["demotable_faces"] = .array(faces.map { .string($0) })
            }
            bindings[ak] = .object(b)
        }
        s["bindings"] = .object(bindings)
        return .object(s)
    }

    // ── the carry cluster ─────────────────────────────────────────────────
    static func contentsDepth(_ v: JSONValue) -> Int {
        v.objectValue?["contents"]?.arrayValue?.count ?? 1
    }

    public static func isFlat(_ t: JSONValue) -> Bool {
        (t.at(path: "off_top")?.arrayValue ?? []).isEmpty
            && (t.at(path: "bindings")?.objectValue ?? [:]).values.allSatisfy { contentsDepth($0) <= 1 }
            && (t.at(path: "promotions")?.arrayValue ?? []).isEmpty
            && (t.at(path: "bindings")?.objectValue ?? [:]).values.allSatisfy { $0.objectValue?["nested"] == nil }
    }

    public static func isCarryable(_ t: JSONValue) -> Bool {
        (t.at(path: "off_top")?.arrayValue ?? []).isEmpty
            && (t.at(path: "bindings")?.objectValue ?? [:]).values.allSatisfy { contentsDepth($0) <= 1 }
            && (t.at(path: "bindings")?.objectValue ?? [:]).values.allSatisfy { $0.objectValue?["nested"] == nil }
    }

    public static func carryPromos(bridge: JSONValue, promos: [JSONValue], topo: JSONValue) -> [JSONValue] {
        guard !promos.isEmpty else { return [] }
        let flatK = (arrangementTargetsRec(bridge: bridge, topo: topo).objectValue ?? [:]).keys.sorted()
        var withPromos = bridge.objectValue ?? [:]
        withPromos["promotions"] = .array(promos)
        let derived = deriveNested(arr: .object(withPromos), topo: topo)
        let promoK = (arrangementTargetsRec(bridge: derived, topo: topo).objectValue ?? [:]).keys.sorted()
        return flatK == promoK ? promos : []
    }

    public static func carryableWindows(_ t: JSONValue, topo: JSONValue) -> JSONValue {
        let derived = deriveNested(arr: t, topo: topo)
        let keys = (arrangementTargetsRec(bridge: derived, topo: topo).objectValue ?? [:]).keys.sorted()
        return .array(keys.map { k in
            if let n = Int64(k) { return .int(n) }
            return .string(k)
        })
    }
}
