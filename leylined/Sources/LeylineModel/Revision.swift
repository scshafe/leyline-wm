/// The total order over core state changes.
///
/// Monotonic across epochs: the journal persists the high-water mark, so
/// `expected_revision` comparisons stay valid across a crash. The epoch (one
/// process lifetime) scopes request-id idempotency only — it never resets this
/// counter. On the wire a Revision is a bare unsigned integer, not an object.
public struct Revision: Hashable, Comparable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public func next() -> Revision {
        Revision(value + 1)
    }

    public static func < (lhs: Revision, rhs: Revision) -> Bool {
        lhs.value < rhs.value
    }
}

extension Revision: Codable {
    public init(from decoder: any Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
