import Foundation
import LeylineModel

private struct SpacePartitionsFixture {
    let value: JSONValue
    var topology: JSONValue { value.at(path: "topology")! }
    func space(_ name: String) -> JSONValue { value.at(path: "spaces.\(name)")! }
    func key(_ name: String) -> String { "space:" + space(name).at(path: "space_uuid")!.stringValue! }
    func partitionKey(_ name: String) -> String {
        "\(space(name).at(path: "display_id")!.intValue!):\(space(name).at(path: "space_uuid")!.stringValue!)"
    }
    func partition(_ state: JSONValue, _ name: String) -> JSONValue? {
        state.at(path: "space_partitions.partitions")?.objectValue?[partitionKey(name)]
    }
    func world(_ names: [String] = ["A1", "B1"], enabled: [String: Bool] = [:], focus: Int64? = 11,
               epoch: String? = nil, removed: Set<Int64> = [], lifetimes: [Int64: Int64] = [:]) -> JSONValue {
        var contexts: [JSONValue] = [], windows: [JSONValue] = []
        for name in names {
            let spec = space(name), display = spec.at(path: "display_id")!.intValue!
            let uuid = spec.at(path: "space_uuid")!, on = enabled[name] ?? true
            contexts.append(.object(["display_id": .int(display), "space_uuid": uuid, "space_key": .string(key(name)),
                "space_enabled": .bool(on), "space_visible": .bool(true), "space_identity_available": .bool(true)]))
            let ids = (spec.at(path: "window_ids")?.arrayValue ?? []).compactMap(\.intValue)
            for (index, id) in ids.enumerated() where !removed.contains(id) {
                windows.append(.object(["window_id": .int(id), "pid": .int(500 + id), "window_generation": .int(lifetimes[id] ?? 1),
                    "display": .int(display), "display_id": .int(display), "space_uuid": uuid, "space_key": .string(key(name)),
                    "space_enabled": .bool(on), "space_visible": .bool(true), "space_identity_available": .bool(true),
                    "eligible": .bool(true), "resizable": .bool(true), "movable": .bool(true), "minimized": .bool(false),
                    "role": .string("AXWindow"), "subrole": .string("AXStandardWindow"),
                    "frame": .object(["x": .int((display - 1) * 1200 + Int64(index) * 600), "y": .int(30), "w": .int(596), "h": .int(770)])]))
            }
        }
        let anchor = windows.first(where: { $0.at(path: "window_id")?.intValue == focus })
            ?? windows.first(where: { $0.at(path: "space_enabled")?.boolValue == true })
        return .object(["complete": .bool(true), "trusted": .bool(true), "observer_epoch": .string(epoch ?? value.at(path: "observer_epoch")!.stringValue!),
            "observer_generation": .int(8), "topology_revision": .int(4), "topology": topology, "space_contexts": .array(contexts),
            "space_enabled": anchor?.at(path: "space_enabled") ?? .bool(false), "active_space_key": anchor?.at(path: "space_key") ?? .null,
            "windows": .array(windows), "focused_window_id": focus.map(JSONValue.int) ?? .null])
    }
}

private func spacePartitionsIds(_ state: JSONValue) -> Set<Int64> {
    Set(Arrangement.memberWindows(state.at(path: "arrangement") ?? .object([:])).compactMap { $0.at(path: "window_id")?.intValue })
}
private func spacePartitionsDivider(_ part: JSONValue?) -> Double? {
    part?.at(path: "arrangement.segments")?.arrayValue?.first?.at(path: "coord")?.numberValue
}
private func spacePartitionsRefusesUnchanged(_ plan: ResidentPlan, _ state: JSONValue) -> Bool {
    plan.status == .refused && plan.state == state && plan.targets == .object([:]) && plan.focusTarget == nil
}

