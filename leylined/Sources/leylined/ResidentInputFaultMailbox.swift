import Foundation
import LeylineModel

/// @canonical resident_input_fault_delivery -- one pending immutable event and
/// one executing callback. Atomic ownership transfer keeps release independent
/// of the action worker, timeline, AppKit and a stalled notice recipient.
final class ResidentInputFaultMailbox: @unchecked Sendable {
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void
    private final class EventBox: Sendable {
        let event: ResidentInputFaultRelease
        init(_ event: ResidentInputFaultRelease) { self.event = event }
    }
    private let inputEpoch: String
    private let pending = ResidentAtomic<UInt64>(0)
    private let scheduled = ResidentAtomic<Bool>(false)
    private let executing = ResidentAtomic<Bool>(false)
    private let superseded = ResidentAtomic<Int>(0)
    private let rejected = ResidentAtomic<Int>(0)
    private let execute: Executor
    private let deliver: @Sendable (ResidentInputFaultRelease) -> Void

    init(inputEpoch: String, execute: Executor? = nil,
         deliver: @escaping @Sendable (ResidentInputFaultRelease) -> Void) {
        self.inputEpoch = inputEpoch
        self.deliver = deliver
        if let execute { self.execute = execute }
        else {
            let queue = DispatchQueue(label: "leyline.resident.input.fault.delivery", qos: .userInteractive)
            self.execute = { queue.async(execute: $0) }
        }
    }

    deinit {
        let remaining = pending.exchange(0, ordering: .acquiringAndReleasing)
        if remaining != 0 { Self.box(remaining).release() }
    }

    func submit(_ event: ResidentInputFaultRelease) {
        guard event.inputEpoch == inputEpoch, event.receiptUptimeNs > 0,
              event.originalGeneration < UInt64.max,
              event.releasedGeneration == event.originalGeneration + 1 else {
            rejected.wrappingAdd(1, ordering: .relaxed)
            return
        }
        var candidate = EventBox(event)
        // Every exchange transfers exactly one retained ownership. If an old
        // producer arrives late, put the newer displaced event back. No object
        // is dereferenced through a borrowed atomic pointer or shared lock.
        while true {
            let bits = UInt64(UInt(bitPattern: Unmanaged.passRetained(candidate).toOpaque()))
            let previous = pending.exchange(bits, ordering: .acquiringAndReleasing)
            guard previous != 0 else { break }
            let displaced = Self.box(previous).takeRetainedValue()
            superseded.wrappingAdd(1, ordering: .relaxed)
            guard displaced.event.releasedGeneration > candidate.event.releasedGeneration else { break }
            candidate = displaced
        }
        scheduleIfNeeded()
    }

    var health: JSONObject {
        ["pending_events": .int(pending.load(ordering: .acquiring) == 0 ? 0 : 1),
         "pending_capacity": .int(1), "executing_event": .bool(executing.load(ordering: .acquiring)),
         "superseded_events": .int(Int64(clamping: superseded.load(ordering: .relaxed))),
         "rejected_events": .int(Int64(clamping: rejected.load(ordering: .relaxed)))]
    }

    private static func box(_ bits: UInt64) -> Unmanaged<EventBox> {
        Unmanaged<EventBox>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(bits))!)
    }

    private func scheduleIfNeeded() {
        if scheduled.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            execute { [self] in drainOne() }
        }
    }

    private func drainOne() {
        let bits = pending.exchange(0, ordering: .acquiringAndReleasing)
        if bits != 0 {
            let event = Self.box(bits).takeRetainedValue().event
            executing.store(true, ordering: .releasing)
            deliver(event)
            executing.store(false, ordering: .releasing)
        }
        scheduled.store(false, ordering: .releasing)
        // Covers submission between taking the slot and releasing scheduling.
        if pending.load(ordering: .acquiring) != 0 { scheduleIfNeeded() }
    }
}
