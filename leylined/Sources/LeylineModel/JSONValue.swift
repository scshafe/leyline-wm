// Canonical JSON algebra, ordered serialization and typed field projection.
import Foundation

/// jq's object semantics: insertion-ordered keys, by-key lookup, updating an
/// existing key keeps its position, adding a new key appends. Equality is
/// order-INSENSITIVE (jq: {"a":1,"b":2} == {"b":2,"a":1}).
public struct JSONObject: Equatable, Sendable {
    public private(set) var keys: [String]
    private var map: [String: JSONValue]

    public init() {
        keys = []
        map = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        keys = []
        map = [:]
        for (k, v) in pairs { self[k] = v }
    }

    /// Interop from an unordered Dictionary: keys inserted SORTED so the
    /// result is deterministic (Swift dictionary iteration order is not).
    public init(unordered dict: [String: JSONValue]) {
        keys = dict.keys.sorted()
        map = dict
    }

    public subscript(key: String) -> JSONValue? {
        get { map[key] }
        set {
            if let newValue {
                if map[key] == nil { keys.append(key) }
                map[key] = newValue
            } else if map.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [JSONValue] { keys.map { map[$0]! } }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let old = map.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return old
    }

    /// Right-biased merge in jq `+` style: keys from `other` overwrite in
    /// place; new keys append in `other`'s order.
    public func merging(_ other: JSONObject) -> JSONObject {
        var out = self
        for (k, v) in other { out[k] = v }
        return out
    }

    public mutating func merge(_ other: JSONObject,
                               uniquingKeysWith combine: (JSONValue, JSONValue) -> JSONValue) {
        for (k, v) in other {
            if let old = self[k] {
                self[k] = combine(old, v)
            } else {
                self[k] = v
            }
        }
    }

    /// The entries `isIncluded` keeps, in their original insertion order.
    public func filter(_ isIncluded: ((key: String, value: JSONValue)) -> Bool) -> JSONObject {
        var result = JSONObject()
        for entry in self where isIncluded(entry) { result[entry.key] = entry.value }
        return result
    }

    public func mapValues(_ transform: (JSONValue) -> JSONValue) -> JSONObject {
        var out = JSONObject()
        for k in keys { out[k] = transform(map[k]!) }
        return out
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.map == b.map }
}

extension JSONObject: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = 0
        let keys = self.keys
        let map = self.map
        return AnyIterator {
            guard i < keys.count else { return nil }
            let k = keys[i]
            i += 1
            return (k, map[k]!)
        }
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Integral doubles emit as JSON integers, matching jq number output.
    static func number(_ d: Double) -> JSONValue {
        if d == d.rounded(), abs(d) < 9_007_199_254_740_992 {
            return .int(Int64(d))
        }
        return .double(d)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    /// Compact emission in jq -c style: object keys in INSERTION order, ints
    /// without a decimal point. Comparisons across engines still pipe through
    /// `jq -S -c` on both sides; emitting insertion order (not sorted) keeps
    /// captured stores byte-faithful to what the live jq stack read and wrote.
    public func canonical() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992, d.isFinite {
                return String(Int64(d))
            }
            return String(d)
        case .string(let s):
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            let arr = String(decoding: data, as: UTF8.self)
            return String(arr.dropFirst().dropLast())
        case .array(let a):
            return "[" + a.map { $0.canonical() }.joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.map { key in
                JSONValue.string(key).canonical() + ":" + (o[key] ?? .null).canonical()
            }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    // -- Typed accessors (nil on shape mismatch — validators decide severity).

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int64(d)
        default: return nil
        }
    }

    public var numberValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Dot-path lookup ("arr", "prior", "a.b"); empty path = self.
    public func at(path: String) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var cur = self
        for part in path.split(separator: ".") {
            guard let o = cur.objectValue, let next = o[String(part)] else { return nil }
            cur = next
        }
        return cur
    }
}

// ── Order-preserving parser ──────────────────────────────────────────────────
// JSONSerialization returns unordered NSDictionary, destroying the key order
// jq semantics depend on. This recursive-descent parser keeps insertion order
// and decides int-vs-double lexically (no '.'/'e' and fits Int64 → .int).

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let message: String
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let v = try parseValue()
        skipWhitespace()
        guard i == bytes.count else {
            throw JSONParseError(offset: i, message: "trailing content after value")
        }
        return v
    }

    mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else {
            throw JSONParseError(offset: i, message: "unexpected end of input")
        }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expectLiteral(_ lit: String) throws {
        for b in lit.utf8 {
            guard i < bytes.count, bytes[i] == b else {
                throw JSONParseError(offset: i, message: "invalid literal (expected \(lit))")
            }
            i += 1
        }
    }

    mutating func parseObject() throws -> JSONValue {
        i += 1  // {
        var obj = JSONObject()
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return .object(obj)
        }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                throw JSONParseError(offset: i, message: "expected object key")
            }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                throw JSONParseError(offset: i, message: "expected ':' after key")
            }
            i += 1
            skipWhitespace()
            obj[key] = try parseValue()
            skipWhitespace()
            guard i < bytes.count else {
                throw JSONParseError(offset: i, message: "unterminated object")
            }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(obj)
            }
            throw JSONParseError(offset: i, message: "expected ',' or '}' in object")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        i += 1  // [
        var arr: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return .array(arr)
        }
        while true {
            skipWhitespace()
            arr.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else {
                throw JSONParseError(offset: i, message: "unterminated array")
            }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(arr)
            }
            throw JSONParseError(offset: i, message: "expected ',' or ']' in array")
        }
    }

    mutating func parseString() throws -> String {
        i += 1  // opening quote
        var out: [UInt8] = []
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { break }
                switch bytes[i] {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 1
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 1
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 1
                case UInt8(ascii: "b"): out.append(0x08); i += 1
                case UInt8(ascii: "f"): out.append(0x0C); i += 1
                case UInt8(ascii: "n"): out.append(0x0A); i += 1
                case UInt8(ascii: "r"): out.append(0x0D); i += 1
                case UInt8(ascii: "t"): out.append(0x09); i += 1
                case UInt8(ascii: "u"):
                    i += 1
                    var unit = try parseHex4()
                    // Surrogate pair: a high surrogate followed by \uDC00-\uDFFF.
                    if (0xD800...0xDBFF).contains(unit), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    if let scalar = Unicode.Scalar(unit) {
                        out.append(contentsOf: Array(String(scalar).utf8))
                    } else {
                        out.append(contentsOf: [0xEF, 0xBF, 0xBD])  // U+FFFD
                    }
                default:
                    throw JSONParseError(offset: i, message: "invalid escape")
                }
                continue
            }
            out.append(b)
            i += 1
        }
        throw JSONParseError(offset: i, message: "unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard i < bytes.count else {
                throw JSONParseError(offset: i, message: "truncated \\u escape")
            }
            let b = bytes[i]
            let d: UInt32
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(b - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(b - UInt8(ascii: "A")) + 10
            default: throw JSONParseError(offset: i, message: "invalid hex digit in \\u escape")
            }
            v = (v << 4) | d
            i += 1
        }
        return v
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        var sawDigit = false
        while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) {
            i += 1
            sawDigit = true
        }
        var isDouble = false
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            isDouble = true
            i += 1
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isDouble = true
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
        }
        guard sawDigit else {
            throw JSONParseError(offset: start, message: "invalid number")
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isDouble, let n = Int64(text) {
            return .int(n)
        }
        guard let d = Double(text) else {
            throw JSONParseError(offset: start, message: "unparseable number \(text)")
        }
        return .double(d)
    }
}
