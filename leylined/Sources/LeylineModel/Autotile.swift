// Tileability and explicit rules feed one structural reconciliation pass:
// adopt, remove/collapse, display placement and displaced-window rehoming.
import Foundation

public enum Autotile {
    // ── float rules ──────────────────────────────────────────────────────
    static func rulesList(_ rules: JSONValue) -> [JSONValue] {
        if let a = rules.arrayValue { return a }
        return rules.at(path: "rules")?.arrayValue ?? []
    }

    static func regexTest(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func ruleMatches(_ w: JSONObject, _ r: JSONObject) -> Bool {
        if let app = r["app"]?.stringValue,
           !regexTest(w["app"]?.stringValue ?? "", app) { return false }
        if let title = r["title"]?.stringValue,
           !regexTest(w["title"]?.stringValue ?? "", title) { return false }
        if let rid = r["window_id"], !JQOrder.equal(rid, w["window_id"] ?? .null) { return false }
        return true
    }

    public static func floatVerdict(_ w: JSONValue, _ rules: JSONValue) -> String {
        var verdict = "on"
        for r in rulesList(rules) {
            guard let ro = r.objectValue, let wo = w.objectValue else { continue }
            if ruleMatches(wo, ro) { verdict = ro["manage"]?.stringValue ?? "off" }
        }
        return verdict
    }

    public static func tileable(_ w: JSONValue, _ rules: JSONValue) -> Bool {
        let o = w.objectValue ?? [:]
        let resizable = o["resizable"]?.boolValue ?? false
        let standard = o["role"]?.stringValue == "AXWindow" && o["subrole"]?.stringValue == "AXStandardWindow"
        return resizable && standard && floatVerdict(w, rules) != "off"
    }

    public static func partition(_ observed: [JSONValue], _ rules: JSONValue) -> (managed: [Int64], float: [Int64]) {
        var managed: [Int64] = []
        var float: [Int64] = []
        for w in observed {
            guard let wid = w.objectValue?["window_id"]?.intValue else { continue }
            if tileable(w, rules) { managed.append(wid) } else { float.append(wid) }
        }
        return (managed.sorted(), float.sorted())
    }

    // ── tree helpers over raw JSONValue ─────────────────────────────────
    static func nodes(_ tree: JSONValue) -> JSONObject {
        tree.at(path: "nodes")?.objectValue ?? [:]
    }

    static func rootId(_ tree: JSONValue) -> String? {
        tree.at(path: "root_id")?.stringValue
    }

    static func isLeaf(_ n: JSONValue?) -> Bool {
        (n?.objectValue?["children"]?.arrayValue ?? []).isEmpty
    }

    static func children(_ n: JSONValue?) -> [String] {
        (n?.objectValue?["children"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    static func setNode(_ tree: JSONValue, _ id: String, _ node: JSONValue) -> JSONValue {
        var t = tree.objectValue ?? [:]
        var ns = t["nodes"]?.objectValue ?? [:]
        ns[id] = node
        t["nodes"] = .object(ns)
        return .object(t)
    }

    static func mutNode(_ tree: JSONValue, _ id: String, _ f: (inout JSONObject) -> Void) -> JSONValue {
        var t = tree.objectValue ?? [:]
        var ns = t["nodes"]?.objectValue ?? [:]
        var n = ns[id]?.objectValue ?? [:]
        f(&n)
        ns[id] = .object(n)
        t["nodes"] = .object(ns)
        return .object(t)
    }

    static func firstLexPath(_ nodes: JSONObject, _ root: String?, _ target: String) -> [String]? {
        Floorplan.pathsTo(nodes, root: root, target: target)
            .sortedStableBy { .string($0.joined(separator: "/")) }
            .first
    }

    // ── BSP adopt ────────────────────────────────────────────────────────
    struct SplitAxis {
        let axis: String
        let reason: String
    }

    static func splitAxis(_ frame: Frame?) -> SplitAxis {
        guard let frame else { return SplitAxis(axis: "row", reason: "aspect:null") }
        return frame.w >= frame.h
            ? SplitAxis(axis: "row", reason: "aspect:w>=h")
            : SplitAxis(axis: "col", reason: "aspect:w<h")
    }

    static func splitNodeId(_ leafId: String, _ nodes: JSONObject) -> String {
        let base = "i:" + leafId
        if nodes[base] == nil { return base }
        for i in 1..<1_000_000 where nodes["\(base).\(i)"] == nil {
            return "\(base).\(i)"
        }
        return base + ".x"
    }

    static func splitLeaf(_ tree: JSONValue, _ target: String, _ newLeafId: String,
                          _ orientation: String, _ side: String) -> JSONValue {
        let ns = nodes(tree)
        let root = rootId(tree)
        let N = splitNodeId(newLeafId, ns)
        let kids: [JSONValue] = side == "before"
            ? [.string(newLeafId), .string(target)]
            : [.string(target), .string(newLeafId)]
        let fresh = JSONValue.object(["id": .string(N), "mode": .string(orientation), "children": .array(kids)])
        if target == root {
            var t = tree.objectValue ?? [:]
            t["root_id"] = .string(N)
            var nn = ns
            nn[N] = fresh
            t["nodes"] = .object(nn)
            return .object(t)
        }
        guard let path = firstLexPath(ns, root, target), path.count >= 2 else { return tree }
        let parent = path[path.count - 2]
        var out = setNode(tree, N, fresh)
        out = mutNode(out, parent) { p in
            p["children"] = .array((p["children"]?.arrayValue ?? []).map {
                $0.stringValue == target ? .string(N) : $0
            })
        }
        return out
    }

    static func adopt(_ tree: JSONValue, _ windowLeaf: JSONValue, _ focusedLeaf: String?, _ focusedFrame: Frame?) -> JSONValue {
        let wid = windowLeaf.objectValue?["id"]?.stringValue ?? ""
        let ns = nodes(tree)
        let root = rootId(tree)
        let mode = splitAxis(focusedFrame).axis
        if root == nil || ns[root!] == nil {
            return .object(["root_id": .string(wid), "nodes": .object([wid: windowLeaf])])
        }
        let reach = Floorplan.closure(ns, seeds: [root!])
        var F: String?
        if let fl = focusedLeaf, ns[fl] != nil, isLeaf(ns[fl]), reach.contains(fl) {
            F = fl
        } else {
            F = ns.filter { isLeaf($0.value) && reach.contains($0.key) }.map(\.key).sorted().first
        }
        guard let F else {
            var out = setNode(tree, wid, windowLeaf)
            out = mutNode(out, root!) { r in
                r["children"] = .array((r["children"]?.arrayValue ?? []) + [.string(wid)])
            }
            return out
        }
        let withLeaf = setNode(tree, wid, windowLeaf)
        return splitLeaf(withLeaf, F, wid, mode, "after")
    }

    // ── remove + collapse ────────────────────────────────────────────────
    static func collapseSingletons(_ tree: JSONValue) -> JSONValue {
        var t = tree
        while true {
            let ns = nodes(t)
            let single = ns.first { (_, v) in  // jq: to_entries — insertion order
                let o = v.objectValue ?? [:]
                return (o["children"]?.arrayValue ?? []).count == 1
                    && (o["mode"]?.stringValue ?? "region") != "region"
                    && (o["frame_source"]?.stringValue ?? "computed") != "pinned"
            }
            guard let (sid, sv) = single,
                  let child = sv.objectValue?["children"]?.arrayValue?.first?.stringValue else { return t }
            var to = t.objectValue ?? [:]
            if to["root_id"]?.stringValue == sid { to["root_id"] = .string(child) }
            var nn = to["nodes"]?.objectValue ?? [:]
            nn.removeValue(forKey: sid)
            for (k, v) in nn {
                guard var o = v.objectValue, o["children"] != nil else { continue }
                o["children"] = .array((o["children"]?.arrayValue ?? []).map {
                    $0.stringValue == sid ? .string(child) : $0
                })
                nn[k] = .object(o)
            }
            to["nodes"] = .object(nn)
            t = .object(to)
        }
    }

    static func remove(_ tree: JSONValue, _ leaf: String) -> JSONValue {
        let ns = nodes(tree)
        let root = rootId(tree)
        guard ns[leaf] != nil else { return tree }
        if leaf == root {
            return .object(["root_id": .null, "nodes": .object([:])])
        }
        guard let path = firstLexPath(ns, root, leaf), path.count >= 2 else {
            var t = tree.objectValue ?? [:]
            var nn = ns
            nn.removeValue(forKey: leaf)
            t["nodes"] = .object(nn)
            return .object(t)
        }
        let parent = path[path.count - 2]
        let idx = children(ns[parent]).firstIndex(of: leaf)
        var out = mutNode(tree, parent) { p in
            var kids = p["children"]?.arrayValue ?? []
            if let idx, idx < kids.count { kids.remove(at: idx) }
            p["children"] = .array(kids)
            if var ratios = p["ratios"]?.arrayValue, let idx, idx < ratios.count {
                ratios.remove(at: idx)
                p["ratios"] = .array(ratios)
            }
            if p["top"]?.stringValue == leaf { p.removeValue(forKey: "top") }
        }
        var to = out.objectValue ?? [:]
        var nn = to["nodes"]?.objectValue ?? [:]
        nn.removeValue(forKey: leaf)
        to["nodes"] = .object(nn)
        out = .object(to)
        return collapseSingletons(out)
    }

    // ── auto-proportion + reequalize ─────────────────────────────────────
    static func reproportionTargets(_ tree: JSONValue) -> [(node: String, axis: String)] {
        nodes(tree).compactMap { (k, v) -> (String, String)? in
            let o = v.objectValue ?? [:]
            let mode = o["mode"]?.stringValue ?? "region"
            guard mode == "row" || mode == "col",
                  (o["ratio_source"]?.stringValue ?? "computed") != "pinned",
                  o["ratios"] != nil else { return nil }
            return (k, mode)
        }
        .sorted { $0.0 < $1.0 }
    }

    public static func autoProportion(_ tree: JSONValue) -> JSONValue {
        var t = tree.objectValue ?? [:]
        var nn = t["nodes"]?.objectValue ?? [:]
        for (k, v) in nn {
            guard var o = v.objectValue else { continue }
            let mode = o["mode"]?.stringValue ?? "region"
            guard mode == "row" || mode == "col",
                  (o["ratio_source"]?.stringValue ?? "computed") != "pinned",
                  o["ratios"] != nil else { continue }
            o.removeValue(forKey: "ratios")
            nn[k] = .object(o)
        }
        t["nodes"] = .object(nn)
        return .object(t)
    }

    static func reequalize(_ tree: JSONValue, _ policy: String, _ removed: Int) -> (tree: JSONValue, facts: [JSONValue]) {
        if policy == "off" || (policy == "on_remove" && removed == 0) {
            return (tree, [])
        }
        let facts = reproportionTargets(tree).map { t -> JSONValue in
            .object(["kind": .string("reproportion"), "window_id": .null,
                     "node": .string(t.node), "axis": .string(t.axis)])
        }
        return (autoProportion(tree), facts)
    }

    // ── mounts + homing ──────────────────────────────────────────────────
    static func mountId(_ d: Int64) -> String { "d:\(d)" }

    static func ensureScaffold(_ tree: JSONValue, _ want: [Int64]) -> JSONValue {
        var t: JSONValue
        let ns = nodes(tree)
        if rootId(tree) == "root", ns["root"]?.objectValue?["children"] != nil {
            t = tree
        } else {
            t = .object(["root_id": .string("root"),
                         "nodes": .object(["root": .object(["id": .string("root"),
                                                            "mode": .string("region"),
                                                            "children": .array([])])])])
        }
        for d in Array(Set(want)).sorted() {
            let m = mountId(d)
            if nodes(t)[m] != nil { continue }
            t = setNode(t, m, .object(["id": .string(m), "mode": .string("row"),
                                       "frame_source": .string("pinned"),
                                       "display_id": .int(d), "children": .array([])]))
            t = mutNode(t, "root") { r in
                r["children"] = .array((r["children"]?.arrayValue ?? []) + [.string(m)])
            }
        }
        t = mutNode(t, "root") { r in
            r["children"] = .array((r["children"]?.arrayValue ?? []).jqUnique())
        }
        return t
    }

    static func rehomeToEmpty(_ home: [String: Int64], _ newcomers: [Int64],
                              _ priorBound: [Int64], _ disps: [NormDisplay]) -> [String: Int64] {
        let occupied = disps.compactMap(\.id).filter { d in
            priorBound.contains { home[String($0)] == d }
        }
        let empties = disps.compactMap(\.id).filter { !occupied.contains($0) }.sorted()
        var out = home
        for (i, w) in newcomers.enumerated() where i < empties.count {
            out[String(w)] = empties[i]
        }
        return out
    }

    static func rehomeDisplaced(_ tree: JSONValue, _ home: [String: Int64]) -> (tree: JSONValue, facts: [JSONValue]) {
        let ns = nodes(tree)
        let root = rootId(tree)
        var displaced: [(leaf: String, w: Int64, cur: Int64, want: Int64?)] = []
        for (k, v) in ns {  // jq: to_entries — insertion order
            guard isLeaf(v), let wid = v.objectValue?["window_id"]?.intValue else { continue }
            guard let path = firstLexPath(ns, root, k), path.count >= 2,
                  let cur = ns[path[1]]?.objectValue?["display_id"]?.intValue else { continue }
            let want = home[String(wid)]
            if cur != want {
                displaced.append((k, wid, cur, want))
            }
        }
        var t = tree
        for d in displaced { t = remove(t, d.leaf) }
        let facts = displaced.map { d -> JSONValue in
            .object(["kind": .string("rehome"), "window_id": .int(d.w), "leaf": .string(d.leaf),
                     "from_display": .int(d.cur), "to_display": d.want.map { .int($0) } ?? .null])
        }
        return (t, facts)
    }

    static func dropEmptyMounts(_ tree: JSONValue) -> JSONValue {
        let ns = nodes(tree)
        let empties = ns.filter { (_, v) in
            let o = v.objectValue ?? [:]
            return o["frame_source"]?.stringValue == "pinned"
                && (o["children"]?.arrayValue ?? []).isEmpty
        }.map(\.key)  // jq: to_entries — insertion order
        var t = tree
        for m in empties {
            t = mutNode(t, "root") { r in
                r["children"] = .array((r["children"]?.arrayValue ?? []).filter { $0.stringValue != m })
            }
            var to = t.objectValue ?? [:]
            var nn = to["nodes"]?.objectValue ?? [:]
            nn.removeValue(forKey: m)
            to["nodes"] = .object(nn)
            t = .object(to)
        }
        return t
    }

    static func adoptNewcomers(_ tree: JSONValue, _ newcomers: [Int64], _ home: [String: Int64],
                               _ focusedLeaf: String?, _ topology: JSONValue) -> (tree: JSONValue, facts: [JSONValue]) {
        var t = tree
        var anchors: [String: String] = [:]
        var facts: [JSONValue] = []
        for w in newcomers {
            let wid = "w:\(w)"
            let leaf = JSONValue.object(["id": .string(wid), "window_id": .int(w)])
            guard let disp = home[String(w)] else { continue }
            let m = mountId(disp)
            let mkids = children(nodes(t)[m])
            if mkids.isEmpty {
                t = setNode(t, wid, leaf)
                t = mutNode(t, m) { $0["children"] = .array([.string(wid)]) }
                anchors[m] = wid
                facts.append(.object(["kind": .string("seed"), "window_id": .int(w),
                                      "leaf": .string(wid), "mount": .string(m),
                                      "display_id": .int(disp)]))
            } else {
                let ns = nodes(t)
                let sub = Floorplan.closure(ns, seeds: [m])
                var foc: String?
                if let a = anchors[m], sub.contains(a) {
                    foc = a
                } else if let fl = focusedLeaf, sub.contains(fl), isLeaf(ns[fl]) {
                    foc = fl
                } else {
                    foc = sub.filter { isLeaf(ns[$0]) }.sorted().first
                }
                let ff = foc.flatMap { Project.project(tree: t, topo: topology).leaves[$0]?.desiredFrame }
                let sa = splitAxis(ff)
                t = adopt(t, leaf, foc, ff)
                anchors[m] = wid
                facts.append(.object(["kind": .string("adopt"), "window_id": .int(w),
                                      "leaf": .string(wid),
                                      "anchor_leaf": foc.map { .string($0) } ?? .null,
                                      "mount": .string(m), "axis": .string(sa.axis),
                                      "axis_reason": .string(sa.reason), "side": .string("after")]))
            }
        }
        return (t, facts)
    }

    // ── sync — the keystone ──────────────────────────────────────────────
    public static func sync(tree: JSONValue, observed: [JSONValue], rules: JSONValue,
                            focusedLeaf: String?, topology: JSONValue,
                            config: JSONValue) -> (tree: JSONValue, facts: [JSONValue]) {
        let cfg = config.objectValue ?? [:]
        let reqpol = cfg["reequalize_policy"]?.stringValue ?? "always"
        let homing = cfg["homing"]?.stringValue ?? "focus"
        let obs = observed

        // Buried stack members exempt from the minimized gate.
        var buriedWids: [Int64] = []
        for (_, v) in nodes(tree) {
            guard let o = v.objectValue, o["mode"]?.stringValue == "stack" else { continue }
            let top = o["top"]?.stringValue
            for c in children(v) where c != top {
                if let w = nodes(tree)[c]?.objectValue?["window_id"]?.intValue {
                    buriedWids.append(w)
                }
            }
        }
        let obsWids = obs.compactMap { $0.objectValue?["window_id"]?.intValue }

        func effectiveMinimized(_ w: JSONValue) -> Bool {
            let o = w.objectValue ?? [:]
            if let ax = o["ax_minimized"] { return ax.boolValue ?? false }
            return o["minimized"]?.boolValue ?? false
        }
        let liveManaged = partition(obs.filter { !effectiveMinimized($0) }, rules).managed
        let live = Array(Set(liveManaged + buriedWids.filter { obsWids.contains($0) })).sorted()

        // PRUNE. jq: to_entries — insertion order (the step-8 live capture caught
        // a key-sort here diverging from jq on a 3-departure settle).
        let dead = nodes(tree).compactMap { (k, v) -> (w: Int64, leaf: String)? in
            guard let wid = v.objectValue?["window_id"]?.intValue, !live.contains(wid) else { return nil }
            return (wid, k)
        }
        var pruned = tree
        for d in dead {
            if let leaf = nodes(pruned)
                .first(where: { $0.value.objectValue?["window_id"]?.intValue == d.w })?.key {
                pruned = remove(pruned, leaf)
            }
        }
        let pruneFacts = dead.map { d -> JSONValue in
            let o = obs.first { $0.objectValue?["window_id"]?.intValue == d.w }
            let cause: String
            if o == nil {
                cause = "departed"
            } else if effectiveMinimized(o!) {
                cause = "minimized"
            } else {
                cause = "floated"
            }
            return .object(["kind": .string("prune"), "window_id": .int(d.w),
                            "leaf": .string(d.leaf), "cause": .string(cause)])
        }

        if live.isEmpty {
            let req = reequalize(pruned, reqpol, dead.count)
            return (req.tree, pruneFacts + req.facts)
        }

        let disps = Project.normTopology(topology).displays
        var homeGeo: [String: Int64] = [:]
        for w in obs {
            guard let wid = w.objectValue?["window_id"]?.intValue, live.contains(wid) else { continue }
            let f = Frame.from(w.objectValue?["frame"]) ?? Frame(x: 0, y: 0, w: 0, h: 0)
            if let d = Geometry.assignDisplay(f, disps) { homeGeo[String(wid)] = d }
        }
        let priorBound = nodes(pruned).compactMap { $0.value.objectValue?["window_id"]?.intValue }
        let newcomersHome = live.filter { !priorBound.contains($0) }.sorted()
        let home = homing == "empty_first"
            ? rehomeToEmpty(homeGeo, newcomersHome, priorBound, disps)
            : homeGeo
        let scaffold = ensureScaffold(pruned, Array(home.values))
        let rh = rehomeDisplaced(scaffold, home)
        let present = nodes(rh.tree).compactMap { $0.value.objectValue?["window_id"]?.intValue }
        let newcomers = live.filter { !present.contains($0) }.sorted()
        let ad = adoptNewcomers(rh.tree, newcomers, home, focusedLeaf, topology)
        let dropped = dropEmptyMounts(ad.tree)
        let req = reequalize(dropped, reqpol, dead.count)
        return (req.tree, pruneFacts + rh.facts + ad.facts + req.facts)
    }
}