/// Hermetic replay over actual planner/cache authoring; no AX reads, effects, menu or live input.
func runSpacePartitionsSelfTest() -> Int32 {
    var test = SelfTest()
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/space_partitions/display_spaces.json"
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data) else {
        test.check(false, "space-partitions/fixture-load"); return test.finish("space-partitions")
    }
    let fixture = SpacePartitionsFixture(value: value)
    let scenarios = value.at(path: "scenarios")?.arrayValue?.compactMap(\.stringValue) ?? []
    test.check(scenarios.count == 14 && Set(scenarios).count == 14
        && value.at(path: "spaces")?.objectValue?.count == 5, "space-partitions/nonempty-independent-fourteen-scenario-fixture")
    var state: JSONValue = .object([:])
    func reconcile(_ world: JSONValue) -> ResidentPlan {
        let plan = ResidentPlanner.plan(actionID: "world.reconcile", state: state, world: world)
        if plan.status == .accepted { state = plan.state }
        return plan
    }
    func action(_ action: String, _ world: JSONValue) -> ResidentPlan {
        let plan = ResidentPlanner.plan(actionID: action, state: state, world: world)
        if plan.status == .accepted { state = plan.state }
        return plan
    }
    let baseline = reconcile(fixture.world())
    test.check(baseline.status == .accepted && spacePartitionsIds(state) == [11, 12, 31, 32]
        && fixture.partition(state, "A1") != nil && fixture.partition(state, "B1") != nil,
        "space-partitions/two-visible-display-Spaces-seed-with-exact-membership")
    var resizedWorld = fixture.world().objectValue!, resizedTopology = fixture.topology.objectValue!
    var resizedDisplays = resizedTopology["displays"]!.arrayValue!
    var resizedDisplay = resizedDisplays[0].objectValue!, resizedUsable = resizedDisplay["usable"]!.objectValue!
    resizedUsable["h"] = .int(600); resizedDisplay["usable"] = .object(resizedUsable)
    resizedDisplays[0] = .object(resizedDisplay); resizedTopology["displays"] = .array(resizedDisplays)
    resizedWorld["topology"] = .object(resizedTopology)
    let resized = ResidentPlanner.plan(actionID: "world.reconcile", state: baseline.state, world: .object(resizedWorld))
    test.check(resized.status == .accepted && spacePartitionsIds(resized.state) == [11, 12, 31, 32]
        && resized.targets.at(path: "11.frame.h")?.numberValue == 600,
        "space-partitions/usable-frame-shrink-validates-old-checkpoint-in-recorded-geometry-and-repacks-current-world")
    var corruptedState = baseline.state.objectValue!, corruptedCache = corruptedState["space_partitions"]!.objectValue!
    var corruptedParts = corruptedCache["partitions"]!.objectValue!, corruptedPart = corruptedParts[fixture.partitionKey("A1")]!.objectValue!
    var invalidGeometry = corruptedPart["display_geometry"]!.objectValue!, invalidUsable = invalidGeometry["usable"]!.objectValue!
    invalidUsable["h"] = .int(0); invalidGeometry["usable"] = .object(invalidUsable)
    corruptedPart["display_geometry"] = .object(invalidGeometry); corruptedParts[fixture.partitionKey("A1")] = .object(corruptedPart)
    corruptedCache["partitions"] = .object(corruptedParts); corruptedState["space_partitions"] = .object(corruptedCache)
    let invalidCached = JSONValue.object(corruptedState)
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: invalidCached,
        world: .object(resizedWorld)), invalidCached),
        "space-partitions/geometry-change-cannot-discard-invalid-recorded-geometry-as-a-success")
    _ = action("resize.start", fixture.world())
    let resize = action("resize.adjust.east", fixture.world())
    test.check(resize.status == .accepted && spacePartitionsDivider(fixture.partition(state, "A1")) == 640,
        "space-partitions/manual-resize-retains-forty-point-step-in-partition-checkpoint")
    _ = action("resize.off", fixture.world())
    let manualA1 = fixture.partition(state, "A1"), originalB1 = fixture.partition(state, "B1")
    _ = reconcile(fixture.world(["A2", "B1"], focus: 21))
    test.check(spacePartitionsIds(state) == [21, 22, 31, 32] && fixture.partition(state, "A1") == manualA1
        && fixture.partition(state, "B1") == originalB1, "space-partitions/A1-to-A2-preserves-departed-and-unaffected-display")
    _ = reconcile(fixture.world())
    test.check(fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "B1") == originalB1
        && spacePartitionsIds(state) == [11, 12, 31, 32], "space-partitions/return-to-A1-resurrects-validated-manual-geometry")
    let priorState = state
    var arrivalWorld = fixture.world(focus: 12).objectValue!, arrivalWindows = arrivalWorld["windows"]!.arrayValue!
    var newcomer = arrivalWindows[0].objectValue!; newcomer["window_id"] = .int(13); newcomer["pid"] = .int(513)
    arrivalWindows.append(.object(newcomer)); arrivalWorld["windows"] = .array(arrivalWindows)
    _ = reconcile(.object(arrivalWorld))
    let untouchedBefore = (priorState.at(path: "arrangement.bindings")?.objectValue ?? [:]).values.first { $0.at(path: "window_id")?.intValue == 12 }
    let untouchedAfter = (state.at(path: "arrangement.bindings")?.objectValue ?? [:]).values.first { $0.at(path: "window_id")?.intValue == 12 }
    test.check(spacePartitionsIds(state) == [11, 12, 13, 31, 32] && untouchedBefore == untouchedAfter
        && fixture.partition(state, "B1") == originalB1
        && fixture.partition(state, "A1")?.at(path: "arrangement.segments")?.arrayValue?.contains(where: { $0.at(path: "axis")?.stringValue == "h" }) == true,
        "space-partitions/newcomer-splits-current-manually-enlarged-largest-region-and-isolates-B1")
    state = priorState
    _ = action("resize.start", fixture.world(focus: 31)); _ = action("resize.adjust.east", fixture.world(focus: 31))
    _ = action("resize.off", fixture.world(focus: 31))
    let manualB1 = fixture.partition(state, "B1")
    _ = reconcile(fixture.world(["A1", "B2"], focus: 41))
    test.check(fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "B1") == manualB1
        && spacePartitionsIds(state) == [11, 12, 41, 42], "space-partitions/B1-to-B2-preserves-A1-and-dormant-B1")
    _ = reconcile(fixture.world(focus: 31))
    test.check(spacePartitionsDivider(fixture.partition(state, "B1")) == 1840
        && fixture.partition(state, "B1") == manualB1, "space-partitions/return-to-B1-restores-own-manual-divider")
    for focus: Int64 in [11, 31] {
        let off = reconcile(fixture.world(enabled: ["B1": false], focus: focus))
        test.check((off.status == .accepted || off.status == .noop) && spacePartitionsIds(state) == [11, 12]
            && fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "B1") == manualB1,
            "space-partitions/A-ON-B-OFF-independent-focused-\(focus)")
    }
    _ = reconcile(fixture.world())
    for focus: Int64 in [31, 11] {
        let off = reconcile(fixture.world(enabled: ["A1": false], focus: focus))
        test.check((off.status == .accepted || off.status == .noop) && spacePartitionsIds(state) == [31, 32]
            && fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "B1") == manualB1,
            "space-partitions/A-OFF-B-ON-independent-focused-\(focus)")
    }
    _ = reconcile(fixture.world())
    let empty = reconcile(fixture.world(["Aempty", "B1"], focus: nil))
    test.check(empty.status == .accepted && spacePartitionsIds(state) == [31, 32]
        && fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "Aempty") != nil,
        "space-partitions/identified-empty-Space-without-focus-never-prunes-departed-A1")
    _ = reconcile(fixture.world())
    var missing = fixture.world().objectValue!; missing["complete"] = .bool(false); missing["windows"] = .array([])
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: state, world: .object(missing)), state),
        "space-partitions/missed-incomplete-observation-preserves-checkpoint-with-zero-targets")
    var unknown = fixture.world().objectValue!, contexts = unknown["space_contexts"]!.arrayValue!
    var context = contexts[0].objectValue!; context["space_identity_available"] = .bool(false); context["space_uuid"] = .null
    contexts[0] = .object(context); unknown["space_contexts"] = .array(contexts)
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: state, world: .object(unknown)), state),
        "space-partitions/unknown-actual-identity-cannot-prune-or-resurrect")
    let bothOff = reconcile(fixture.world(enabled: ["A1": false, "B1": false], focus: nil))
    test.check(bothOff.status == .accepted && spacePartitionsIds(state).isEmpty && bothOff.targets == .object([:])
        && fixture.partition(state, "A1") == manualA1 && fixture.partition(state, "B1") == manualB1,
        "space-partitions/all-OFF-is-zero-effects-with-both-arrangements-dormant")
    _ = reconcile(fixture.world())
    let reusedWorld = fixture.world(lifetimes: [11: 2])
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "resize.start", state: state, world: reusedWorld), state),
        "space-partitions/reused-window-id-lifetime-refuses-command-with-zero-mutation")
    let reuse = reconcile(reusedWorld)
    test.check(reuse.status == .accepted && spacePartitionsIds(state) == [11, 12, 31, 32]
        && fixture.partition(state, "A1")?.at(path: "window_identities.11.window_generation")?.intValue == 2
        && fixture.partition(state, "B1") == manualB1 && fixture.partition(state, "A1") != manualA1,
        "space-partitions/reused-id-is-reclaimed-and-reinserted-as-deterministic-newcomer")
    let restoredEpoch = reconcile(fixture.world(epoch: "fixture-windowserver-epoch-2"))
    test.check(restoredEpoch.status == .accepted && spacePartitionsDivider(fixture.partition(state, "A1")) == 600
        && spacePartitionsDivider(fixture.partition(state, "B1")) == 1800,
        "space-partitions/checkpoint-new-observer-epoch-never-replays-old-manual-frames")
    state = .object([:]); _ = reconcile(fixture.world())
    _ = action("resize.start", fixture.world()); _ = action("resize.adjust.east", fixture.world()); _ = action("resize.off", fixture.world())
    _ = reconcile(fixture.world(["A2", "B1"], focus: 21))
    let unchangedB = fixture.partition(state, "B1")
    _ = reconcile(fixture.world(removed: [12]))
    test.check(spacePartitionsIds(state) == [11, 31, 32] && fixture.partition(state, "B1") == unchangedB
        && fixture.partition(state, "A1")?.at(path: "window_identities.12") == nil,
        "space-partitions/fresh-return-membership-prunes-only-genuinely-removed-window")
    runSpacePartitionCrossDisplayScenarios(fixture: fixture, test: &test)
    runSpacePartitionRefusalScenarios(fixture: fixture, test: &test)
    runSpacePartitionInteractionIsolationScenarios(fixture: fixture, test: &test)
    runRecursiveSpacePartitionScenarios(fixture: fixture, test: &test)
    return test.finish("space-partitions")
}

