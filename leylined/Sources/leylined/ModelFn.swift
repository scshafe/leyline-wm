// leylined model fn — the per-def fixture dispatcher, mirroring the
// arrangement arm of tests/oracles/frozen-models.sh:167 verbatim for the WIRED read-side fns
// (model-port plan step 4). An unwired fn exits 3 — the harness prints it as a
// clean SKIP, never a vacuous green. Also: model bridge-targets (the golden
// engine_bridge route: arrangement_targets ∘ bridge_arrangement).
import Foundation
import LeylineModel

private func fnUnwired(_ name: String) -> Int32 {
    FileHandle.standardError.write(Data("leylined model fn: '\(name)' not wired yet (pending model-port slice)\n".utf8))
    return 3
}

private func loadFixture(_ args: [String]) -> JSONValue? {
    guard let i = args.firstIndex(of: "--fixture"), i + 1 < args.count,
          let data = FileManager.default.contents(atPath: args[i + 1]) else { return nil }
    return try? JSONValue.parse(data)
}

func runModelBridgeTargets(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args),
          let tree = fx.at(path: "tree"),
          let topo = fx.at(path: "topology") else {
        FileHandle.standardError.write(Data("usage: leylined model bridge-targets --fixture <file with .tree/.topology>\n".utf8))
        return 64
    }
    let bridge = Arrangement.bridgeArrangement(tree: tree, topo: topo)
    print(Arrangement.arrangementTargets(bridge: bridge, topo: topo).canonical())
    return 0
}

func runModelPrune(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args),
          let store = fx.at(path: "store"),
          let topo = fx.at(path: "topology") else {
        FileHandle.standardError.write(Data("usage: leylined model prune --fixture <file with .store/.goners/.topology[/.policy/.focused]>\n".utf8))
        return 64
    }
    let goners = (fx.at(path: "goners")?.arrayValue ?? []).compactMap(\.intValue)
    let result = Arrangement.bridgeArrangementNativePrune(
        store: store,
        goners: goners,
        focused: fx.at(path: "focused") ?? .null,
        topo: topo,
        policy: fx.at(path: "policy")?.stringValue
    )
    print(result.canonical())
    return 0
}

func runModelAdopt(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args),
          let store = fx.at(path: "store"),
          let topo = fx.at(path: "topology"),
          let ndid = fx.at(path: "ndid")?.intValue else {
        FileHandle.standardError.write(Data("usage: leylined model adopt --fixture <file with .store/.newcomers/.ndid/.topology[/.focused/.insertion_policy]>\n".utf8))
        return 64
    }
    let newcomers = (fx.at(path: "newcomers")?.arrayValue ?? []).compactMap(\.intValue)
    if let policy = fx.at(path: "insertion_policy"),
       policy.stringValue == nil || (policy.stringValue == "largest_first"
           && newcomers.count != (fx.at(path: "newcomers")?.arrayValue ?? []).count) {
        print("null")
        return 0
    }
    var newcomerMinimums: [Int64: JSONValue] = [:]
    if let minimums = fx.at(path: "newcomer_minimums") {
        guard let values = minimums.objectValue else { print("null"); return 0 }
        for (key, value) in values {
            guard let id = Int64(key), id > 0, String(id) == key,
                  Minsize.validStore(.object(["fixture": value])) else { print("null"); return 0 }
            newcomerMinimums[id] = value
        }
    }
    let result = Arrangement.bridgeArrangementNativeAdopt(
        store: store, newcomers: newcomers, ndid: ndid,
        focused: fx.at(path: "focused") ?? .null, topo: topo,
        insertionPolicy: fx.at(path: "insertion_policy")?.stringValue ?? "focus_chain",
        newcomerMinimums: newcomerMinimums.filter { newcomers.contains($0.key) }
    )
    print(result.canonical())
    return 0
}

