// Developer adapters that run frozen oracle fixtures through the production
// model functions: `leylined model fn` dispatches on the fixture's `.fn`, and
// `leylined model adopt` drives largest-first insertion. Unknown functions fail.
import Foundation
import LeylineModel

private func loadFixture(_ args: [String]) -> JSONValue? {
    guard let i = args.firstIndex(of: "--fixture"), i + 1 < args.count,
          let data = FileManager.default.contents(atPath: args[i + 1]) else { return nil }
    return try? JSONValue.parse(data)
}

func runModelAdopt(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args),
          let store = fx.at(path: "store"),
          let topo = fx.at(path: "topology"),
          let ndid = fx.at(path: "ndid")?.intValue else {
        FileHandle.standardError.write(Data("usage: leylined model adopt --fixture <file with .store/.newcomers/.ndid/.topology[/.focused/.newcomer_minimums]>\n".utf8))
        return 64
    }
    let raw = fx.at(path: "newcomers")?.arrayValue ?? []
    let newcomers = raw.compactMap(\.intValue)
    guard newcomers.count == raw.count else { print("null"); return 0 }
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
        newcomerMinimums: newcomerMinimums.filter { newcomers.contains($0.key) }
    )
    print(result.canonical())
    return 0
}

func runModelFn(_ args: [String]) -> Int32 {
    guard let fx = loadFixture(args), let fn = fx.at(path: "fn")?.stringValue else {
        FileHandle.standardError.write(Data("usage: leylined model fn --fixture <fixture with .fn>\n".utf8))
        return 64
    }
    let topo = fx.at(path: "topology") ?? .object([:])
    let arr = fx.at(path: "arr") ?? fx.at(path: "arrangement") ?? .array([])
    let segs = Arrangement.parseSegs(arr.arrayValue != nil ? arr : arr.at(path: "segments"))
    let T = { Project.normTopology(topo) }

    let out: JSONValue
    switch fn {
    case "cells":
        guard let cv = Frame.from(fx.at(path: "canvas")) else { return 65 }
        out = .array(Arrangement.cells(segs, cv).map { $0.json() })
    case "valid":
        guard let cv = Frame.from(fx.at(path: "canvas")) else { return 65 }
        out = Arrangement.valid(segs, cv)
    case "canvas":
        out = .array(Arrangement.canvasList(T()).map { bag in
            .object(["display_id": bag.displayId.map { JSONValue.int($0) } ?? .null,
                     "rect": bag.rect?.json ?? .null])
        })
    case "bags":
        let r = Arrangement.bagsWithRejected(segs, T())
        out = .object([
            "bags": .array(r.bags.map { bag in
                .object(["display_id": bag.displayId.map { JSONValue.int($0) } ?? .null,
                         "segments": .array(bag.segments.map(\.json)),
                         "rect": bag.rect?.json ?? .null])
            }),
            "rejected": .array(r.rejected.map(\.json)),
        ])
    case "cells_md":
        out = .array(Arrangement.cellsMd(segs, T()).map { $0.json() })
    case "valid_md":
        out = Arrangement.validMd(segs, T())
    case "targets_rec":
        guard let bridge = fx.at(path: "bridge") else { return 65 }
        out = Arrangement.arrangementTargetsRec(bridge: bridge, topo: topo)
    case "prune":
        guard let store = fx.at(path: "store") else { return 65 }
        out = Arrangement.bridgeArrangementNativePrune(
            store: store, goners: (fx.at(path: "goners")?.arrayValue ?? []).compactMap(\.intValue), topo: topo)
    case "assign_display":
        guard let win = Frame.from(fx.at(path: "win")) else { return 65 }
        let displays = Project.normTopology(.object(["displays": fx.at(path: "displays") ?? .array([])])).displays
        out = Geometry.assignDisplay(win, displays).map(JSONValue.int) ?? .null
    case "learn":
        out = Minsize.learnMinSizes(targets: fx.at(path: "targets") ?? .object([:]),
                                    observed: fx.at(path: "observed")?.arrayValue ?? [],
                                    store: fx.at(path: "store") ?? .object([:]), topo: fx.at(path: "topo"))
    case "tileable":
        out = .bool(Autotile.tileable(fx.at(path: "window") ?? .null))
    default:
        FileHandle.standardError.write(Data("leylined model fn: unknown function '\(fn)'\n".utf8))
        return 64
    }
    print(out.canonical())
    return 0
}