private func runSpacePartitionInteractionIsolationScenarios(fixture: SpacePartitionsFixture, test: inout SelfTest) {
    let world = fixture.world(), initial = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world).state
    for mode in ["resize", "move"] {
        for focus: Int64 in [11, 31] {
            var held = ResidentPlanner.plan(actionID: mode + ".start", state: initial, world: world).state
            if mode == "move" {
                held = ResidentPlanner.plan(actionID: "move.cursor.east", state: held, world: world).state
                held = ResidentPlanner.plan(actionID: "move.drop", state: held, world: world).state
            }
            let originalInteraction = held.at(path: "interaction"), originalA = fixture.partition(held, "A1")
            var offWorld = fixture.world(enabled: ["B1": false], focus: focus).objectValue!
            offWorld["mode"] = .string(mode)
            offWorld["observer_generation"] = .int(9)
            let off = ResidentPlanner.plan(actionID: "world.reconcile", state: held, world: .object(offWorld))
            var expectedOff = originalInteraction?.objectValue ?? [:]; expectedOff["observer_generation"] = .int(9)
            expectedOff.removeValue(forKey: "candidate")
            var actualOff = off.state.at(path: "interaction")?.objectValue ?? [:]; actualOff.removeValue(forKey: "candidate")
            test.check(off.status == .accepted && actualOff == expectedOff
                && fixture.partition(off.state, "A1") == originalA && spacePartitionsIds(off.state) == [11, 12],
                "space-partitions/held-A-\(mode)-B-OFF-preserves-participants-focused-\(focus)")
            var onWorld = fixture.world(focus: focus).objectValue!
            onWorld["mode"] = .string(mode)
            onWorld["observer_generation"] = .int(10); onWorld["topology_revision"] = .int(5)
            let on = ResidentPlanner.plan(actionID: "world.reconcile", state: off.state, world: .object(onWorld))
            var expectedOn = expectedOff; expectedOn["observer_generation"] = .int(10); expectedOn["topology_revision"] = .int(5)
            var actualOn = on.state.at(path: "interaction")?.objectValue ?? [:]; actualOn.removeValue(forKey: "candidate")
            test.check(on.status == .accepted && actualOn == expectedOn
                && fixture.partition(on.state, "A1") == originalA && spacePartitionsIds(on.state) == [11, 12, 31, 32],
                "space-partitions/held-A-\(mode)-B-ON-preserves-participants-focused-\(focus)")
            if mode == "move" {
                let candidate = on.state.at(path: "interaction.candidate") ?? .null
                test.check(MoveCandidate.isCurrent(candidate: candidate, state: on.state, world: .object(onWorld))
                    && candidate.at(path: "base.arrangement") == on.state.at(path: "arrangement")
                    && candidate.at(path: "targets.11.frame") == originalInteraction?.at(path: "candidate.targets.11.frame"),
                    "space-partitions/unrelated-Space-change-refreshes-composite-preview-without-changing-source-draft-focused-\(focus)")
            }
        }
    }
    let resize = ResidentPlanner.plan(actionID: "resize.start", state: initial, world: world).state
    for mode: JSONValue? in [nil, .string("default")] {
        var released = fixture.world().objectValue!
        released["mode"] = mode
        released["observer_generation"] = .int(9)
        let retired = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: .object(released))
        test.check(retired.status == .accepted && retired.state.at(path: "interaction") == nil
            && retired.state.at(path: "arrangement") == resize.at(path: "arrangement")
            && spacePartitionsIds(retired.state) == spacePartitionsIds(resize),
            "space-partitions/\(mode == nil ? "missing" : "default")-mode-proof-retires-stored-interaction-without-changing-managed-layout")
    }
    let changedSource = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: fixture.world(["A2", "B1"], focus: 21))
    test.check(changedSource.status == .accepted && changedSource.state.at(path: "interaction") == nil,
        "space-partitions/held-resize-changed-source-Space-cancels-interaction")
    let disabledSource = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: fixture.world(enabled: ["A1": false], focus: 31))
    test.check(disabledSource.status == .accepted && disabledSource.state.at(path: "interaction") == nil,
        "space-partitions/held-resize-source-Space-OFF-cancels-interaction")
    let reused = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: fixture.world(lifetimes: [11: 2]))
    test.check(reused.status == .accepted && reused.state.at(path: "interaction") == nil,
        "space-partitions/held-resize-source-lifetime-change-cancels-interaction")
    let groupChanged = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: fixture.world(removed: [12]))
    test.check(groupChanged.status == .accepted && groupChanged.state.at(path: "interaction") == nil,
        "space-partitions/held-resize-neighbour-partition-membership-change-cancels-group")
    let epochChanged = ResidentPlanner.plan(actionID: "world.reconcile", state: resize, world: fixture.world(epoch: "fixture-next-observer-epoch"))
    test.check(epochChanged.status == .accepted && epochChanged.state.at(path: "interaction") == nil,
        "space-partitions/held-resize-observer-epoch-change-cancels-interaction")
    var cross = ResidentPlanner.plan(actionID: "move.start", state: initial, world: world).state
    cross = ResidentPlanner.plan(actionID: "move.cursor.east", state: cross, world: world).state
    cross = ResidentPlanner.plan(actionID: "move.cursor.east", state: cross, world: world).state
    cross = ResidentPlanner.plan(actionID: "move.drop", state: cross, world: world).state
    let targetOff = ResidentPlanner.plan(actionID: "world.reconcile", state: cross, world: fixture.world(enabled: ["B1": false]))
    test.check(targetOff.status == .accepted && targetOff.state.at(path: "interaction") == nil,
        "space-partitions/staged-move-referenced-B-cursor-and-span-OFF-cancels-interaction")
}

