// Crowding resolution preserves authored footprints, unfolds before folding,
// reveals focus and checks window conservation over learned minimum sizes.
import Foundation

public enum Balance {
    static func splitDim(_ mode: String) -> String {
        mode == "row" ? "w" : "h"
    }

    static func nodeMode(_ n: JSONValue?) -> String {
        n?.objectValue?["mode"]?.stringValue ?? "region"
    }

    // node_frames — every node's assigned frame, internal nodes included.
    static func nodeFrames(_ tree: JSONValue, _ topo: JSONValue) -> [String: Frame] {
        let T = Project.normTopology(topo)
        let ns = Autotile.nodes(tree)
        guard let root = Autotile.rootId(tree), ns[root] != nil else { return [:] }
        var out: [String: Frame] = [:]
        func go(_ id: String, _ frame: Frame, _ seen: [String]) {
            if seen.contains(id) { return }
            out[id] = frame
            guard let n = ns[id]?.objectValue, !Autotile.isLeaf(.object(n)) else { return }
            for sl in Project.childSlots(ns, T, n, frame) {
                if let f = sl.frame { go(sl.childId, f, seen + [id]) }
            }
        }
        go(root, Project.canvasRect(T), [])
        return out
    }

    static func strict(_ ns: JSONObject) -> Bool {
        for id in ns.keys {
            let parents = ns.values.filter { Autotile.children($0).contains(id) }.count
            if parents > 1 { return false }
        }
        return true
    }

    static func required(_ ns: JSONObject, _ T: NormTopology,
                         _ node: JSONObject, _ frames: [String: Frame]) -> Double {
        let kids = (node["children"]?.arrayValue ?? []).compactMap(\.stringValue)
        let ax = splitDim(node["mode"]?.stringValue ?? "region")
        let gap = T.gap
        var sum = 0.0
        for cid in kids {
            let cn = ns[cid]?.objectValue ?? [:]
            if (cn["frame_source"]?.stringValue ?? "computed") == "computed" {
                let m = Project.subtreeMin(ns, cid, gap)
                sum += ax == "w" ? m.w : m.h
            } else {
                let f = frames[cid]
                sum += ax == "w" ? (f?.w ?? 0) : (f?.h ?? 0)
            }
        }
        return sum + gap * Double(max(kids.count - 1, 0))
    }

    static func unfold(_ tree: JSONValue) -> JSONValue {
        var t = tree.objectValue ?? [:]
        var nn = t["nodes"]?.objectValue ?? [:]
        for (k, v) in nn {
            guard var o = v.objectValue, o["stack_source"]?.stringValue == "valve" else { continue }
            o["mode"] = o["valve_from"] ?? .string("row")
            o.removeValue(forKey: "stack_source")
            o.removeValue(forKey: "valve_from")
            o.removeValue(forKey: "top")
            nn[k] = .object(o)
        }
        t["nodes"] = .object(nn)
        return .object(t)
    }

    static func descendantBoundLeaves(_ ns: JSONObject, _ id: String) -> [String] {
        Floorplan.closure(ns, seeds: [id]).sorted().filter {
            Autotile.isLeaf(ns[$0]) && (ns[$0]?.objectValue?["window_id"].map { $0 != .null } ?? false)
        }
    }

    struct Folded {
        let node: String
        let axis: String
        let span: Double
        let required: Double
    }

    static func foldNode(_ ns: inout JSONObject, _ T: NormTopology,
                         _ frames: [String: Frame], _ thr: Double, _ id: String,
                         _ folded: inout [Folded]) {
        guard let n = ns[id]?.objectValue, !Autotile.isLeaf(.object(n)) else { return }
        for cid in (n["children"]?.arrayValue ?? []).compactMap(\.stringValue) {
            foldNode(&ns, T, frames, thr, cid, &folded)
        }
        guard var cur = ns[id]?.objectValue else { return }
        let mode = cur["mode"]?.stringValue ?? "region"
        guard mode == "row" || mode == "col",
              (cur["children"]?.arrayValue ?? []).count >= 2,
              (cur["ratio_source"]?.stringValue ?? "computed") != "pinned",
              let frame = frames[id] else { return }
        let ax = splitDim(mode)
        let span = ax == "w" ? frame.w : frame.h
        let req = required(ns, T, cur, frames)
        if req > span + thr {
            cur["mode"] = .string("stack")
            cur["stack_source"] = .string("valve")
            cur["valve_from"] = .string(mode)
            ns[id] = .object(cur)
            folded.append(Folded(node: id, axis: mode, span: span, required: req))
        }
    }

    // op_reveal_leaf — retarget every stack ancestor on the lex-first path.
    static func revealLeaf(_ tree: JSONValue, _ leaf: String) -> JSONValue? {
        let ns = Autotile.nodes(tree)
        guard ns[leaf] != nil,
              let path = Autotile.firstLexPath(ns, Autotile.rootId(tree), leaf) else { return nil }
        var t = tree
        for i in 0..<(path.count - 1) {
            let pid = path[i]
            let pn = Autotile.nodes(t)[pid]
            if nodeMode(pn) == "stack" {
                guard Autotile.children(pn).contains(path[i + 1]) else { return nil }
                t = Autotile.mutNode(t, pid) { $0["top"] = .string(path[i + 1]) }
            }
        }
        return t
    }

