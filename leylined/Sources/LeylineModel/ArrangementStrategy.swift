// Canonical layout settlement: preserve prior structure, prune/adopt/reclaim,
// allocate cold layouts and conserve membership. Policy is explicit; this pure
// model never reads runtime environment variables.
import Foundation

public enum ArrangementStrategy {
    public struct Policies: Sendable {
        public var reclaim: String?
        public var nativePrune: Bool
        public var nativeAdopt: Bool
        public var nativePromote: Bool

        public init(reclaim: String? = nil, nativePrune: Bool = true,
                    nativeAdopt: Bool = true, nativePromote: Bool = true) {
            self.reclaim = reclaim
            self.nativePrune = nativePrune
            self.nativeAdopt = nativeAdopt
            self.nativePromote = nativePromote
        }
    }

    // ── _prior_tree: the flat mount reconstruction ────────────────────────
    static func priorTree(_ store: JSONValue) -> JSONValue {
        guard store.at(path: "segments") != nil, store.at(path: "segments") != .null else {
            return store
        }
        var bound: [(wid: JSONValue, disp: String)] = []
        for (k, v) in store.at(path: "bindings")?.objectValue ?? [:] {  // jq: to_entries — insertion order
            guard let wid = v.objectValue?["window_id"], wid != .null else { continue }
            bound.append((wid, k.split(separator: ":").first.map(String.init) ?? ""))
        }
        for o in store.at(path: "off_top")?.arrayValue ?? [] {
            guard let wid = o.objectValue?["window_id"], wid != .null else { continue }
            bound.append((wid, "1"))
        }
        var tree = JSONValue.object([
            "root_id": .string("root"),
            "nodes": .object(["root": .object(["id": .string("root"), "mode": .string("region"), "children": .array([])])]),
        ])
        for b in bound {
            let m = "d:\(b.disp)"
            let widStr = b.wid.intValue.map(String.init) ?? (b.wid.stringValue ?? "")
            let lid = "w:\(widStr)"
            if Autotile.nodes(tree)[m] == nil {
                let dnum: JSONValue = Int64(b.disp).map { .int($0) } ?? .string(b.disp)
                tree = Autotile.setNode(tree, m, .object([
                    "id": .string(m), "mode": .string("row"),
                    "frame_source": .string("pinned"), "display_id": dnum, "children": .array([]),
                ]))
                tree = Autotile.mutNode(tree, "root") {
                    $0["children"] = .array(($0["children"]?.arrayValue ?? []) + [.string(m)])
                }
            }
            tree = Autotile.setNode(tree, lid, .object(["id": .string(lid), "window_id": b.wid]))
            tree = Autotile.mutNode(tree, m) {
                $0["children"] = .array(($0["children"]?.arrayValue ?? []) + [.string(lid)])
            }
        }
        return tree
    }

    // ── _sticky_mount: single-axis fully-pinned display reconstruction ────
    struct StickyMount {
        let mode: String
        let wids: [JSONValue]
        let ratios: [Double]
    }

    static func stickyMount(_ store: JSONValue, _ T: NormTopology, _ disp: String) -> StickyMount? {
        let segsAll = Arrangement.parseSegs(store.at(path: "segments"))
        let bag = Arrangement.bags(segsAll, T).first { "\($0.displayId ?? 0)" == disp }
        let segs = bag?.segments ?? []
        let cells = Arrangement.cellsMd(segsAll, T).filter { "\($0.displayId ?? 0)" == disp }
        let axes = Set(segs.map(\.axis))
        guard !segs.isEmpty, axes.count == 1, let axis = axes.first else { return nil }
        let mode = axis == "v" ? "row" : "col"
        guard segs.allSatisfy({ ($0.raw["relation"]?.stringValue ?? "free") == "pinned" }) else { return nil }
        let ordered = cells
            .map { (key: "\($0.displayId ?? 0):\($0.i0):\($0.j0)",
                    pos: axis == "v" ? $0.frame.x : $0.frame.y,
                    size: axis == "v" ? $0.frame.w : $0.frame.h) }
            .sortedStableBy { .double($0.pos) }
        let bindings = store.at(path: "bindings")?.objectValue ?? [:]
        let wids = ordered.map { bindings[$0.key]?.objectValue?["window_id"] ?? .null }
        guard wids.count >= 2, !wids.contains(.null) else { return nil }
        let sizes = ordered.map(\.size)
        let tot = sizes.reduce(0, +)
        guard tot > 0 else { return nil }
        return StickyMount(mode: mode, wids: wids, ratios: sizes.map { $0 / tot })
    }