private func runSpacePartitionCrossDisplayScenarios(fixture: SpacePartitionsFixture, test: inout SelfTest) {
    let world = fixture.world(), initial = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world).state
    var state = ResidentPlanner.plan(actionID: "move.start", state: initial, world: world).state
    state = ResidentPlanner.plan(actionID: "move.cursor.east", state: state, world: world).state
    state = ResidentPlanner.plan(actionID: "move.cursor.east", state: state, world: world).state
    let swap = ResidentPlanner.plan(actionID: "move.execute.swap", state: state, world: world)
    let aSwap = fixture.partition(swap.state, "A1")?.at(path: "window_identities")?.objectValue?.keys ?? []
    let bSwap = fixture.partition(swap.state, "B1")?.at(path: "window_identities")?.objectValue?.keys ?? []
    test.check(swap.status == .accepted && Set(aSwap) == ["12", "31"] && Set(bSwap) == ["11", "32"]
        && spacePartitionsIds(swap.state) == [11, 12, 31, 32], "space-partitions/visible-display-swap-updates-both-caches-in-one-draft")
    let staged = ResidentPlanner.plan(actionID: "move.drop", state: state, world: world)
    let inserted = ResidentPlanner.plan(actionID: "move.drop", state: staged.state, world: world)
    let aInsert = fixture.partition(inserted.state, "A1")?.at(path: "window_identities")?.objectValue?.keys ?? []
    let bInsert = fixture.partition(inserted.state, "B1")?.at(path: "window_identities")?.objectValue?.keys ?? []
    test.check(inserted.status == .accepted && Set(aInsert) == ["12"] && Set(bInsert) == ["11", "31", "32"]
        && spacePartitionsIds(inserted.state) == [11, 12, 31, 32], "space-partitions/visible-display-insert-reclaims-source-and-caches-destination")
    let loneWorld = fixture.world(removed: [12]), loneInitial = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: loneWorld).state
    var lone = ResidentPlanner.plan(actionID: "move.start", state: loneInitial, world: loneWorld).state
    lone = ResidentPlanner.plan(actionID: "move.cursor.east", state: lone, world: loneWorld).state
    lone = ResidentPlanner.plan(actionID: "move.drop", state: lone, world: loneWorld).state
    let loneInsert = ResidentPlanner.plan(actionID: "move.drop", state: lone, world: loneWorld)
    test.check(loneInsert.status == .accepted && spacePartitionsIds(loneInsert.state) == [11, 31, 32]
        && fixture.partition(loneInsert.state, "A1")?.at(path: "arrangement.bindings")?.objectValue?.isEmpty == true
        && fixture.partition(loneInsert.state, "B1")?.at(path: "window_identities.11") != nil,
        "space-partitions/cross-display-insert-of-sole-source-leaves-empty-identified-partition")
    let offWorld = fixture.world(enabled: ["B1": false])
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "move.execute.swap", state: state, world: offWorld), state),
        "space-partitions/OFF-destination-cannot-commit-staged-cross-display-work")
    let switched = fixture.world(["A1", "B2"])
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "move.execute.swap", state: state, world: switched), state),
        "space-partitions/inactive-destination-cannot-commit-staged-cross-display-work")
}

