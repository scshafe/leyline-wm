import Foundation
import LeylineModel

private struct ModeReleaseEntry: Equatable { let mode: String; let generation: UInt64; let resetsInteraction: Bool }

/// Uses the actual atomic mode word and delivery mailbox, without installing a tap.
func runResidentModeReleaseChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: SelfTestFixtures.path("input/mode-release.json", root: home)),
          let fixture = try? JSONValue.parse(data),
          let entry = fixture.at(path: "entry_chord")?.stringValue,
          let exit = fixture.at(path: "exit_chord")?.stringValue,
          let reason = fixture.at(path: "release_reason")?.stringValue.flatMap(ResidentInputReleaseReason.init(rawValue:)) else {
        test.check(false, "mode-release/fixture-required"); return
    }
    let recorder = Recorded<ModeReleaseEntry>()
    let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { recorder.append(.init(mode: $0, generation: $1, resetsInteraction: $2)); return true })
    _ = routing.admit(chord: entry); routing.flushForSelfTest()
    let entered = routing.generation
    routing.withMailboxLockForSelfTest { routing.release(reason: reason) }
    routing.flushForSelfTest()
    let released = routing.generation
    test.check(released > entered && routing.mode == "default"
        && recorder.values.last == .init(mode: "default", generation: released, resetsInteraction: true)
        && routing.health()["pending_mode_release"] == .bool(false),
        "mode-release/mailbox-contention-cannot-drop-forced-default-publication")

    // Hold the real delivery queue across two releases and a newer optimistic entry.
    // Stale release work must deliver the newer mode once, with the inherited reset.
    let held = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let blocked = ResidentAtomic<Bool>(false), newer = Recorded<ModeReleaseEntry>()
    let advancing = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { mode, generation, reset in
            if mode == "move", !blocked.exchange(true, ordering: .acquiringAndReleasing) {
                held.signal(); _ = resume.wait(timeout: .now() + .seconds(3))
            }
            newer.append(.init(mode: mode, generation: generation, resetsInteraction: reset))
        return true })
    _ = advancing.admit(chord: entry)
    let firstHeld = held.wait(timeout: .now() + .seconds(1)) == .success
    advancing.withMailboxLockForSelfTest {
        advancing.release(reason: reason); advancing.release(reason: reason)
    }
    let renewed = advancing.admit(chord: entry), current = advancing.generation
    resume.signal(); advancing.flushForSelfTest()
    test.check(firstHeld && renewed == .claimed && advancing.mode == "move"
        && newer.values.last == .init(mode: "move", generation: current, resetsInteraction: true)
        && newer.values.filter { $0.generation == current }.count == 1,
        "mode-release/coalesced-forced-releases-retire-old-context-before-newer-entry-once")

    let provisional = Recorded<ModeReleaseEntry>()
    let partial = ResidentInputRouting(configuration: configuration, dispatchAction: { action, complete in
        complete(action.actionId == "move.cancel" ? 3 : 0)
    }, onModeChanged: { provisional.append(.init(mode: $0, generation: $1, resetsInteraction: $2)); return true })
    _ = partial.admit(chord: entry); partial.flushForSelfTest()
    _ = partial.admit(chord: exit); partial.flushForSelfTest()
    test.check(partial.mode == "move" && provisional.values.contains { $0.mode == "default" }
        && provisional.values.allSatisfy { !$0.resetsInteraction },
        "mode-release/Escape-provisional-default-preserves-partial-unstage-restoration")
}

private final class ResidentModeReleaseRoutingBox: @unchecked Sendable {
    weak var routing: ResidentInputRouting?
}

