import Foundation
import LeylineModel

/// Frozen legacy claims are filtered by the ratified retained actions. The resident additionally
/// keeps the retained global-first shortcuts available in move/resize, with modal overrides intact.
private func residentClaimFixtureFailures(_ inventory: ResidentInputClaims, fixture: JSONValue) -> [String] {
    guard let modes = fixture.at(path: "expected_action_routes")?.objectValue, !modes.isEmpty else {
        return ["fixture.expected_action_routes_missing"]
    }
    var failures: [String] = []
    for (mode, value) in modes {
        guard let routes = value.objectValue else { failures.append(mode + ".fixture_routes_invalid"); continue }
        let expected = Dictionary(uniqueKeysWithValues: routes.compactMap { key, value in value.stringValue.map { (key, $0) } })
        if expected.count != routes.count { failures.append(mode + ".fixture_action_invalid") }
        if inventory.actionRoutes(for: mode) != expected { failures.append(mode + ".action_routes_mismatch") }
        if inventory.claims(for: mode) != expected.keys.sorted() { failures.append(mode + ".claims_mismatch") }
    }
    return failures
}

/// Keep the original frozen contract untouched; the user-authorized shortcut
/// is a separately pinned amendment with independent expected counts.
private func residentClaimFixtureWithSpaceToggle(base: JSONValue, amendment: JSONValue) -> JSONValue? {
    guard var value = base.objectValue, let action = amendment.at(path: "action_id")?.stringValue,
          let chord = amendment.at(path: "chord")?.stringValue,
          let modes = amendment.at(path: "modes")?.arrayValue?.compactMap(\.stringValue), modes.count == 3,
          var routes = value["expected_action_routes"]?.objectValue,
          var additions = value["allowed_global_first_additions"]?.objectValue,
          var retained = value["retained_action_ids"]?.arrayValue else { return nil }
    retained.append(.string(action)); value["retained_action_ids"] = .array(retained)
    for mode in modes {
        var table = routes[mode]?.objectValue ?? [:]
        table[chord] = .string(action); routes[mode] = .object(table)
        additions[mode] = .array((additions[mode]?.arrayValue ?? []) + [.string(chord)])
    }
    routes.removeValue(forKey: "input")
    value["expected_action_routes"] = .object(routes)
    value["allowed_global_first_additions"] = .object(additions)
    value["expected_claim_counts"] = amendment.at(path: "expected_claim_counts")
    return .object(value)
}