func runModelSettle(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args), let topo = fx.at(path: "topology") else {
        FileHandle.standardError.write(Data("usage: leylined model settle --fixture <file with .t/.obs/.topology/…> [--emit targets|full]\n".utf8))
        return 64
    }
    var emit = "full"
    if let i = args.firstIndex(of: "--emit"), i + 1 < args.count { emit = args[i + 1] }
    let pol = fx.at(path: "policies")?.objectValue ?? [:]
    let policies = ArrangementStrategy.Policies(
        reclaim: pol["reclaim"]?.stringValue,
        nativePrune: pol["native_prune"]?.boolValue ?? true,
        nativeAdopt: pol["native_adopt"]?.boolValue ?? true,
        nativePromote: pol["native_promote"]?.boolValue ?? true
    )
    let r = ArrangementStrategy.settle(
        t: fx.at(path: "t") ?? .object([:]),
        obs: fx.at(path: "obs")?.arrayValue ?? fx.at(path: "observed")?.arrayValue ?? [],
        topo: topo,
        rules: fx.at(path: "rules") ?? .object(["rules": .array([])]),
        foc: fx.at(path: "foc") ?? fx.at(path: "focused") ?? .string(""),
        config: fx.at(path: "config") ?? .object([:]),
        minstore: fx.at(path: "minstore") ?? .object([:]),
        policies: policies
    )
    if emit == "targets" {
        print(Arrangement.arrangementTargets(bridge: r.arrangement, topo: topo).canonical())
    } else {
        print(JSONValue.object(["arrangement": r.arrangement, "facts": .array(r.facts)]).canonical())
    }
    return 0
}

func runModelStoreValid(_ args: [String]) -> Int32 {
    var path = ""
    if let i = args.firstIndex(of: "--path"), i + 1 < args.count { path = args[i + 1] }
    guard let fx = loadFixture(args), let store = fx.at(path: path) else {
        FileHandle.standardError.write(Data("usage: leylined model storevalid --fixture <file> [--path <dot.path>]\n".utf8))
        return 64
    }
    print(Arrangement.storeValid(store: store).canonical())
    return 0
}