private func runSpacePartitionRefusalScenarios(fixture: SpacePartitionsFixture, test: inout SelfTest) {
    let world = fixture.world(), baseline = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world).state
    var crowded = world.objectValue!, windows = crowded["windows"]!.arrayValue!
    var first = windows[0].objectValue!; first["min_size"] = .object(["w": .int(1300), "h": .int(900)])
    windows[0] = .object(first); crowded["windows"] = .array(windows)
    let overload = ResidentPlanner.plan(actionID: "world.reconcile", state: baseline, world: .object(crowded))
    test.check(overload.status == .accepted && spacePartitionsIds(overload.state) == [11, 12, 31, 32]
        && fixture.partition(overload.state, "A1")?.at(path: "arrangement.bindings.1:0:0.minimum_fit") == .string("unavoidable")
        && fixture.partition(overload.state, "B1") == fixture.partition(baseline, "B1"),
        "space-partitions/automatic-unavoidable-floor-keeps-every-identity-managed-and-unrelated-partition-exact")
    var nested = baseline.objectValue!, cache = nested["space_partitions"]!.objectValue!, parts = cache["partitions"]!.objectValue!
    var part = parts[fixture.partitionKey("A1")]!.objectValue!, arr = part["arrangement"]!.objectValue!, bindings = arr["bindings"]!.objectValue!
    var binding = bindings["1:0:0"]!.objectValue!; binding["nested"] = .object(["segments": .array([])])
    bindings["1:0:0"] = .object(binding); arr["bindings"] = .object(bindings); part["arrangement"] = .object(arr)
    parts[fixture.partitionKey("A1")] = .object(part); cache["partitions"] = .object(parts); nested["space_partitions"] = .object(cache)
    let nestedState = JSONValue.object(nested)
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: nestedState, world: world), nestedState),
        "space-partitions/nested-shape-refusal-never-flattens-or-drops-members")
    var duplicate = world.objectValue!; duplicate["windows"] = .array(world.at(path: "windows")!.arrayValue! + [world.at(path: "windows")!.arrayValue![0]])
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: baseline, world: .object(duplicate)), baseline),
        "space-partitions/ambiguous-duplicate-identity-refuses-whole-draft")
    var stale = world.objectValue!; windows = stale["windows"]!.arrayValue!; first = windows[0].objectValue!
    first["space_uuid"] = fixture.space("A2").at(path: "space_uuid"); windows[0] = .object(first); stale["windows"] = .array(windows)
    test.check(spacePartitionsRefusesUnchanged(ResidentPlanner.plan(actionID: "world.reconcile", state: baseline, world: .object(stale)), baseline),
        "space-partitions/stale-actual-membership-refuses-whole-draft")
}

