import Foundation
import LeylineModel

/// An immutable observation of one committed transition. A revision may never
/// be paired with a later read of `worldState` when handing work to AppKit.
struct CoreCommittedSnapshot: Equatable, Sendable {
    let revision: UInt64
    let world: JSONValue
    let receiptUptimeNs: UInt64

    var borderPlan: BorderPlan { BorderProjection.plan(world: world) }
}

/// World-state facts the resident reads at every boundary, spelled once.
extension JSONValue {
    /// The event that produced this world state; "" when it names none.
    var worldEvent: String { at(path: "event")?.stringValue ?? "" }
    /// Management is on unless the state says otherwise.
    var managementEnabled: Bool { at(path: "management_enabled")?.boolValue != false }
    /// The observation's own completeness claim; nil when it made none.
    var worldComplete: Bool? { at(path: "observation.world_complete")?.boolValue }
    /// A window record that is eligible, on a visible enabled Space and still present.
    var isLiveEnabledWindow: Bool {
        at(path: "eligible")?.boolValue == true && at(path: "space_visible")?.boolValue == true
            && at(path: "space_enabled")?.boolValue == true
            && at(path: "minimized")?.boolValue != true && at(path: "destroyed")?.boolValue != true
    }
}

/// The sole bounded bridge from authoritative commits to presentation. There is
/// at most one executing render and one pending latest snapshot. The executor
/// must enqueue asynchronously; observation and authority never wait for it.
final class CorePresentationMailbox: @unchecked Sendable {
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let execute: Executor
    private let present: @Sendable (CoreCommittedSnapshot) -> Void
    private var latest: CoreCommittedSnapshot?
    private var pending: CoreCommittedSnapshot?
    private var scheduled = false
    private var replaced: UInt64 = 0

    init(execute: @escaping Executor,
         present: @escaping @Sendable (CoreCommittedSnapshot) -> Void) {
        self.execute = execute
        self.present = present
    }

    func submit(_ snapshot: CoreCommittedSnapshot) {
        lock.lock()
        if let latest, snapshot.revision <= latest.revision {
            lock.unlock()
            return
        }
        latest = snapshot
        if pending != nil { replaced &+= 1 }
        pending = snapshot
        let needsScheduling = !scheduled
        scheduled = true
        lock.unlock()
        if needsScheduling { execute { [self] in drainOne() } }
    }

    var health: JSONObject {
        lock.lock()
        defer { lock.unlock() }
        return [
            "pending_snapshots": .int(pending == nil ? 0 : 1),
            "scheduled": .bool(scheduled),
            "superseded_visuals": .int(Int64(clamping: replaced)),
            "latest_committed_revision": latest.map { .int(Int64(clamping: $0.revision)) } ?? .null,
            // Submission is recorded by BorderRenderer; this mailbox cannot
            // observe physical presentation and never manufactures its stamp.
            "visible_frame_evidence": .null,
        ]
    }

    private func drainOne() {
        lock.lock()
        let snapshot = pending
        pending = nil
        lock.unlock()
        if let snapshot { present(snapshot) }
        lock.lock()
        let needsScheduling = pending != nil
        if !needsScheduling { scheduled = false }
        lock.unlock()
        if needsScheduling { execute { [self] in drainOne() } }
    }
}
