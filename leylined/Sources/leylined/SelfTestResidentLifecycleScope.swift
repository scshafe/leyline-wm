// Canonical lifecycle decisions and real CoreServer mode transitions. No AX,
// event tap, live socket, delay, or window effect is created by these scenarios.
import Foundation
import LeylineModel

func runResidentLifecycleScopeScenarios(check: (String, Bool) -> Void) {
    let path = SelfTestFixtures.url("resident/lifecycle-scope.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 20,
          let managed = fixture.at(path: "managed")?.arrayValue, managed.count == 2,
          let ignored = fixture.at(path: "ignored"), let newManaged = fixture.at(path: "new_managed") else {
        check("lifecycle-scope/nonvacuous-fixture-load", false); return
    }
    let ignoredID = ignored.at(path: "window_id")!.intValue!
    let secondID = managed[1].at(path: "window_id")!.intValue!
    for scenario in scenarios {
        let event = scenario.requiredString("event")
        let mutation = scenario.requiredString("mutation")
        var beforeWindows = managed, afterWindows = managed + [ignored]
        var target = ignoredID
        var afterIgnored = ignored.objectValue!
        var changed = managed[1].objectValue!
        switch mutation {
        case "ignored_destroyed": beforeWindows.append(ignored); afterWindows = managed
        case "ignored_minimized": beforeWindows.append(ignored)
        case "managed_created": afterWindows = managed + [newManaged]; target = newManaged.at(path: "window_id")!.intValue!
        case "managed_destroyed": afterWindows = [managed[0]]; target = secondID
        case "managed_minimized":
            changed["eligible"] = .bool(false); changed["managed"] = .bool(false)
            afterWindows = [managed[0], .object(changed)]; target = secondID
        case "managed_restored":
            changed["eligible"] = .bool(false); changed["managed"] = .bool(false)
            beforeWindows = [managed[0], .object(changed)]; afterWindows = managed; target = secondID
        case "pid_changed": changed["pid"] = fixture.at(path: "changed_pid"); afterWindows[1] = .object(changed)
        case "lifetime_changed": changed["window_generation"] = fixture.at(path: "changed_lifetime"); afterWindows[1] = .object(changed)
        case "space_changed": changed["space_key"] = fixture.at(path: "changed_space_key"); afterWindows[1] = .object(changed)
        case "display_changed": changed["display_id"] = fixture.at(path: "changed_display_id"); afterWindows[1] = .object(changed)
        case "frame_changed": changed["frame"] = fixture.at(path: "changed_frame"); afterWindows[1] = .object(changed)
        case "unknown_eligibility": afterIgnored.removeValue(forKey: "eligible"); afterWindows[2] = .object(afterIgnored)
        case "missing_lifetime": afterIgnored.removeValue(forKey: "window_generation"); afterWindows[2] = .object(afterIgnored)
        case "stale_receipt": beforeWindows.append(ignored)
        case "empty_cohort": beforeWindows = []; afterWindows = [ignored]
        default: break
        }
        func world(_ windows: [JSONValue], receipt: JSONValue, reason: String) -> JSONValue {
            .object(["observer_epoch": fixture.at(path: "epoch")!, "windows": .array(windows), "focus": managed[0],
                "model_state": .object(["interaction": fixture.at(path: "interaction")!]),
                "notification_window_id": .int(target),
                "observation": .object(["ready": .bool(true), "world_complete": .bool(true), "reason": .string(reason),
                    "source_receipt_uptime_ns": receipt, "read_completed_uptime_ns": receipt,
                    "target_window_id": .int(target)])])
        }
        let before = world(beforeWindows, receipt: fixture.at(path: "receipt_before")!,
            reason: mutation == "stale_receipt" ? event : "world_seed")
        var after = world(afterWindows, receipt: fixture.at(path: mutation == "stale_receipt" ? "receipt_before" : "receipt_after")!, reason: event).objectValue!
        var observation = after["observation"]!.objectValue!
        if mutation == "partial_world" { observation["world_complete"] = .bool(false) }
        if mutation == "missing_target" { observation.removeValue(forKey: "target_window_id"); after.removeValue(forKey: "notification_window_id") }
        if mutation == "conflicting_target" { after["notification_window_id"] = .int(secondID) }
        after["observation"] = .object(observation)
        let expected = scenario.at(path: "invalidates")!.boolValue!
        let direct = residentLifecycleInvalidatesInteraction(event: event, before: before, after: .object(after))

        let server = CoreServer(socketPath: selfTestSocketPath("leylined-lifecycle-scope"))
        var seed = before.objectValue!
        seed.removeValue(forKey: "observer_epoch"); seed["event"] = .string("world_seed")
        _ = server.applyWorldDelta(seed)
        _ = server.applyModeFrame(.init(type: .snapshot, epoch: fixture.requiredString("epoch"), sequence: 0, mode: "resize"))
        let active = server.worldState
        after.removeValue(forKey: "observer_epoch"); after.removeValue(forKey: "model_state")
        after["event"] = .string(event)
        if mutation == "stale_receipt" { after.removeValue(forKey: "observation"); after.removeValue(forKey: "notification_window_id") }
        _ = server.applyWorldDelta(after)
        let actual = server.worldState
        let interaction = actual.at(path: "model_state.interaction")
        check("lifecycle-scope/" + scenario.requiredString("name"), direct == expected
            && active.at(path: "mode")?.stringValue == "resize"
            && actual.at(path: "mode")?.stringValue == (expected ? "default" : "resize")
            && (expected ? interaction == nil : interaction == fixture.at(path: "interaction")))
    }
}
