import Foundation
import LeylineModel

/// Chord-to-action routes of a loaded configuration, including implicit modal exit keys.
private func residentActionRoutes(_ configuration: ResidentInputConfiguration, mode: String) -> [String: String] {
    guard let index = configuration.modeNames.firstIndex(of: mode) else { return [:] }
    return configuration.routes[index].mapValues(\.actionId)
}

private func residentClaimFixtureFailures(_ configuration: ResidentInputConfiguration, fixture: JSONValue) -> [String] {
    guard let modes = fixture.at(path: "expected_action_routes")?.objectValue, !modes.isEmpty else {
        return ["fixture.expected_action_routes_missing"]
    }
    var failures: [String] = []
    for (mode, value) in modes {
        guard let routes = value.objectValue else { failures.append(mode + ".fixture_routes_invalid"); continue }
        let expected = Dictionary(uniqueKeysWithValues: routes.compactMap { key, value in value.stringValue.map { (key, $0) } })
        if expected.count != routes.count { failures.append(mode + ".fixture_action_invalid") }
        if residentActionRoutes(configuration, mode: mode) != expected { failures.append(mode + ".action_routes_mismatch") }
    }
    return failures
}

/// @canonical resident_input_claim_self_test -- the actual headless configuration versus the
/// independent v1 route contract. Mutations alter the loader's supported-action boundary or keymap.
func runResidentClaimsSelfTest() -> Int32 {
    var test = SelfTest()
    let home = SelfTestFixtures.repositoryRoot()
    guard let data = FileManager.default.contents(atPath: SelfTestFixtures.path("input/v1-claims.json", root: home)),
          let fixture = try? JSONValue.parse(data),
          let expectedModes = fixture.at(path: "expected_action_routes")?.objectValue,
          let retainedRows = fixture.at(path: "retained_action_ids")?.arrayValue else {
        test.check(false, "resident-claims/route-contract-required"); return test.finish("claims")
    }
    do {
        let input = try ResidentInput.load(home: home, dispatchAction: { _, complete in complete(4) }, onModeChanged: { _, _, _ in return true })
        let configuration = input.routing.configuration
        let retained = Set(retainedRows.compactMap(\.stringValue))
        test.check(retained.count == 25 && retainedRows.count == 25 && retained == ResidentInput.retainedActionIds
            && Set(expectedModes.keys) == Set(configuration.modeNames)
            && Set(configuration.modeNames) == ["default", "move", "resize"],
            "resident-claims/retained-action-and-mode-inventory")
        test.check(input.health()["tap_installed"]?.boolValue == false
            && input.health()["desired_running"]?.boolValue == false,
            "resident-claims/actual-configuration-load-installs-no-input-tap")
        let failures = residentClaimFixtureFailures(configuration, fixture: fixture)
        if !failures.isEmpty {
            print("diagnostic resident-claims mismatches=\(failures.joined(separator: ","))")
        }
        test.check(failures.isEmpty, "resident-claims/actual-routes-match-the-v1-contract")
        let total = configuration.modeNames.reduce(0) { $0 + residentActionRoutes(configuration, mode: $1).count }
        test.check(total == 43, "resident-claims/three-modes-claim-forty-three-chords")
        let routedActions = Set(configuration.modeNames.flatMap { residentActionRoutes(configuration, mode: $0).values })
        test.check(routedActions == retained.union(["mode.cancel"]),
            "resident-claims/every-retained-action-has-a-real-route-and-only-modal-exit-is-implicit")
        test.check(configuration.unsupportedActionIds.isEmpty, "resident-claims/shipping-keymaps-have-only-v1-actions")
        test.check(["input", "unknown", "capture"].allSatisfy { residentActionRoutes(configuration, mode: $0).isEmpty },
            "resident-claims/unknown-retired-and-input-modes-claim-zero-keys")

        // Each mutation must be visible to the route contract and must not install a tap.
        let mutations: [(name: String, supported: Set<String>, extraGlobal: (chord: String, action: String)?, mode: String)] = [
            ("retained-rotation-removed", retained.subtracting(["move.rotate"]), nil, "move"),
            ("retained-global-navigation-removed", retained.subtracting(["nav.focus.east"]), nil, "default"),
            ("retired-top-execution-added", retained.union(["move.execute.top"]),
             ("cmd + ctrl + alt + shift - u", "move.execute.top"), "move"),
        ]
        for mutation in mutations {
            let changed: ResidentInput
            if let extra = mutation.extraGlobal {
                guard let globalData = FileManager.default.contents(atPath: home + "/keymap/global.json"),
                      var global = try JSONValue.parse(globalData).objectValue,
                      var bindings = global["bindings"]?.arrayValue else {
                    test.check(false, "resident-claims/\(mutation.name)-keymap-required"); continue
                }
                bindings.append(.object(["chord": .string(extra.chord), "action_id": .string(extra.action)]))
                global["bindings"] = .array(bindings)
                let mutated = try ResidentInputConfiguration(decode: configuration.decode, fsm: configuration.fsm,
                    globalData: Data(JSONValue.object(global).canonical().utf8), supportedActionIds: mutation.supported)
                changed = ResidentInput(configuration: mutated, dispatchAction: { _, complete in complete(4) },
                    onModeChanged: { _, _, _ in return true })
            } else {
                changed = try ResidentInput.load(home: home, supportedActionIds: mutation.supported,
                    dispatchAction: { _, complete in complete(4) }, onModeChanged: { _, _, _ in return true })
            }
            let rejected = residentClaimFixtureFailures(changed.routing.configuration, fixture: fixture)
            test.check(rejected.contains(mutation.mode + ".action_routes_mismatch")
                && changed.health()["tap_installed"]?.boolValue == false,
                "resident-claims/\(mutation.name)-mutation-is-rejected-by-the-route-contract")
        }
    } catch { test.check(false, "resident-claims/actual-configuration-load: \(error)") }
    return test.finish("claims")
}