    static func hasPersistedStructure(_ store: JSONValue) -> Bool {
        guard store.at(path: "segments") != nil, store.at(path: "segments") != .null else { return false }
        return (store.at(path: "segments")?.arrayValue ?? []).contains {
            ($0.objectValue?["relation"]?.stringValue ?? "free") == "pinned"
        }
    }

    static func priorTreeStructured(_ store: JSONValue, _ T: NormTopology) -> JSONValue? {
        guard hasPersistedStructure(store) else { return nil }
        var bound: [(wid: JSONValue, disp: String)] = []
        for (k, v) in store.at(path: "bindings")?.objectValue ?? [:] {  // jq: to_entries — insertion order
            guard let wid = v.objectValue?["window_id"], wid != .null else { continue }
            bound.append((wid, k.split(separator: ":").first.map(String.init) ?? ""))
        }
        for o in store.at(path: "off_top")?.arrayValue ?? [] {
            guard let wid = o.objectValue?["window_id"], wid != .null else { continue }
            bound.append((wid, "1"))
        }
        let disps = Array(Set(bound.map(\.disp))).sorted()
        let mounts = disps.map { (disp: $0, sticky: stickyMount(store, T, $0)) }
        guard mounts.contains(where: { $0.sticky != nil }) else { return nil }
        var tree = JSONValue.object([
            "root_id": .string("root"),
            "nodes": .object(["root": .object(["id": .string("root"), "mode": .string("region"), "children": .array([])])]),
        ])
        for m in mounts {
            let mid = "d:\(m.disp)"
            let dnum: JSONValue = Int64(m.disp).map { .int($0) } ?? .string(m.disp)
            func widStr(_ w: JSONValue) -> String {
                w.intValue.map(String.init) ?? (w.stringValue ?? "")
            }
            if let s = m.sticky {
                let kids = s.wids.map { "w:\(widStr($0))" }
                tree = Autotile.setNode(tree, mid, .object([
                    "id": .string(mid), "mode": .string(s.mode), "frame_source": .string("pinned"),
                    "display_id": dnum, "children": .array(kids.map { .string($0) }),
                    "ratios": .array(s.ratios.map { .number($0) }), "ratio_source": .string("pinned"),
                ]))
                tree = Autotile.mutNode(tree, "root") {
                    $0["children"] = .array(($0["children"]?.arrayValue ?? []) + [.string(mid)])
                }
                for w in s.wids {
                    let lid = "w:\(widStr(w))"
                    tree = Autotile.setNode(tree, lid, .object(["id": .string(lid), "window_id": w]))
                }
            } else {
                let dwids = bound.filter { $0.disp == m.disp }.map(\.wid)
                tree = Autotile.setNode(tree, mid, .object([
                    "id": .string(mid), "mode": .string("row"), "frame_source": .string("pinned"),
                    "display_id": dnum,
                    "children": .array(dwids.map { .string("w:\(widStr($0))") }),
                ]))
                tree = Autotile.mutNode(tree, "root") {
                    $0["children"] = .array(($0["children"]?.arrayValue ?? []) + [.string(mid)])
                }
                for w in dwids {
                    let lid = "w:\(widStr(w))"
                    tree = Autotile.setNode(tree, lid, .object(["id": .string(lid), "window_id": w]))
                }
            }
        }
        return tree
    }

    // ── _carry_manual_stacks ──────────────────────────────────────────────
    static func carryManualStacks(_ store: JSONValue, _ tree: JSONValue) -> JSONValue {
        var t = tree
        let stacks = (store.at(path: "bindings")?.objectValue ?? [:])
            .compactMap { (_, v) -> (top: Int64, wids: [Int64])? in  // jq: to_entries — insertion order
                guard let cs = v.objectValue?["contents"]?.arrayValue, cs.count > 1,
                      let top = cs.first?.objectValue?["window_id"]?.intValue else { return nil }
                return (top, cs.compactMap { $0.objectValue?["window_id"]?.intValue })
            }
        for stk in stacks {
            let lid = "w:\(stk.top)"
            let sid = "s:\(stk.top)"
            guard Autotile.nodes(t)[lid] != nil else { continue }
            t = Autotile.setNode(t, sid, .object([
                "id": .string(sid), "mode": .string("stack"), "stack_source": .string("manual"),
                "top": .string(lid), "children": .array(stk.wids.map { .string("w:\($0)") }),
            ]))
            for w in stk.wids where Autotile.nodes(t)["w:\(w)"] == nil {
                t = Autotile.setNode(t, "w:\(w)", .object(["id": .string("w:\(w)"), "window_id": .int(w)]))
            }
            var to = t.objectValue ?? [:]
            var nn = to["nodes"]?.objectValue ?? [:]
            for (k, v) in nn where k != sid {
                guard var o = v.objectValue, o["children"] != nil else { continue }
                o["children"] = .array((o["children"]?.arrayValue ?? []).map {
                    $0.stringValue == lid ? .string(sid) : $0
                })
                nn[k] = .object(o)
            }
            to["nodes"] = .object(nn)
            t = .object(to)
        }
        return t
    }

