// Fixed US keyboard decoding: virtual keycode plus modifier flags becomes the
// chord grammar used by immutable keymap resources. No live layout source is read.
import Foundation

public enum DecodeFixtureError: Error, Sendable {
    case malformed
}

public struct KeyDecode: Sendable {
    /// Pure modifier flags — deliberately NOT CGEventFlags (the pure model never
    /// imports CoreGraphics). The daemon boundary maps CGEventFlags → Flags.
    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let cmd = Flags(rawValue: 1 << 0)
        public static let ctrl = Flags(rawValue: 1 << 1)
        public static let alt = Flags(rawValue: 1 << 2)
        public static let shift = Flags(rawValue: 1 << 3)
        public static let fn = Flags(rawValue: 1 << 4)
    }

    public let table: [Int: String]
    /// Rows the loader refused (invalid token grammar) — callers report these
    /// loudly; they are never silently honored (INV-FSM-2). A non-integer
    /// keyCode key is omitted from the fixed keycode table.
    public let droppedRows: [(keyCode: Int, token: String)]

    /// The base-key token grammar for manifest chords:
    /// `0x` + one-or-more hex digits, or all lowercase-letters/digits.
    public static func isKeyToken(_ key: String) -> Bool {
        if key.isEmpty { return false }
        if key.hasPrefix("0x") {
            let hex = key.dropFirst(2)
            return !hex.isEmpty && hex.allSatisfy { $0.isHexDigit }
        }
        return key.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber }
    }

    /// Load from the frozen fixture bytes (top-level `keycode_to_token` map).
    /// Throws on missing/malformed structure; grammar-invalid rows land in
    /// `droppedRows`.
    public init(fixtureData: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let m = obj["keycode_to_token"] as? [String: String] else {
            throw DecodeFixtureError.malformed
        }
        var table: [Int: String] = [:]
        var dropped: [(keyCode: Int, token: String)] = []
        for (k, v) in m {
            guard let kc = Int(k) else { continue }
            if KeyDecode.isKeyToken(v) {
                table[kc] = v
            } else {
                dropped.append((keyCode: kc, token: v))
            }
        }
        self.table = table
        self.droppedRows = dropped
    }

    /// Pure decode: nil when the keyCode is absent from the table — which
    /// includes every pure-modifier keyCode, so a bare modifier can never
    /// produce a suppressable token (K1.1). Modifiers are emitted in the
    /// load-bearing canonical order `cmd + ctrl + alt + shift + fn`; a bare
    /// keystroke decodes to just the key token (no " - " separator).
    public func chord(keyCode: Int, flags: Flags) -> String? {
        guard let key = table[keyCode] else { return nil }
        var mods: [String] = []
        if flags.contains(.cmd) { mods.append("cmd") }
        if flags.contains(.ctrl) { mods.append("ctrl") }
        if flags.contains(.alt) { mods.append("alt") }
        if flags.contains(.shift) { mods.append("shift") }
        if flags.contains(.fn) { mods.append("fn") }
        return mods.isEmpty ? key : (mods.joined(separator: " + ") + " - " + key)
    }
}
