// self-test decode — the shipped US decode table against Apple's fixed virtual
// keycodes (HIToolbox kVK_* constants, independent of this repository), the
// loader's row policy, chord spelling and exact coverage of the shipped keymaps.
// Resource home: --home arg, else LEYLINE_HOME — no silent cwd-relative guess.
import Foundation
import LeylineModel

// The six pure-modifier virtual keyCodes (cmd/shift/capslock/alt/ctrl/fn). Their
// ABSENCE from the table is the K1.1 guarantee: a bare modifier decodes to nil.
private let pureModifierKeyCodes = [0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3F]

// kVK_ANSI_* / kVK_* values for every key the shipped keymaps bind.
private let appleVirtualKeyCodes: [String: Int] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "h": 0x04, "c": 0x08, "r": 0x0F,
    "u": 0x20, "i": 0x22, "l": 0x25, "j": 0x26, "k": 0x28, "m": 0x2E,
    "0x24": 0x24, "0x35": 0x35, "0x5A": 0x5A,
]

func runDecodeSelfTest(_ args: [String]) -> Int32 {
    var t = SelfTest()
    let home = SelfTestFixtures.repositoryRoot(arguments: args)
    let path = home + "/keymap/decode-us.json"
    guard let data = FileManager.default.contents(atPath: path) else {
        t.check(false, "decode/table-read: \(path)")
        return t.finish("decode")
    }

    // Independent parse of the raw table (the reference), then the model load.
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let raw = obj["keycode_to_token"] as? [String: String] else {
        t.check(false, "decode/table-shape: no keycode_to_token map in \(path)")
        return t.finish("decode")
    }
    guard let decode = try? KeyDecode(fixtureData: data) else {
        t.check(false, "decode/model-load: KeyDecode threw on \(path)")
        return t.finish("decode")
    }

    t.check(!raw.isEmpty, "decode/table-non-empty (\(raw.count) rows)")
    t.check(decode.droppedRows.isEmpty, "decode/shipped-table-has-zero-dropped-rows")
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

    // Every row is the Apple keycode for its token.
    let wrongRows = decode.table.filter { appleVirtualKeyCodes[$0.value] != $0.key }
    t.check(wrongRows.isEmpty, "decode/rows-match-apple-virtual-keycodes")
    for (kc, tok) in wrongRows { print("    keyCode \(kc) → '\(tok)' is not the US keycode") }

    // K1.1: every pure-modifier keyCode is absent → bare modifiers decode to nil.
    let modifierLeak = pureModifierKeyCodes.filter { decode.table[$0] != nil }
    t.check(modifierLeak.isEmpty, "decode/pure-modifier-keycodes-absent (K1.1)")
    for kc in modifierLeak { print("    modifier keyCode present: \(kc)") }

    // Chord spelling: canonical modifier order + the bare/modified separator rule
    // (mode-fsm-spec §10; keyCode 4 is 'h' regardless of layout).
    t.check(decode.chord(keyCode: 4, flags: []) == "h",
            "decode/bare-key-spells-token-only")
    t.check(decode.chord(keyCode: 4, flags: [.cmd, .ctrl, .alt, .shift])
                == "cmd + ctrl + alt + shift - h",
            "decode/hyper-chord-canonical-order")
    t.check(decode.chord(keyCode: 0x00, flags: [.cmd, .ctrl, .alt, .shift])
                == "cmd + ctrl + alt + shift - a",
            "decode/hyper-a-space-toggle-decodes")
    t.check(decode.chord(keyCode: 0x5A, flags: [.fn]) == "fn - 0x5A",
            "decode/fn-modifier-spelling")
    t.check(decode.chord(keyCode: 0x37, flags: [.cmd]) == nil,
            "decode/absent-keycode-decodes-nil")

    // The shipped keymaps load (the loader refuses undecodable chords) and the
    // table holds exactly their base keys: nothing bound is missing, nothing
    // unbound remains.
    do {
        let input = try ResidentInput.load(home: home, dispatchAction: { _, complete in complete(4) },
                                           onModeChanged: { _, _, _ in true })
        let bound = Set(input.routing.configuration.routes.flatMap(\.keys).map {
            $0.components(separatedBy: " - ").last ?? $0
        })
        t.check(bound == Set(decode.table.values), "decode/table-covers-exactly-the-bound-keys")
        for token in bound.symmetricDifference(Set(decode.table.values)).sorted() { print("    coverage gap: \(token)") }
    } catch {
        t.check(false, "decode/shipped-keymaps-load: \(error)")
    }
    var undecodable = keymapRefusal(withGlobalChord: "cmd + ctrl + alt + shift - q", home: home)
    t.check(undecodable == "INPUT.KEYMAP_INVALID", "decode/undecodable-bound-chord-is-refused")
    undecodable = keymapRefusal(withGlobalChord: "cmd + ctrl + alt + shift - a", home: home)
    t.check(undecodable == nil, "decode/decodable-bound-chord-is-accepted")

    return t.finish("decode")
}

/// Loads the shipped configuration with `chord` re-bound to the Space toggle;
/// returns the refusal code, or nil when it loads.
private func keymapRefusal(withGlobalChord chord: String, home: String) -> String? {
    do {
        let decode = try KeyDecode(fixtureData: Data(contentsOf: URL(fileURLWithPath: home + "/keymap/decode-us.json")))
        let fsm = try ModeFSM(manifestData: Data(contentsOf: URL(fileURLWithPath: home + "/keymap/modes.json")))
        guard var global = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: home + "/keymap/global.json"))).objectValue,
              var bindings = global["bindings"]?.arrayValue else { return "unreadable" }
        bindings = bindings.filter { $0.at(path: "action_id")?.stringValue != "space.management.toggle" }
        bindings.append(.object(["chord": .string(chord), "action_id": .string("space.management.toggle")]))
        global["bindings"] = .array(bindings)
        _ = try ResidentInputConfiguration(decode: decode, fsm: fsm,
                                           globalData: Data(JSONValue.object(global).canonical().utf8),
                                           supportedActionIds: ResidentInput.retainedActionIds)
        return nil
    } catch let error as ResidentInputError {
        return error.code
    } catch {
        return "unexpected"
    }
}
