import Foundation
import LeylineModel

private final class PresentationTestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    private(set) var snapshots: [CoreCommittedSnapshot] = []
    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.lock(); work.append(operation); lock.unlock()
    }
    func record(_ snapshot: CoreCommittedSnapshot) {
        lock.lock(); snapshots.append(snapshot); lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return work.count
    }
    func drain() {
        while true {
            lock.lock()
            guard !work.isEmpty else { lock.unlock(); return }
            let operation = work.removeFirst()
            lock.unlock()
            operation()
        }
    }
}

/// Exercises the real server publication and mailbox with rendering withheld.
/// It verifies committed/submitted semantics, never physical-frame timing.
func runPresentationSelfTest() -> Int32 {
    var failures: [String] = []
    func check(_ name: String, _ passed: Bool) {
        if !passed { failures.append(name) }
    }
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/projection/authority.json")
    do {
        let fixture = try JSONValue.parse(Data(contentsOf: path))
        guard let base = fixture.at(path: "world")?.objectValue,
              let cases = fixture.at(path: "mutations")?.arrayValue, !cases.isEmpty else {
            throw NSError(domain: "projection_fixture_invalid", code: 1)
        }
        check("identified enabled managed fixture produces focus", BorderProjection.plan(world: .object(base)).rings.count == 1)
        for row in cases {
            var world = base
            var focus = world["focus"]?.objectValue ?? [:]
            for (key, value) in row.at(path: "focus")?.objectValue ?? [:] { focus[key] = value }
            world["focus"] = .object(focus)
            for (key, value) in row.at(path: "world")?.objectValue ?? [:] { world[key] = value }
            let plan = BorderProjection.plan(world: .object(world))
            let expected = row.at(path: "expected_role")?.stringValue
            check(row.at(path: "name")?.stringValue ?? "unnamed",
                  expected.map { plan.rings.count == 1 && plan.rings[0].role.rawValue == $0 }
                    ?? plan.rings.isEmpty)
        }
        let queue = PresentationTestQueue()
        let mailbox = CorePresentationMailbox(execute: { queue.enqueue($0) }, present: { queue.record($0) })
        let server = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/leylined-presentation-unused-\(getpid()).sock")
        server.setCommittedSnapshotHandler { mailbox.submit($0) }
        var seed = base
        seed["event"] = .string("world_seed")
        _ = server.applyWorldDelta(seed)
        for i in 2...200 {
            _ = server.applyWorldDelta(["event": .string("fixture_update"), "sequence": .int(Int64(i))])
        }
        check("blocked renderer cannot stop 200 authoritative commits", server.currentRevision == 200)
        check("blocked renderer leaves factual health unacknowledged", server.committedSnapshot.revision == 200 && queue.snapshots.isEmpty)
        check("publication backlog bounded to one scheduled and one pending", queue.count == 1 && mailbox.health["pending_snapshots"] == .int(1))
        queue.drain()
        check("superseded visuals render only the latest immutable revision", queue.snapshots.count == 1 && queue.snapshots[0].revision == 200 && queue.snapshots[0].world.at(path: "sequence") == .int(200))
        let mode = ModeFrame(type: .snapshot, epoch: "presentation-fixture", sequence: 0, mode: "resize")
        _ = server.applyModeFrame(mode)
        let origin = server.committedSnapshot
        check("mode entry binds to origin window and Space", origin.borderPlan.rings.first?.role == .resizing)
        var changedFocus = base["focus"]!.objectValue!
        changedFocus["window_id"] = .int(102)
        _ = server.applyWorldDelta(["focus": .object(changedFocus), "event": .string("focus_changed")])
        check("new focus invalidates the old mode context", server.committedSnapshot.world.at(path: "mode") == .string("default") && server.committedSnapshot.borderPlan.rings.first?.role == .focus)
        queue.drain()
        let last = queue.snapshots.last!
        mailbox.replayLatest()
        queue.drain()
        check("remount replays current snapshot and same revision", queue.snapshots.last == last)
        check("physical visibility is never inferred from submission", mailbox.health["visible_frame_evidence"] == .null)
        var source = base["focus"]!.objectValue!
        source["window_id"] = .int(101)
        var destination = source; destination["window_id"] = .int(102)
        _ = server.applyWorldDelta(["focus": .object(source), "windows": .array([.object(source), .object(destination)])])
        _ = server.applyModeFrame(ModeFrame(type: .changed, epoch: "presentation-fixture", sequence: 1, mode: "move"))
        _ = server.applyWorldDelta(["focus": .object(destination), "event": .string("focus_changed")])
        check("ordinary focus cannot retarget or erase a positively bound move source",
            server.worldState.at(path: "mode") == .string("move")
                && server.worldState.at(path: "mode_context_window_id") == .int(101))
        _ = server.applyWorldDelta(["model_state": .object(["fixture": .bool(true)])])
        let modelRevision = server.worldState.at(path: "model_state_revision")
        _ = server.applyWorldDelta(["event": .string("diagnostic_fixture")])
        check("diagnostic revisions do not self-stale candidate model authority",
            server.worldState.at(path: "model_state_revision") == modelRevision)
        source["destroyed"] = .bool(true); source["eligible"] = .bool(false)
        _ = server.applyWorldDelta(["event": .string("ax_window_destroyed"), "windows": .array([.object(source), .object(destination)])])
        check("real move-origin loss still clears mode authority", server.worldState.at(path: "mode") == .string("default"))
    } catch {
        failures.append("fixture: \(error)")
    }
    for failure in failures { FileHandle.standardError.write(Data("self-test presentation FAIL: \(failure)\n".utf8)) }
    print("self-test presentation: \(failures.isEmpty ? "ok" : "failed")")
    return failures.isEmpty ? 0 : 1
}