    // valve — unfold → measure → bottom-up fold → focus reveal → facts.
    public static func valve(tree: JSONValue, topo: JSONValue, foc: JSONValue,
                             config: JSONValue) -> (tree: JSONValue, facts: [JSONValue]) {
        let cfg = config.objectValue ?? [:]
        let thr = cfg["stack_vs_shrink_threshold"]?.numberValue ?? 0
        let ns0 = Autotile.nodes(tree)
        guard strict(ns0), tree.at(path: "root_id") != nil, tree.at(path: "root_id") != .null else {
            return (tree, [])
        }
        let T = Project.normTopology(topo)
        let focus: String? = {
            guard let s = foc.stringValue, !s.isEmpty else { return nil }
            return s
        }()
        let prior = ns0.filter { $0.value.objectValue?["stack_source"]?.stringValue == "valve" }.map(\.key).sorted()
        let clean = unfold(tree)
        let frames = nodeFrames(clean, topo)
        var nn = Autotile.nodes(clean)
        var folded: [Folded] = []
        if let root = Autotile.rootId(clean) {
            foldNode(&nn, T, frames, thr, root, &folded)
        }
        var foldedTree = clean.objectValue ?? [:]
        foldedTree["nodes"] = .object(nn)
        var final = JSONValue.object(foldedTree)
        if let focus, Autotile.nodes(final)[focus] != nil {
            final = revealLeaf(final, focus) ?? final
        }
        let proj = Project.project(tree: final, topo: topo)
        let foldedIds = Set(folded.map(\.node))
        let foldFacts = folded.map { f -> JSONValue in
            let leaves = descendantBoundLeaves(Autotile.nodes(final), f.node)
            let top = leaves.first { proj.leaves[$0]?.presented == true }
            let surplus = leaves.filter { proj.leaves[$0]?.presented != true }.sorted()
            return .object(["kind": .string("stack"), "action": .string("fold"),
                            "node": .string(f.node), "axis": .string(f.axis),
                            "span": .number(f.span), "required": .number(f.required),
                            "top": top.map { .string($0) } ?? .null,
                            "surplus": .array(surplus.map { .string($0) })])
        }
        let unfoldFacts = prior.filter { !foldedIds.contains($0) }.map { p -> JSONValue in
            .object(["kind": .string("stack"), "action": .string("unfold"), "node": .string(p)])
        }
        return (final, unfoldFacts + foldFacts)
    }

    static func hiddenExplained(_ ns: JSONObject, _ root: String?, _ leaf: String) -> Bool {
        let paths = Floorplan.pathsTo(ns, root: root, target: leaf)
        guard !paths.isEmpty else { return false }
        return paths.contains { path in
            (0..<(path.count - 1)).contains { i in
                let p = ns[path[i]]?.objectValue ?? [:]
                guard (p["mode"]?.stringValue ?? "region") == "stack" else { return false }
                let k = (p["children"]?.arrayValue ?? []).compactMap(\.stringValue)
                let pres = p["top"]?.stringValue ?? k.first
                guard let pres, k.contains(pres) else { return false }
                return pres != path[i + 1]
            }
        }
    }

    public static func conservation(tree: JSONValue, topo: JSONValue, foc: JSONValue,
                                    config: JSONValue) -> JSONValue {
        let v = valve(tree: tree, topo: topo, foc: foc, config: config)
        let ns = Autotile.nodes(v.tree)
        let root = Autotile.rootId(v.tree)
        let proj = Project.project(tree: v.tree, topo: topo)
        let managed = ns.filter {
            Autotile.isLeaf($0.value) && ($0.value.objectValue?["window_id"].map { $0 != .null } ?? false)
        }.map(\.key).sorted()
        let presented = managed.filter { proj.leaves[$0]?.presented == true }.sorted()
        let hidden = managed.filter { proj.leaves[$0]?.presented != true }.sorted()
        let unexplained = hidden.filter { !hiddenExplained(ns, root, $0) }.sorted()
        let overflowing = presented.filter { proj.leaves[$0]?.overflow == true }.sorted()
        func strs(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }
        return .object([
            "ok": .bool(unexplained.isEmpty),
            "managed": strs(managed), "presented": strs(presented), "hidden": strs(hidden),
            "unexplained": strs(unexplained), "overflowing": strs(overflowing),
        ])
    }

    // valve_live — stamp learned mins for the DECISION, strip before persist.
    public static func valveLive(synced: JSONValue, obs: [JSONValue], minstore: JSONValue,
                                 topo: JSONValue, foc: JSONValue,
                                 config: JSONValue) -> (tree: JSONValue, facts: [JSONValue]) {
        let unmin = Autotile.nodes(synced).filter {
            $0.value.objectValue?["min_size"] == nil || $0.value.objectValue?["min_size"] == .null
        }.map(\.key)
        let stamped = Minsize.stampMinSizes(tree: synced, store: minstore, observed: obs, topo: topo)
        let v = valve(tree: stamped, topo: topo, foc: foc, config: config)
        var t = v.tree.objectValue ?? [:]
        var nn = t["nodes"]?.objectValue ?? [:]
        for k in unmin {
            guard var o = nn[k]?.objectValue else { continue }
            o.removeValue(forKey: "min_size")
            nn[k] = .object(o)
        }
        t["nodes"] = .object(nn)
        return (.object(t), v.facts)
    }
}