    // ── the settle ────────────────────────────────────────────────────────
    public static func settle(t: JSONValue, obs: [JSONValue], topo: JSONValue,
                              rules: JSONValue, foc: JSONValue, config: JSONValue,
                              minstore: JSONValue, policies: Policies) -> (arrangement: JSONValue, facts: [JSONValue]) {
        let cfg: JSONValue = config.objectValue != nil ? config : .object([:])
        let valveOn = cfg.objectValue?["stack_vs_shrink_threshold"] != nil
        let reclaim = policies.reclaim ?? cfg.objectValue?["reclaim_policy"]?.stringValue ?? "absorber"
        let focus: JSONValue = (foc.stringValue == "") ? .null : foc
        let T = Project.normTopology(topo)
        let hasSegments = t.at(path: "segments") != nil && t.at(path: "segments") != .null

        // Author-time min stamp (native edition) + the z-demotion gate.
        var ts = Minsize.stampMinSizesArr(arr: t, store: minstore, observed: obs, topo: topo)
        if cfg.objectValue?["demote"]?.boolValue == true, hasSegments {
            ts = Arrangement.stampDemotable(store: ts, obs: obs, topo: topo)
        }

        let liveObs = obs.filter { $0.objectValue?["minimized"]?.boolValue != true }
        let priorBound: JSONValue? = hasSegments
            ? Arrangement.carryableWindows(t, topo: topo)
            : nil
        let live = Autotile.partition(liveObs, rules).managed
        let liveJSON = JSONValue.array(live.map { .int($0) })

        func isAdmissible(_ store: JSONValue) -> Bool {
            policies.nativePromote ? Arrangement.isCarryable(store) : Arrangement.isFlat(store)
        }

        let nativeNoop = hasSegments
            && JQOrder.equal(liveJSON, priorBound ?? .null)
            && Arrangement.observedBindingsStayOnDisplay(
                store: t, observed: liveObs, managed: live, topology: T)
            && isAdmissible(t)

        let priorArr = (priorBound?.arrayValue ?? []).compactMap(\.intValue)
        let goners = priorArr.filter { !live.contains($0) }
        let newcomers = live.filter { !priorArr.contains($0) }

        func displayIsGrid(_ did: String) -> Bool {
            Arrangement.bags(Arrangement.parseSegs(t.at(path: "segments")), T).contains { bag in
                "\(bag.displayId ?? 0)" == did && Set(bag.segments.map(\.axis)).count >= 2
            }
        }

        var nativePrune = policies.nativePrune && hasSegments && goners.count == 1
            && newcomers.isEmpty && isAdmissible(t)
        if nativePrune {
            let gdid = (t.at(path: "bindings")?.objectValue ?? [:])
                .first { $0.value.objectValue?["window_id"]?.intValue == goners[0] }?
                .key.split(separator: ":").first.map(String.init) ?? ""
            nativePrune = displayIsGrid(gdid)
        }
        let np: JSONValue? = nativePrune
            ? {
                let r = Arrangement.bridgeArrangementNativePrune(
                    store: ts, goners: goners, focused: focus, topo: topo, policy: reclaim)
                return r == .null ? nil : r
            }()
            : nil

        var ndid: Int64?
        if newcomers.count == 1,
           let nwobs = obs.first(where: { $0.objectValue?["window_id"]?.intValue == newcomers[0] }) {
            ndid = Arrangement.homeDisplay(nwobs.objectValue?["frame"] ?? .null, T)
        }
        var nativeAdopt = policies.nativeAdopt && hasSegments && newcomers.count == 1
            && goners.isEmpty && isAdmissible(t) && ndid != nil
        if nativeAdopt, let ndid {
            nativeAdopt = displayIsGrid(String(ndid))
        }
        let na: JSONValue? = nativeAdopt
            ? {
                let r = Arrangement.bridgeArrangementNativeAdopt(
                    store: ts, newcomers: newcomers, ndid: ndid!, focused: focus, topo: topo)
                return r == .null ? nil : r
            }()
            : nil

        let normTopoJSON = topologyJSON(T)
        let priorPromos = t.at(path: "promotions")?.arrayValue ?? []

        if nativeNoop {
            var arr = Arrangement.bridgeArrangementNative(store: ts, topo: topo).objectValue ?? [:]
            arr["topology"] = normTopoJSON
            arr["promotions"] = .array(priorPromos)
            return (.object(arr), [])
        }
        if let np {
            let gw = goners[0]
            let gobs = obs.first { $0.objectValue?["window_id"]?.intValue == gw }
            let cause: String
            if gobs == nil {
                cause = "departed"
            } else if gobs?.objectValue?["minimized"]?.boolValue == true {
                cause = "minimized"
            } else {
                cause = "floated"
            }
            var arr = (np.at(path: "arr") ?? .object([:])).objectValue ?? [:]
            arr["topology"] = normTopoJSON
            arr["promotions"] = .array(Arrangement.carryPromos(bridge: np.at(path: "arr") ?? .object([:]),
                                                               promos: priorPromos, topo: topo))
            let fact = JSONValue.object([
                "kind": .string("prune"), "window_id": .int(gw), "leaf": .string("w:\(gw)"),
                "cause": .string(cause), "absorber": np.at(path: "absorber") ?? .null,
            ])
            return (.object(arr), [fact])
        }
        if let na {
            let aw = newcomers[0]
            var arr = na.objectValue ?? [:]
            arr["topology"] = normTopoJSON
            arr["promotions"] = .array(Arrangement.carryPromos(bridge: na, promos: priorPromos, topo: topo))
            let fact = JSONValue.object([
                "kind": .string("adopt"), "window_id": .int(aw), "leaf": .string("w:\(aw)"),
            ])
            return (.object(arr), [fact])
        }

        // ── the cold tail ────────────────────────────────────────────────
        var prior = priorTreeStructured(t, T) ?? priorTree(t)
        prior = carryManualStacks(t, prior)
        if prior.at(path: "nodes") == nil || prior.at(path: "nodes") == .null {
            prior = .object(["root_id": .null, "nodes": .object([:])])
        }
        let base = Autotile.sync(tree: prior, observed: obs, rules: rules,
                                 focusedLeaf: focus.stringValue, topology: topo, config: cfg)
        let valved = valveOn
            ? Balance.valveLive(synced: base.tree, obs: obs, minstore: minstore,
                                topo: topo, foc: focus, config: cfg)
            : (tree: base.tree, facts: [])
        let stamped = Minsize.stampMinSizes(tree: valved.tree, store: minstore, observed: obs, topo: topo)
        let hasStacks = Autotile.nodes(stamped).values.contains {
            $0.objectValue?["mode"]?.stringValue == "stack"
        }
        func bridgeOf(_ tree: JSONValue) -> JSONValue {
            hasStacks
                ? Arrangement.bridgeArrangementFolded(tree: tree, topo: topo)
                : Arrangement.bridgeArrangement(tree: tree, topo: topo)
        }
        let bridge0 = bridgeOf(stamped)
        let want = Set(Autotile.nodes(valved.tree).compactMap { $0.value.objectValue?["window_id"]?.intValue })
        var got = Set((bridge0.at(path: "bindings")?.objectValue ?? [:]).compactMap {
            $0.value.objectValue?["window_id"]?.intValue
        })
        for o in bridge0.at(path: "off_top")?.arrayValue ?? [] {
            if let w = o.objectValue?["window_id"]?.intValue { got.insert(w) }
        }
        var unfitFact: JSONValue?
        if got != want {
            unfitFact = .object(["kind": .string("min_stamp_unfit_fallback"),
                                 "dropped": .array(want.subtracting(got).sorted().map { .int($0) })])
        }
        let bridge = unfitFact == nil ? bridge0 : bridgeOf(valved.tree)
        let carried = Arrangement.carryPromos(bridge: bridge, promos: priorPromos, topo: topo)
        var arr = bridge.objectValue ?? [:]
        arr["topology"] = normTopoJSON
        arr["promotions"] = .array(carried)
        var facts = base.facts + valved.facts
        if let unfitFact { facts.append(unfitFact) }
        return (.object(arr), facts)
    }

    // Emit the normalized topology exactly as P::norm_topology serializes.
    static func topologyJSON(_ T: NormTopology) -> JSONValue {
        var object: JSONObject = [
            "displays": .array(T.displays.map { d in
                .object(["id": d.id.map { .int($0) } ?? .null,
                         "frame": d.frame.json, "usable": d.usable.json,
                         "main": .bool(d.main)])
            }),
            "dead_zones": .array(T.deadZones.map(\.json)),
            "gap": .number(T.gap),
        ]
        if T.hasExplicitOuterGap { object["outer_gap"] = .double(T.outerGap) }
        return .object(object)
    }
}
