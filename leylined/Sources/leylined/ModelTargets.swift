// leylined model targets — the step-3 harness verb: tree fixture in
// ({tree, topology, …}), the window-keyed target map out (the
// R::reconcile_targets contract the differential harness compares).
import Foundation
import LeylineModel

func runModelTargets(_ args: [String]) -> Int32 {
    var fixturePath: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--fixture" where i + 1 < args.count:
            fixturePath = args[i + 1]
            i += 2
        default:
            FileHandle.standardError.write(Data("leylined model targets: unknown arg '\(args[i])'\n".utf8))
            return 64
        }
    }
    guard let fixturePath else {
        FileHandle.standardError.write(Data("usage: leylined model targets --fixture <file>\n".utf8))
        return 64
    }
    guard let data = FileManager.default.contents(atPath: fixturePath) else {
        FileHandle.standardError.write(Data("leylined model targets: cannot read \(fixturePath)\n".utf8))
        return 66
    }
    guard let parsed = try? JSONValue.parse(data),
          let tree = parsed.at(path: "tree"),
          let topo = parsed.at(path: "topology") else {
        FileHandle.standardError.write(Data("leylined model targets: fixture needs .tree and .topology\n".utf8))
        return 65
    }
    print(Project.reconcileTargets(tree: tree, topo: topo).canonical())
    return 0
}