func runModelFn(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args), let fn = fx.at(path: "fn")?.stringValue else {
        FileHandle.standardError.write(Data("usage: leylined model fn --fixture <fixture with .fn>\n".utf8))
        return 64
    }
    let topo = fx.at(path: "topology") ?? .object([:])
    let tree = fx.at(path: "tree") ?? .object([:])
    let arr = fx.at(path: "arr") ?? .array([])
    let segsFromArr = { (Arrangement.parseSegs(arr.arrayValue != nil ? arr : arr.at(path: "segments"))) }
    let T = { Project.normTopology(topo) }

    let out: JSONValue
    switch fn {
    case "cells":
        guard let cv = Frame.from(fx.at(path: "canvas")) else { return 65 }
        out = .array(Arrangement.cells(segsFromArr(), cv).map { $0.json() })
    case "valid":
        guard let cv = Frame.from(fx.at(path: "canvas")) else { return 65 }
        out = Arrangement.valid(segsFromArr(), cv)
    case "incident":
        guard let cv = Frame.from(fx.at(path: "canvas")),
              let line = fx.at(path: "line").flatMap(Seg.init) else { return 65 }
        out = .array(Arrangement.incident(segsFromArr(), cv, line).map { $0.json() })
    case "from_floorplan":
        out = .array(Arrangement.fromFloorplan(tree: tree, topo: topo).map(\.json))
    case "equiv":
        out = Arrangement.equiv(tree: tree, topo: topo)
    case "canvas":
        out = .array(Arrangement.canvasList(T()).map { bag in
            .object(["display_id": bag.displayId.map { JSONValue.int($0) } ?? .null,
                     "rect": bag.rect?.json ?? .null])
        })
    case "bags":
        let r = Arrangement.bagsWithRejected(segsFromArr(), T())
        out = .object([
            "bags": .array(r.bags.map { bag in
                .object(["display_id": bag.displayId.map { JSONValue.int($0) } ?? .null,
                         "segments": .array(bag.segments.map(\.json)),
                         "rect": bag.rect?.json ?? .null])
            }),
            "rejected": .array(r.rejected.map(\.json)),
        ])
    case "cells_md":
        out = .array(Arrangement.cellsMd(segsFromArr(), T()).map { $0.json() })
    case "valid_md":
        out = Arrangement.validMd(segsFromArr(), T())
    case "bridge":
        out = Arrangement.bridgeMdEquiv(tree: tree, topo: topo)
    case "cells_stack":
        out = Arrangement.cellsStack(tree: tree, topo: topo)
    case "valid_stack":
        out = Arrangement.validStack(tree: tree, topo: topo)
    case "targets_stack":
        let bridge = Arrangement.bridgeArrangement(tree: tree, topo: topo)
        out = Arrangement.arrangementTargets(bridge: bridge, topo: topo)
    case "targets_stack_eq":
        let bridge = Arrangement.bridgeArrangement(tree: tree, topo: topo)
        let at = Arrangement.arrangementTargets(bridge: bridge, topo: topo)
        let entries = at.objectValue ?? [:]
        let presented = entries.values.filter { $0.objectValue?["presented"]?.boolValue == true }.count
        let recon = Project.reconcileTargets(tree: tree, topo: topo)
        out = .object([
            "targets": at,
            "presented_count": .int(Int64(presented)),
            "hidden_count": .int(Int64(entries.count - presented)),
            "eq_reconcile": .bool(JQOrder.equal(at, recon)),
        ])
    case "contents_1stack":
        let br = Arrangement.bridgeArrangement(tree: tree, topo: topo)
        let at = Arrangement.arrangementTargets(bridge: br, topo: topo)
        let bindings = br.at(path: "bindings")?.objectValue ?? [:]
        let all1 = !bindings.isEmpty && bindings.values.allSatisfy {
            ($0.objectValue?["contents"]?.arrayValue)?.count == 1
        }
        let c0eq = bindings.values.allSatisfy { v in
            guard var bare = v.objectValue, let c0 = bare["contents"]?.arrayValue?.first else { return false }
            bare.removeValue(forKey: "contents")
            return JQOrder.equal(c0, .object(bare))
        }
        out = .object([
            "eq_reconcile": .bool(JQOrder.equal(at, Project.reconcileTargets(tree: tree, topo: topo))),
            "all_1deep": .bool(all1),
            "contents0_eq_bare": .bool(c0eq),
            "targets": at,
        ])
    case "targets_contents":
        guard let bridge = fx.at(path: "bridge") else { return 65 }
        let at = Arrangement.arrangementTargetsRec(bridge: bridge, topo: topo)
        out = .object([
            "targets": at,
            "eq_reconcile": .bool(JQOrder.equal(at, Project.reconcileTargets(tree: tree, topo: topo))),
            "eq_depth0": .bool(JQOrder.equal(at, Arrangement.arrangementTargets(bridge: bridge, topo: topo))),
        ])
    case "cells_rec":
        out = Arrangement.cellsRec(arr: arr, topo: topo)
    case "cells_rec_flat_eq":
        let rec = Arrangement.cellsRec(arr: arr, topo: topo)
        let md = JSONValue.array(Arrangement.cellsMd(Arrangement.parseSegs(arr.at(path: "segments")), T()).map { $0.json() })
        out = .object(["eq": .bool(JQOrder.equal(rec, md))])
    case "cells_rec_derived":
        let derived = Arrangement.deriveNested(arr: arr, topo: topo)
        out = Arrangement.cellsRec(arr: derived, topo: topo)
    case "derive_nested_flat_eq":
        let derived = Arrangement.deriveNested(arr: arr, topo: topo)
        let recOfDerived = Arrangement.cellsRec(arr: derived, topo: topo)
        let md = JSONValue.array(Arrangement.cellsMd(Arrangement.parseSegs(arr.at(path: "segments")), T()).map { $0.json() })
        out = .object([
            "eq": .bool(JQOrder.equal(derived, arr)),
            "cells_eq": .bool(JQOrder.equal(recOfDerived, md)),
        ])
    case "targets_rec_derived_twice":
        let d = Arrangement.deriveNested(arr: arr, topo: topo)
        let once = Arrangement.arrangementTargetsRec(bridge: d, topo: topo)
        let twice = Arrangement.arrangementTargetsRec(bridge: d, topo: topo)
        out = .object(["once": once, "twice_eq": .bool(JQOrder.equal(once, twice))])
    case "anchor_path_depth2":
        guard let D = topo.at(path: "displays")?.arrayValue?.first?.objectValue?["id"]?.intValue,
              let cellFx = fx.at(path: "cell") else { return 65 }
        let cs = Arrangement.cellsRec(arr: arr, topo: topo).arrayValue ?? []
        let nested = cs.compactMap { c -> (key: String, i0: Int64, j0: Int64)? in
            let o = c.objectValue ?? [:]
            guard let p = o["path"]?.arrayValue, !p.isEmpty,
                  let i0 = o["i0"]?.intValue, let j0 = o["j0"]?.intValue else { return nil }
            let rungs = p.compactMap(\.arrayValue) + [[.int(i0), .int(j0)]]
            var key = "\(D):\(rungs[0][0].intValue ?? 0):\(rungs[0][1].intValue ?? 0)"
            for r in rungs.dropFirst() {
                key += "@\(r[0].intValue ?? 0):\(r[1].intValue ?? 0)"
            }
            return (key, i0, j0)
        }
        let keys = nested.map(\.key)
        let collide = nested.filter { $0.i0 == 1 && $0.j0 == 0 }.map(\.key)
        out = .object([
            "keys": .array(keys.map { .string($0) }),
            "distinct": .bool(Set(keys).count == keys.count),
            "collide_pair_distinct": .bool(collide.count == 2 && collide[0] != collide[1]),
            "depth0_eq": .bool(Arrangement.anchorKeyPublic(cellFx)
                == "\(cellFx.objectValue?["display_id"]?.intValue ?? 0):\(cellFx.objectValue?["i0"]?.intValue ?? 0):\(cellFx.objectValue?["j0"]?.intValue ?? 0)"),
        ])
    case "author", "author_facts":
        let s = Autotile.sync(tree: tree, observed: fx.at(path: "observed")?.arrayValue ?? [],
                              rules: fx.at(path: "rules") ?? .array([]),
                              focusedLeaf: fx.at(path: "focused_leaf")?.stringValue,
                              topology: topo, config: fx.at(path: "config") ?? .object([:]))
        if fn == "author_facts" {
            out = .array(s.facts)
        } else {
            let bridge = Arrangement.bridgeArrangement(tree: s.tree, topo: topo)
            out = Arrangement.arrangementTargets(bridge: bridge, topo: topo)
        }
    case "author_valved":
        let cfgV = fx.at(path: "config").flatMap { $0.objectValue != nil ? $0 : nil } ?? .object([:])
        let valveOn = cfgV.objectValue?["stack_vs_shrink_threshold"] != nil
        let s = Autotile.sync(tree: tree, observed: fx.at(path: "observed")?.arrayValue ?? [],
                              rules: fx.at(path: "rules") ?? .array([]),
                              focusedLeaf: fx.at(path: "focused_leaf")?.stringValue,
                              topology: topo, config: cfgV)
        let v = valveOn
            ? Balance.valveLive(synced: s.tree, obs: fx.at(path: "observed")?.arrayValue ?? [],
                                minstore: fx.at(path: "minstore") ?? .object([:]),
                                topo: topo, foc: fx.at(path: "focused") ?? .null, config: cfgV)
            : (tree: s.tree, facts: [])
        let at = Arrangement.arrangementTargets(
            bridge: Arrangement.bridgeArrangement(tree: v.tree, topo: topo), topo: topo)
        let entries = at.objectValue ?? [:]
        let presented = entries.filter { $0.value.objectValue?["presented"]?.boolValue == true }.map(\.key).sorted()
        let stacked = entries.filter { $0.value.objectValue?["presented"]?.boolValue != true }.map(\.key).sorted()
        out = .object([
            "targets": at,
            "presented": .array(presented.map { .string($0) }),
            "stacked": .array(stacked.map { .string($0) }),
            "facts": .array((s.facts + v.facts).map { $0.objectValue?["kind"] ?? .null }),
        ])
    case "valve":
        out = Arrangement.valveLens(tree: tree, topo: topo,
                                    foc: fx.at(path: "focused_leaf") ?? .null,
                                    config: fx.at(path: "config") ?? .object([:]))
    case "valve_noop":
        let v = Arrangement.valveLens(tree: tree, topo: topo,
                                      foc: fx.at(path: "focused_leaf") ?? .null,
                                      config: fx.at(path: "config") ?? .object([:]))
        out = .object([
            "arrangement": v.at(path: "arrangement") ?? .array([]),
            "facts": v.at(path: "facts") ?? .array([]),
            "eq_unvalved": .bool(JQOrder.equal(v.at(path: "arrangement") ?? .null,
                                               Arrangement.cellsStack(tree: tree, topo: topo))),
        ])
    case "valve_idempotent":
        let foc = fx.at(path: "focused_leaf") ?? .null
        let cfg = fx.at(path: "config") ?? .object([:])
        let once = Arrangement.valveLens(tree: tree, topo: topo, foc: foc, config: cfg)
        let folded = Balance.valve(tree: tree, topo: topo, foc: foc, config: cfg).tree
        let twice = Arrangement.valveLens(tree: folded, topo: topo, foc: foc, config: cfg)
        out = .object([
            "arrangement": once.at(path: "arrangement") ?? .array([]),
            "facts": once.at(path: "facts") ?? .array([]),
            "twice_eq_once": .bool(JQOrder.equal(twice.at(path: "arrangement") ?? .null,
                                                 once.at(path: "arrangement") ?? .null)),
        ])
    case "valve_matches_tree":
        let foc = fx.at(path: "focused_leaf") ?? .null
        let cfg = fx.at(path: "config") ?? .object([:])
        let av = Arrangement.valveLens(tree: tree, topo: topo, foc: foc, config: cfg)
        let arrStacks = (av.at(path: "arrangement")?.arrayValue ?? [])
            .compactMap { c -> JSONValue? in
                guard let s = c.objectValue?["stack"], s != .null, let so = s.objectValue else { return nil }
                return .object(["members": so["members"] ?? .array([]),
                                "top": so["top"] ?? .null, "source": so["source"] ?? .null])
            }
            .sortedStableBy { $0.objectValue?["top"] ?? .null }
        let foldedTree = Balance.valve(tree: tree, topo: topo, foc: foc, config: cfg).tree
        let treeStacks = Floorplan.stacks(tree: foldedTree)
            .map { s -> JSONValue in
                .object(["members": .array(s.members.map { .string($0) }),
                         "top": s.top.map { .string($0) } ?? .null, "source": s.source])
            }
            .sortedStableBy { $0.objectValue?["top"] ?? .null }
        out = .object([
            "arr_stacks": .array(arrStacks),
            "tree_stacks": .array(treeStacks),
            "equal": .bool(JQOrder.equal(.array(arrStacks), .array(treeStacks))),
        ])
    case "conservation":
        out = Arrangement.conservationLens(tree: tree, topo: topo,
                                           foc: fx.at(path: "focused_leaf") ?? .null,
                                           config: fx.at(path: "config") ?? .object([:]))
    case "carryable":
        let a = fx.at(path: "arr") ?? .object([:])
        out = .object([
            "carried": Arrangement.carryableWindows(a, topo: topo),
            "flat": .bool(Arrangement.isFlat(a)),
        ])
    default:
        return fnUnwired(fn)
    }
    print(out.canonical())
    return 0
}