private func runRecursiveSpacePartitionScenarios(fixture: SpacePartitionsFixture, test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/space_partitions/recursive_allocations.json"
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data),
          let variants = value.at(path: "variants")?.objectValue else { test.check(false, "space-partitions/recursive-fixture-load"); return }
    let world = fixture.world(), baseline = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world).state
    let expected = Set(value.at(path: "expected_managed_ids")!.arrayValue!.compactMap(\.intValue))
    for (name, arrangement) in variants {
        var state = baseline.objectValue!, cache = state["space_partitions"]!.objectValue!, parts = cache["partitions"]!.objectValue!
        var part = parts[fixture.partitionKey("A1")]!.objectValue!
        part["arrangement"] = Arrangement.bridgeArrangementNative(store: arrangement, topo: fixture.topology)
        parts[fixture.partitionKey("A1")] = .object(part); cache["partitions"] = .object(parts); state["space_partitions"] = .object(cache)
        let checkpoint = JSONValue.object(state)
        let restored = ResidentPlanner.plan(actionID: "world.reconcile", state: checkpoint, world: world)
        test.check(restored.status == .accepted && spacePartitionsIds(restored.state) == expected
            && fixture.partition(restored.state, "A1")?.at(path: "window_identities")?.objectValue?.count == 2,
            "space-partitions/\(name)-recovery-composition-conserves-hidden-and-recursive-members-with-exact-identities")
        let managedPart = fixture.partition(restored.state, "A1")?.at(path: "arrangement") ?? .null
        test.check(name == "nested" ? managedPart.at(path: "bindings.1:0:0.nested") != nil
            : managedPart.at(path: "bindings.1:0:0.contents")?.arrayValue?.count == 2,
            "space-partitions/\(name)-checkpoint-keeps-original-structure")
        let select = ResidentPlanner.plan(actionID: "window.select", state: restored.state, world: world,
            arguments: .object(["window_id": .int(12)]))
        test.check(select.status == .accepted && select.focusTarget == 12 && spacePartitionsIds(select.state) == expected
            && select.targets.at(path: "12.presented") == .bool(true), "space-partitions/\(name)-direct-member-command-prepares-and-checkpoints-complete-set")
        let off = ResidentPlanner.plan(actionID: "world.reconcile", state: restored.state, world: fixture.world(enabled: ["B1": false]))
        test.check(off.status == .accepted && spacePartitionsIds(off.state) == [11, 12]
            && fixture.partition(off.state, "B1") == fixture.partition(restored.state, "B1"),
            "space-partitions/\(name)-unrelated-Space-OFF-preserves-dormant-partition-verbatim")
        let on = ResidentPlanner.plan(actionID: "world.reconcile", state: off.state, world: world)
        test.check(on.status == .accepted && spacePartitionsIds(on.state) == expected
            && fixture.partition(on.state, "A1") == fixture.partition(restored.state, "A1"),
            "space-partitions/\(name)-Space-return-keeps-complete-validated-structure")
        let reused = ResidentPlanner.plan(actionID: "world.reconcile", state: restored.state, world: fixture.world(lifetimes: [12: 2]))
        test.check(reused.status == .accepted && spacePartitionsIds(reused.state) == expected
            && fixture.partition(reused.state, "A1")?.at(path: "window_identities.12.window_generation") == .int(2),
            "space-partitions/\(name)-member-lifetime-reuse-retires-old-record-before-new-adoption")
    }
}
