// self-test fsm — byte-agreement with the frozen mode-FSM oracle for move and
// resize: the row set derived from keymap/modes.json must equal
// leylined/Fixtures/mode_fsm/<mode>.frozen.json keyed on (chord, is_enter) →
// exit_predicate | transition:default (verb strings are historical payload,
// not compared). Plus the predicate evaluator truth table incl. the rc4
// universal guard.
import Foundation
import LeylineModel

private func resolveFsmPaths(_ args: [String]) -> (modes: String, fixtureDir: String)? {
    var modes: String?
    var fixtureDir: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--modes" where i + 1 < args.count:
            modes = args[i + 1]
            i += 2
        case "--fixture-dir" where i + 1 < args.count:
            fixtureDir = args[i + 1]
            i += 2
        default:
            i += 1
        }
    }
    let env = ProcessInfo.processInfo.environment, home = SelfTestFixtures.repositoryRoot(arguments: args)
    if modes == nil, let p = env["LEYLINE_KEYMAP_MODES"] { modes = p }
    if modes == nil { modes = home + "/keymap/modes.json" }
    if fixtureDir == nil { fixtureDir = SelfTestFixtures.path("mode_fsm", root: home) }
    guard let m = modes, let f = fixtureDir else { return nil }
    return (m, f)
}

private func loadFrozenRows(_ path: String) -> [String: String]? {
    guard let data = FileManager.default.contents(atPath: path),
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return nil
    }
    var out: [String: String] = [:]
    for row in rows {
        guard let chord = row["chord"] as? String else { return nil }
        let isEnter = row["is_enter"] as? Bool ?? false
        let key = "\(chord)\u{1F}\(isEnter ? "1" : "0")"
        if let transition = row["transition"] as? String {
            out[key] = "transition:\(transition)"
        } else if let predicate = row["exit_predicate"] as? String {
            out[key] = "predicate:\(predicate)"
        } else {
            return nil
        }
    }
    return out
}

private func describeRowKey(_ key: String) -> String {
    let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
    let chord = parts.first ?? key
    let isEnter = parts.count > 1 && parts[1] == "1"
    return isEnter ? "\(chord) (enter)" : chord
}

func runFsmSelfTest(_ args: [String]) -> Int32 {
    var t = SelfTest()

    guard let paths = resolveFsmPaths(args) else {
        t.check(false, "fsm/paths: pass --modes/--fixture-dir or set LEYLINE_KEYMAP_MODES/LEYLINE_HOME")
        return t.finish("fsm")
    }
    guard let manifestData = FileManager.default.contents(atPath: paths.modes) else {
        t.check(false, "fsm/modes-read: \(paths.modes)")
        return t.finish("fsm")
    }
    let fsm: ModeFSM
    do {
        fsm = try ModeFSM(manifestData: manifestData)
    } catch {
        t.check(false, "fsm/modes-parse: \(error)")
        return t.finish("fsm")
    }

    // Frozen-oracle agreement for the ported modes.
    for mode in ["move", "resize"] {
        let fixturePath = paths.fixtureDir + "/\(mode).frozen.json"
        guard var frozen = loadFrozenRows(fixturePath), !frozen.isEmpty else {
            t.check(false, "fsm/\(mode)-frozen-oracle-readable (\(fixturePath))")
            continue
        }
        guard let derived = fsm.frozenRows(mode: mode) else {
            t.check(false, "fsm/\(mode)-present-in-modes-manifest")
            continue
        }
        if mode == "move" {
            let retiredTopKey = "t\u{1F}0"
            t.check(frozen.removeValue(forKey: retiredTopKey) != nil && derived[retiredTopKey] == nil,
                "fsm/v1-removes-unimplemented-top-route-from-current-manifest")
        }
        let missing = frozen.keys.filter { derived[$0] == nil }.sorted()
        let extra = derived.keys.filter { frozen[$0] == nil }.sorted()
        let mismatched = frozen.keys.filter { derived[$0] != nil && derived[$0] != frozen[$0] }.sorted()
        t.check(missing.isEmpty && extra.isEmpty && mismatched.isEmpty,
                "fsm/\(mode)-frozen-agreement (\(frozen.count) rows)")
        for k in missing { print("    missing from modes.json: \(describeRowKey(k)) → \(frozen[k] ?? "?")") }
        for k in extra { print("    not in frozen oracle: \(describeRowKey(k)) → \(derived[k] ?? "?")") }
        for k in mismatched { print("    predicate drift at \(describeRowKey(k)): frozen \(frozen[k] ?? "?") vs modes \(derived[k] ?? "?")") }
    }

    t.check(Set(fsm.modes.keys) == ["move", "resize"], "fsm/v1-has-only-move-and-resize-modes")

    // The predicate evaluator truth table (decisive rcs per predicate).
    t.check(ExitPredicate.exitOnRc0.exits(rc: 0) == true
                && ExitPredicate.exitOnRc0.exits(rc: 1) == false
                && ExitPredicate.exitOnRc0.exits(rc: 3) == false,
            "fsm/predicate-exit_on_rc0")
    t.check(ExitPredicate.exitUnlessRcIn1Or3.exits(rc: 1) == false
                && ExitPredicate.exitUnlessRcIn1Or3.exits(rc: 3) == false
                && ExitPredicate.exitUnlessRcIn1Or3.exits(rc: 0) == true
                && ExitPredicate.exitUnlessRcIn1Or3.exits(rc: 2) == true,
            "fsm/predicate-exit_unless_rc_in_1_3")
    t.check(ExitPredicate.exitOnAnyNonzero.exits(rc: 0) == false
                && ExitPredicate.exitOnAnyNonzero.exits(rc: 1) == true,
            "fsm/predicate-exit_on_any_nonzero")
    t.check(ExitPredicate.unconditionalExit.exits(rc: 0)
                && ExitPredicate.unconditionalExit.exits(rc: 7),
            "fsm/predicate-unconditional_exit")
    t.check(ExitPredicate.noExit.exits(rc: 0) == false
                && ExitPredicate.noExit.exits(rc: 1) == false,
            "fsm/predicate-no_exit")

    // The rc4 universal guard: force-exit to default for EVERY predicate,
    // evaluated before on_done — observable where the bare predicate would
    // stay (exit_on_rc0 with rc4, no_exit with rc4).
    let rc4Holds = ExitPredicate.allCases.allSatisfy { p in
        let s = ModeFSM.step(mode: "move", predicate: p, rc: ModeFSM.staleRc)
        return s.nextMode == "default" && s.exit
    }
    t.check(rc4Holds, "fsm/rc4-force-exit-precedes-on_done (all \(ExitPredicate.allCases.count) predicates)")

    // Step semantics: stay keeps the mode, exit lands in default.
    let stay = ModeFSM.step(mode: "resize", predicate: .noExit, rc: 0)
    let exit = ModeFSM.step(mode: "move", predicate: .exitOnRc0, rc: 0)
    t.check(stay.nextMode == "resize" && !stay.exit && exit.nextMode == "default" && exit.exit,
            "fsm/step-stay-keeps-mode-exit-lands-default")

    return t.finish("fsm")
}