/// The old callback is genuinely superseded between capture and authority commit.
func runResidentModeReleaseAcknowledgementChecks(configuration: ResidentInputConfiguration, home: String, test: inout SelfTest) {
    guard let data = FileManager.default.contents(atPath: SelfTestFixtures.path("input/mode-release.json", root: home)),
          let fixture = try? JSONValue.parse(data), let world = fixture.at(path: "authority_world"),
          let entry = fixture.at(path: "entry_chord")?.stringValue,
          let reason = fixture.at(path: "release_reason")?.stringValue.flatMap(ResidentInputReleaseReason.init(rawValue:)) else {
        test.check(false, "mode-release/acknowledgement-fixture-required"); return
    }
    let server = CoreServer(socketPath: "/tmp/mode-release-unused.sock", initialState: world)
    _ = server.applyModeFrame(.init(type: .snapshot, epoch: "mode-reset-ack", sequence: 0, mode: "move"))
    let box = ResidentModeReleaseRoutingBox(), renewed = ResidentAtomic<Bool>(false)
    let sequence = ResidentAtomic<UInt64>(0), rejected = ResidentAtomic<Int>(0)
    let accepted = Recorded<ModeReleaseEntry>()
    let routing = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { mode, generation, reset in
            if mode == "default", reset, !renewed.exchange(true, ordering: .acquiringAndReleasing) {
                _ = box.routing?.admit(chord: entry)
            }
            let next = sequence.load(ordering: .acquiring) + 1
            let result = server.applyModeFrame(.init(type: .changed, epoch: "mode-reset-ack",
                sequence: Int64(clamping: next), mode: mode, resetsInteraction: reset, inputGeneration: generation),
                commitGuard: { box.routing?.generation == generation ? nil : "input_generation_released" })
            guard result.status == .accepted else { rejected.wrappingAdd(1, ordering: .acquiringAndReleasing); return false }
            sequence.store(next, ordering: .releasing); accepted.append(.init(mode: mode, generation: generation, resetsInteraction: reset))
            return true
        })
    box.routing = routing
    _ = routing.admit(chord: entry); routing.flushForSelfTest()
    routing.release(reason: reason)
    // Work scheduled during the deliberately reentrant callback follows the first barrier.
    routing.flushForSelfTest(); routing.flushForSelfTest()
    test.check(rejected.load(ordering: .acquiring) == 1 && routing.mode == "move"
        && accepted.values.last == .init(mode: "move", generation: routing.generation, resetsInteraction: true)
        && server.worldState.at(path: "model_state.interaction") == nil
        && server.worldState.at(path: "mode") == .string("move")
        && server.worldState.at(path: "mode_input_generation") == .int(Int64(clamping: routing.generation))
        && routing.health()["pending_mode_release"] == .bool(false)
        && sequence.load(ordering: .acquiring) == 2,
        "mode-release/refused-old-callback-cannot-consume-reset-inherited-by-newer-entry")

    // A real earlier default observation arrives while a newer entry is held.
    let feedbackEntered = DispatchSemaphore(value: 0), feedbackResume = DispatchSemaphore(value: 0)
    let feedback = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { _, _, _ in feedbackEntered.signal(); _ = feedbackResume.wait(timeout: .now() + .seconds(2)); return true })
    var earlier = fixture.at(path: "authority_world")!.objectValue!
    earlier["mode"] = .string("default"); earlier["mode_input_generation"] = .int(0)
    earlier["event"] = .string("ax_focus_changed"); earlier["interaction_invalidated"] = .bool(false)
    _ = feedback.admit(chord: entry)
    let feedbackHeld = feedbackEntered.wait(timeout: .now() + .seconds(1)) == .success
    let oldDefaultIgnored = !CoreRuntimeServices.committedDefaultCanReleaseInput(.object(earlier), currentInputGeneration: feedback.generation)
    earlier["event"] = .string("topology_changed"); earlier["interaction_invalidated"] = .bool(true)
    let genuineFence = CoreRuntimeServices.committedDefaultCanReleaseInput(.object(earlier), currentInputGeneration: feedback.generation)
    feedbackResume.signal(); feedback.flushForSelfTest()
    test.check(feedbackHeld && oldDefaultIgnored && genuineFence && feedback.mode == "move",
        "mode-release/older-default-observation-cannot-cancel-new-entry-but-genuine-context-invalidation-still-can")

    let attempts = ResidentAtomic<Int>(0)
    let unavailable = ResidentInputRouting(configuration: configuration, dispatchAction: { _, complete in complete(0) },
        onModeChanged: { _, _, _ in attempts.wrappingAdd(1, ordering: .acquiringAndReleasing); return false })
    unavailable.release(reason: reason); unavailable.flushForSelfTest(); unavailable.flushForSelfTest()
    test.check(attempts.load(ordering: .acquiring) == 1 && unavailable.mode == "default"
        && unavailable.health()["pending_mode_release"] == .bool(true),
        "mode-release/same-generation-authority-refusal-remains-explicit-without-reschedule-spin")
}