/// @canonical resident_input_claim_self_test -- actual headless configuration versus frozen legacy
/// retained-subset/action oracle. Mutations alter the canonical loader's supported-action boundary.
func runResidentClaimsSelfTest() -> Int32 {
    var test = SelfTest()
    let home = responsivenessRepositoryRoot()
    guard let data = FileManager.default.contents(atPath: home + "/leylined/Fixtures/input/claims.json"),
          let base = try? JSONValue.parse(data),
          let extensionData = FileManager.default.contents(atPath: home + "/leylined/Fixtures/input/space-toggle-claims.json"),
          let amendment = try? JSONValue.parse(extensionData),
          let fixture = residentClaimFixtureWithSpaceToggle(base: base, amendment: amendment),
          let expectedModes = fixture.at(path: "expected_action_routes")?.objectValue,
          let legacyModes = fixture.at(path: "legacy_action_routes")?.objectValue,
          let retainedRows = fixture.at(path: "retained_action_ids")?.arrayValue else {
        test.check(false, "resident-claims/frozen-fixture-required"); return test.finish("resident-claims")
    }
    do {
        let input = try ResidentInput.load(home: home, dispatchAction: { _, complete in complete(4) }, onModeChanged: { _, _, _ in return true })
        let inventory = ResidentInputClaims(configuration: input.routing.configuration)
        let retained = Set(retainedRows.compactMap(\.stringValue))
        test.check(retained.count == 25 && retainedRows.count == 25 && retained == ResidentInput.retainedActionIds
            && Set(expectedModes.keys) == Set(input.routing.configuration.modeNames),
            "resident-claims/nonempty-frozen-retained-action-and-mode-inventory")
        test.check(input.health()["tap_installed"]?.boolValue == false
            && input.health()["desired_running"]?.boolValue == false,
            "resident-claims/actual-configuration-load-installs-no-input-tap")
        let failures = residentClaimFixtureFailures(inventory, fixture: fixture)
        if !failures.isEmpty {
            print("diagnostic resident-claims mismatches=\(failures.joined(separator: ","))")
        }
        test.check(failures.isEmpty, "resident-claims/actual-route-actions-and-sorted-claims-match-frozen-small-product")
        for mode in expectedModes.keys.sorted() {
            guard let legacy = legacyModes[mode]?.objectValue,
                  let frozenRetained = fixture.at(path: "retained_legacy_claims")?.objectValue?[mode]?.arrayValue,
                  let additions = fixture.at(path: "allowed_global_first_additions")?.objectValue?[mode]?.arrayValue,
                  let count = fixture.at(path: "expected_claim_counts")?.objectValue?[mode]?.intValue else {
                test.check(false, "resident-claims/\(mode)-legacy-disposition-required"); continue
            }
            let retainedLegacy = Set(legacy.compactMap { chord, action -> String? in
                guard let id = action.stringValue, retained.contains(id) || id == "mode.cancel" else { return nil }
                return chord
            })
            let current = Set(inventory.claims(for: mode))
            let frozen = Set(frozenRetained.compactMap(\.stringValue))
            let explicitAdditions = Set(additions.compactMap(\.stringValue))
            test.check(retainedLegacy == frozen && retainedLegacy.isSubset(of: current)
                && current.subtracting(retainedLegacy) == explicitAdditions
                && current.count == Int(count) && (mode == "input" ? count == 0 : count > 0),
                "resident-claims/\(mode)-exact-retained-legacy-subset-and-explicit-global-first-additions")
        }
        let routedActions = Set(expectedModes.keys.flatMap { inventory.actionRoutes(for: $0).values })
        test.check(routedActions == retained.union(["mode.cancel"]),
            "resident-claims/every-retained-action-has-a-real-route-and-only-modal-exit-is-implicit")
        let unsupported = Set((fixture.at(path: "unsupported_action_ids")?.arrayValue ?? []).compactMap(\.stringValue))
        test.check(unsupported.count == 45 && input.routing.configuration.unsupportedActionIds.isEmpty
            && unsupported.isDisjoint(with: retained)
            && Set(input.routing.configuration.modeNames) == ["default", "move", "resize"],
            "resident-claims/shipping-keymaps-have-only-v1-actions-and-modes")
        let unknownModes = (fixture.at(path: "unknown_or_retired_modes")?.arrayValue ?? []).compactMap(\.stringValue)
        test.check(!unknownModes.isEmpty && unknownModes.allSatisfy {
            inventory.claims(for: $0).isEmpty && inventory.actionRoutes(for: $0).isEmpty
        } && inventory.claims(for: "input").isEmpty,
            "resident-claims/unknown-retired-and-input-modes-claim-zero-keys")
        let reserved = Set((fixture.at(path: "reserved_chords")?.arrayValue ?? []).compactMap(\.stringValue))
        test.check(!reserved.isEmpty && expectedModes.keys.allSatisfy { reserved.isDisjoint(with: inventory.claims(for: $0)) },
            "resident-claims/reserved-chords-stay-unclaimed-in-every-mode")
        let partial = fixture.at(path: "partial_retained_action_dispositions")?.objectValue
        test.check(partial?.count == 3 && Set(partial?.keys ?? []) == ["move.rotate", "move.level.up", "move.level.down"]
            && partial?.values.allSatisfy { $0.stringValue?.isEmpty == false } == true
            && inventory.actionRoutes(for: "move")["c"] == "move.rotate"
            && inventory.actionRoutes(for: "move")["u"] == "move.level.up"
            && inventory.actionRoutes(for: "move")["i"] == "move.level.down",
            "resident-claims/rotation-and-staged-span-scope-remain-retained-with-limited-dispositions")
        let encoded = inventory.json(for: "resize")
        test.check(encoded.at(path: "schema")?.stringValue == "leyline/resident-input-claims/v1"
            && encoded.at(path: "claim_count")?.intValue == 13
            && encoded.at(path: "claims")?.arrayValue == inventory.claims(for: "resize").map(JSONValue.string)
            && encoded.at(path: "action_routes")?.objectValue?.count == 13,
            "resident-claims/optional-JSON-preserves-the-exact-legacy-line-inventory")
        guard let mutations = fixture.at(path: "mutations")?.objectValue else {
            test.check(false, "resident-claims/mutation-inventory-required"); return test.finish("resident-claims")
        }
        for key in mutations.keys.sorted() {
            guard let mutation = mutations[key]?.objectValue,
                  let action = mutation["action_id"]?.stringValue,
                  let expectedMode = mutation["expected_mismatch_mode"]?.stringValue else {
                test.check(false, "resident-claims/\(key)-mutation-description-required"); continue
            }
            let supported = mutation["operation"]?.stringValue == "add"
                ? retained.union([action]) : retained.subtracting([action])
            let changed: ResidentInput
            if mutation["operation"]?.stringValue == "add" {
                guard let chord = legacyModes[expectedMode]?.objectValue?.first(where: { $0.value == .string(action) })?.key,
                      let globalData = FileManager.default.contents(atPath: home + "/keymap/global.json"),
                      var global = try JSONValue.parse(globalData).objectValue,
                      var bindings = global["bindings"]?.arrayValue else {
                    test.check(false, "resident-claims/retired-route-mutation-required"); continue
                }
                bindings.append(.object(["chord": .string(chord), "action_id": .string(action)]))
                global["bindings"] = .array(bindings)
                let configuration = try ResidentInputConfiguration(decode: input.routing.configuration.decode,
                    fsm: input.routing.configuration.fsm, globalData: Data(JSONValue.object(global).canonical().utf8),
                    supportedActionIds: supported)
                changed = ResidentInput(configuration: configuration, dispatchAction: { _, complete in complete(4) },
                    onModeChanged: { _, _, _ in return true })
            } else {
                changed = try ResidentInput.load(home: home, supportedActionIds: supported,
                    dispatchAction: { _, complete in complete(4) }, onModeChanged: { _, _, _ in return true })
            }
            let changedInventory = ResidentInputClaims(configuration: changed.routing.configuration)
            let rejected = residentClaimFixtureFailures(changedInventory, fixture: fixture)
            test.check(rejected.contains(expectedMode + ".action_routes_mismatch")
                && changed.health()["tap_installed"]?.boolValue == false,
                "resident-claims/\(key)-mutation-is-rejected-by-the-frozen-route-oracle")
        }
    } catch { test.check(false, "resident-claims/actual-configuration-load: \(error)") }
    return test.finish("resident-claims")
}
