// leylined model store — the step-1 store surface: canonical dump + shape
// validation over the preserved-JSONValue store model.
import Foundation
import LeylineModel

func runModelStore(_ args: [String]) -> Int32 {
    var dumpPath: String?
    var validatePath: String?
    var subPath = ""
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--dump" where i + 1 < args.count:
            dumpPath = args[i + 1]
            i += 2
        case "--validate" where i + 1 < args.count:
            validatePath = args[i + 1]
            i += 2
        case "--path" where i + 1 < args.count:
            subPath = args[i + 1]
            i += 2
        default:
            FileHandle.standardError.write(Data("leylined model store: unknown arg '\(args[i])'\n".utf8))
            return 64
        }
    }
    guard let file = dumpPath ?? validatePath else {
        FileHandle.standardError.write(Data("usage: leylined model store (--dump|--validate) <file> [--path <dot.path>]\n".utf8))
        return 64
    }
    guard let data = FileManager.default.contents(atPath: file) else {
        FileHandle.standardError.write(Data("leylined model store: cannot read \(file)\n".utf8))
        return 66
    }
    guard let parsed = try? JSONValue.parse(data),
          let subtree = parsed.at(path: subPath),
          let store = try? ArrangementStore(root: subtree) else {
        FileHandle.standardError.write(Data("leylined model store: no store object at path '\(subPath)' in \(file)\n".utf8))
        return 65
    }
    if dumpPath != nil {
        print(store.dumpCanonical())
        return 0
    }
    let violations = store.validate()
    for v in violations { print("violation \(v)") }
    print("model store: \(violations.count) violation(s)")
    return violations.isEmpty ? 0 : 1
}

func runStoreSelfTest() -> Int32 {
    var t = SelfTest()
    guard let home = ProcessInfo.processInfo.environment["LEYLINE_HOME"] else {
        print("not ok store/paths: LEYLINE_HOME unset")
        return 1
    }
    let fm = FileManager.default
    let sweeps: [(dir: String, path: String)] = [
        (home + "/tests/oracles/fixtures/arrangement", "arr"),
        (home + "/tests/oracles/fixtures/arrangement_valid", "arrangement"),
    ]
    var specimens = 0
    var shapeViolations: [String] = []
    var unstable: [String] = []
    for sweep in sweeps {
        for f in (try? fm.contentsOfDirectory(atPath: sweep.dir))?.sorted() ?? [] where f.hasSuffix(".json") {
            let full = sweep.dir + "/" + f
            guard let data = fm.contents(atPath: full),
                  let parsed = try? JSONValue.parse(data),
                  let subtree = parsed.at(path: sweep.path),
                  subtree.objectValue != nil,
                  let store = try? ArrangementStore(root: subtree) else { continue }
            specimens += 1
            for v in store.validate() { shapeViolations.append("\(f): \(v)") }
            // Parse→print→parse→print stability (the jq cross-check in the
            // test arm is the cross-engine fidelity oracle).
            let once = store.dumpCanonical()
            if let re = try? JSONValue.parse(Data(once.utf8)), re.canonical() != once {
                unstable.append(f)
            }
        }
    }
    // 14 of the fn-corpus `arr` fields are object stores (15 are bare arrays —
    // fn inputs covered later by the fn-verb harness); arrangement_valid's
    // fields are all arrays. ≥12 keeps the sweep non-vacuous and robust.
    t.check(specimens >= 12, "store/specimen-sweep-non-vacuous (\(specimens) specimens)")
    t.check(shapeViolations.isEmpty, "store/all-specimens-shape-clean")
    for s in shapeViolations.prefix(5) { print("    \(s)") }
    t.check(unstable.isEmpty, "store/canonical-print-stable")
    for s in unstable.prefix(5) { print("    unstable: \(s)") }

    // Validator non-vacuity: planted violations must fire.
    let badContents = try? ArrangementStore(root: .object([
        "bindings": .object(["1:0:0": .object([
            "window_id": .int(7),
            "contents": .array([.object(["window_id": .int(9)])]),
        ])]),
    ]))
    t.check(badContents?.validate().contains { $0.rule.contains("contents[0]") } == true,
            "store/validator-fires-on-contents-mismatch")
    let badAxis = try? ArrangementStore(root: .object([
        "segments": .array([.object(["axis": .string("x"), "coord": .int(1), "lo": .int(0), "hi": .int(2)])]),
    ]))
    t.check(badAxis?.validate().contains { $0.rule.contains("axis") } == true,
            "store/validator-fires-on-bad-axis")

    // Number identity: ints stay ints, halves stay halves.
    t.check(JSONValue.int(8).canonical() == "8"
                && JSONValue.double(590.5).canonical() == "590.5"
                && JSONValue.double(1542).canonical() == "1542",
            "store/number-identity-int-vs-double")

    return t.finish("store")
}
