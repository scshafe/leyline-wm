// Pure callback target routing through the production selector. No AX/CG call,
// observer registration, sleep, window effect, or synthetic window-ID bridge.
import Foundation
import LeylineModel

func runAccessibilityNotificationTargetScenarios(test: inout SelfTest) {
    runAccessibilityWindowNotificationSlotScenarios(test: &test)
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/feed/notification-capsule.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 3 else {
        test.check(false, "notification-capsule/nonvacuous-fixture-load"); return
    }
    for scenario in scenarios {
        let selected = accessibilityNotificationTarget(
            notifiedElement: scenario.at(path: "notified_element")!.stringValue!,
            registeredElement: scenario.at(path: "registered_element")!.stringValue!,
            registeredWindowId: scenario.at(path: "registered_window_id")?.intValue)
        test.check(selected == scenario.at(path: "expected")!.stringValue!,
            "notification-capsule/" + scenario.at(path: "name")!.stringValue!)
    }
}

/// Executes the same slot installation and callback admission used by real
/// registrations. No private AX identity is faked and no native AX call runs.
private func runAccessibilityWindowNotificationSlotScenarios(test: inout SelfTest) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/feed/window-notification-slots.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 10 else {
        test.check(false, "notification-slots/nonvacuous-fixture-load"); return
    }
    for scenario in scenarios {
        var installed: [String] = [], removed: [String] = []
        var delivered = false
        let result: Result<[String], ProjectionObservationFailure>
        switch accessibilityWindowNotificationNames(role: scenario.at(path: "role")?.stringValue,
            subrole: scenario.at(path: "subrole")?.stringValue) {
        case .failure(let failure): result = .failure(failure)
        case .success(let names):
            result = accessibilityRegisterWindowNotificationSlots(names, add: { name in
                installed.append(name)
                return name == scenario.at(path: "fail_slot")?.stringValue ? .cannotComplete : .success
            }, remove: { removed.append($0) })
        }
        let observed: String
        switch result {
        case .failure(let failure): observed = failure.code
        case .success(let actualSlots):
            observed = "success"
            if let notification = scenario.at(path: "notification")?.stringValue {
                delivered = accessibilityWindowNotificationIsRegistered(notification, notifications: actualSlots)
            }
        }
        test.check(observed == scenario.at(path: "expected")!.stringValue!
            && installed == scenario.at(path: "slots")!.arrayValue!.compactMap(\.stringValue)
            && removed == (scenario.at(path: "removed")?.arrayValue ?? []).compactMap(\.stringValue)
            && delivered == (scenario.at(path: "delivered")?.boolValue ?? false),
            "notification-slots/" + scenario.at(path: "name")!.stringValue!)
    }
}
