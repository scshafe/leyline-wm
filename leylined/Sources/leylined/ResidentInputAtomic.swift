import CResidentAtomics
import Foundation

enum ResidentAtomicOrdering { case relaxed, acquiring, releasing, acquiringAndReleasing }

protocol ResidentAtomicValue: Sendable {
    var residentAtomicBits: UInt64 { get }
    static func fromResidentAtomicBits(_ bits: UInt64) -> Self
}

extension UInt64: ResidentAtomicValue {
    var residentAtomicBits: UInt64 { self }
    static func fromResidentAtomicBits(_ bits: UInt64) -> UInt64 { bits }
}
extension Int: ResidentAtomicValue {
    var residentAtomicBits: UInt64 { UInt64(truncatingIfNeeded: self) }
    static func fromResidentAtomicBits(_ bits: UInt64) -> Int { Int(truncatingIfNeeded: bits) }
}
extension Bool: ResidentAtomicValue {
    var residentAtomicBits: UInt64 { self ? 1 : 0 }
    static func fromResidentAtomicBits(_ bits: UInt64) -> Bool { bits != 0 }
}

/// Lock-free C11 storage; orders are always at least acquire/release even when
/// telemetry requests relaxed access. No OS lock or macOS 15 API is involved.
final class ResidentAtomic<Value: ResidentAtomicValue>: @unchecked Sendable {
    private let storage: OpaquePointer
    init(_ value: Value) { storage = leyline_atomic_create(value.residentAtomicBits) }
    deinit { leyline_atomic_destroy(storage) }
    func load(ordering: ResidentAtomicOrdering) -> Value {
        Value.fromResidentAtomicBits(leyline_atomic_load(storage))
    }
    func store(_ value: Value, ordering: ResidentAtomicOrdering) {
        leyline_atomic_store(storage, value.residentAtomicBits)
    }
    @discardableResult
    func exchange(_ value: Value, ordering: ResidentAtomicOrdering) -> Value {
        Value.fromResidentAtomicBits(leyline_atomic_exchange(storage, value.residentAtomicBits))
    }
    func compareExchange(expected: Value, desired: Value, ordering: ResidentAtomicOrdering) -> (exchanged: Bool, original: Value) {
        let exchanged = leyline_atomic_compare_exchange(storage, expected.residentAtomicBits, desired.residentAtomicBits)
        return (exchanged, exchanged ? expected : load(ordering: .acquiring))
    }
    @discardableResult
    func wrappingAdd(_ value: Value, ordering: ResidentAtomicOrdering) -> Value {
        Value.fromResidentAtomicBits(leyline_atomic_add(storage, value.residentAtomicBits))
    }
}
