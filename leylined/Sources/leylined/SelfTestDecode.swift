// self-test decode — byte-level agreement with the frozen US decode fixture
// (the fixture is the shipped table, so this proves the loader's row policy and
// the chord spelling, not a parallel table). Fixture resolution: --fixture arg,
// else LEYLINE_DECODE_FIXTURE, else $LEYLINE_HOME/leylined/Fixtures/keytap/
// decode-us.frozen.json — no silent cwd-relative guess.
import Foundation
import LeylineModel

// The six pure-modifier virtual keyCodes (cmd/shift/capslock/alt/ctrl/fn). Their
// ABSENCE from the table is the K1.1 guarantee: a bare modifier decodes to nil.
private let pureModifierKeyCodes = [0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3F]

func resolveDecodeFixturePath(_ args: [String]) -> String? {
    if let i = args.firstIndex(of: "--fixture"), i + 1 < args.count {
        return args[i + 1]
    }
    let env = ProcessInfo.processInfo.environment
    if let p = env["LEYLINE_DECODE_FIXTURE"] { return p }
    if let home = env["LEYLINE_HOME"] {
        return home + "/leylined/Fixtures/keytap/decode-us.frozen.json"
    }
    return nil
}

func runDecodeSelfTest(_ args: [String]) -> Int32 {
    var t = SelfTest()

    guard let path = resolveDecodeFixturePath(args) else {
        print("not ok decode/fixture-path: pass --fixture or set LEYLINE_DECODE_FIXTURE or LEYLINE_HOME")
        return 1
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        print("not ok decode/fixture-read: \(path)")
        return 1
    }

    // Independent parse of the raw fixture (the reference), then the model load.
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let raw = obj["keycode_to_token"] as? [String: String] else {
        print("not ok decode/fixture-shape: no keycode_to_token map in \(path)")
        return 1
    }
    guard let decode = try? KeyDecode(fixtureData: data) else {
        print("not ok decode/model-load: KeyDecode threw on \(path)")
        return 1
    }

    t.check(!raw.isEmpty, "decode/fixture-non-empty (\(raw.count) rows)")
    t.check(decode.droppedRows.isEmpty,
            "decode/shipped-fixture-has-zero-dropped-rows")
    for (kc, tok) in decode.droppedRows {
        print("    dropped: keyCode \(kc) → '\(tok)'")
    }

    // Row parity, both directions: every valid raw row is in the table with the
    // same token; the table holds nothing else.
    var parity = true
    var expectedCount = 0
    for (k, v) in raw {
        guard let kc = Int(k) else { continue }
        guard KeyDecode.isKeyToken(v) else { continue }
        expectedCount += 1
        if decode.table[kc] != v { parity = false }
    }
    t.check(parity && decode.table.count == expectedCount,
            "decode/row-parity-both-directions (\(decode.table.count)/\(expectedCount))")

    // K1.1: every pure-modifier keyCode is absent → bare modifiers decode to nil.
    let modifierLeak = pureModifierKeyCodes.filter { decode.table[$0] != nil }
    t.check(modifierLeak.isEmpty, "decode/pure-modifier-keycodes-absent (K1.1)")
    for kc in modifierLeak { print("    modifier keyCode present: \(kc)") }

    // Chord spelling: canonical modifier order + the bare/modified separator rule
    // (mode-fsm-spec §10; keyCode 4 is 'h' regardless of layout, F1 is 122).
    t.check(decode.chord(keyCode: 4, flags: []) == "h",
            "decode/bare-key-spells-token-only")
    t.check(decode.chord(keyCode: 4, flags: [.cmd, .ctrl, .alt, .shift])
                == "cmd + ctrl + alt + shift - h",
            "decode/hyper-chord-canonical-order")
    t.check(decode.chord(keyCode: 122, flags: [.fn]) == "fn - f1",
            "decode/fn-row-spelling")
    t.check(decode.chord(keyCode: 0x37, flags: [.cmd]) == nil,
            "decode/absent-keycode-decodes-nil")

    return t.finish("decode")
}
