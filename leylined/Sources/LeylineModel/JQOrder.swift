// jq's total order + stable sort, for porting sort_by/unique/group_by exactly:
// null < false < true < numbers < strings < arrays < objects; numbers by value,
// strings by Unicode scalars, arrays lexicographic, objects by sorted key list
// then values. jq's sort is STABLE; Swift's is not — sortStableBy decorates
// with the original index.
public enum JQOrder {
    public static func less(_ a: JSONValue, _ b: JSONValue) -> Bool {
        rank(a) != rank(b) ? rank(a) < rank(b) : lessSameRank(a, b)
    }

    static func rank(_ v: JSONValue) -> Int {
        switch v {
        case .null: return 0
        case .bool(let x): return x ? 2 : 1
        case .int, .double: return 3
        case .string: return 4
        case .array: return 5
        case .object: return 6
        }
    }

    static func lessSameRank(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null), (.bool, .bool):
            return false
        case (.string(let x), .string(let y)):
            return x < y
        case (.array(let x), .array(let y)):
            for (ex, ey) in zip(x, y) {
                if less(ex, ey) { return true }
                if less(ey, ex) { return false }
            }
            return x.count < y.count
        case (.object(let x), .object(let y)):
            let kx = x.keys.sorted()
            let ky = y.keys.sorted()
            if kx != ky { return kx.lexicographicallyPrecedes(ky) }
            for k in kx {
                let vx = x[k] ?? .null
                let vy = y[k] ?? .null
                if less(vx, vy) { return true }
                if less(vy, vx) { return false }
            }
            return false
        default:
            let na = a.numberValue ?? 0
            let nb = b.numberValue ?? 0
            return na < nb
        }
    }

    public static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        !less(a, b) && !less(b, a)
    }
}

extension Array {
    /// Stable sort by a jq-tuple key (jq's sort_by is stable).
    public func sortedStableBy(_ key: (Element) -> JSONValue) -> [Element] {
        enumerated()
            .sorted { l, r in
                let kl = key(l.element)
                let kr = key(r.element)
                if JQOrder.less(kl, kr) { return true }
                if JQOrder.less(kr, kl) { return false }
                return l.offset < r.offset
            }
            .map(\.element)
    }
}

extension Array where Element == JSONValue {
    /// jq `unique`: sort + dedup by the total order.
    public func jqUnique() -> [JSONValue] {
        let sorted = sortedStableBy { $0 }
        var out: [JSONValue] = []
        for v in sorted where out.last.map({ !JQOrder.equal($0, v) }) ?? true {
            out.append(v)
        }
        return out
    }
}
