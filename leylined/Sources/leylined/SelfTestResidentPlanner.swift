import Foundation
import LeylineModel

/// The resident plans only over identified visible Spaces. Give a fixture world the same
/// normalized shape: one visible Space per display (the focused display keeps the world's
/// active key) and Space-bound windows with positive lifetimes.
func plannerSpaceWorld(_ world: JSONValue) -> JSONValue {
    guard var value = world.objectValue, let topology = value["topology"] else { return world }
    let displays = Project.normTopology(topology).displays
    let activeKey = value["active_space_key"]?.stringValue ?? "space:fixture"
    let rows = (value["windows"]?.arrayValue ?? []).map { window -> (JSONObject, Int64?) in
        let row = window.objectValue ?? [:]
        return (row, row["display"]?.intValue ?? Frame.from(row["frame"]).flatMap { Geometry.assignDisplay($0, displays) })
    }
    let focusDisplay = rows.first { $0.0["window_id"] == value["focused_window_id"] }?.1 ?? displays.first?.id
    func key(_ display: Int64) -> String { display == focusDisplay ? activeKey : activeKey + "/display:\(display)" }
    value["observer_epoch"] = value["observer_epoch"] ?? .string("planner-fixture-epoch")
    value["space_contexts"] = .array(displays.compactMap(\.id).map { display in .object([
        "display_id": .int(display), "space_uuid": .string("fixture-space-\(display)"), "space_key": .string(key(display)),
        "space_enabled": .bool(true), "space_visible": .bool(true), "space_identity_available": .bool(true)]) })
    value["windows"] = .array(rows.map { row, display in
        guard let display, let id = row["window_id"]?.intValue else { return .object(row) }
        var bound = row
        bound["display"] = .int(display); bound["display_id"] = .int(display)
        bound["space_uuid"] = .string("fixture-space-\(display)"); bound["space_key"] = .string(key(display))
        bound["space_enabled"] = row["space_enabled"] ?? .bool(true)
        bound["space_visible"] = .bool(true); bound["space_identity_available"] = .bool(true)
        bound["pid"] = row["pid"] ?? .int(500 + id); bound["window_generation"] = row["window_generation"] ?? .int(1)
        return .object(bound)
    })
    return .object(value)
}

/// Checkpoint a fixture arrangement for the world's Spaces through the production writer,
/// exactly as a previously accepted plan would have saved it.
func plannerSpaceState(_ state: JSONValue, world: JSONValue) -> JSONValue {
    let observed = world.at(path: "windows")?.arrayValue ?? []
    guard var value = state.objectValue, let arrangement = value["arrangement"],
          let topology = world.at(path: "topology"),
          case .success(let live) = ResidentSpacePartitions.observedContexts(world: world, topology: topology, observed: observed) else {
        return state
    }
    let prepared = ResidentSpacePartitions.Prepared(contexts: live.contexts, topology: topology, epoch: live.epoch,
        observed: observed, arrangement: arrangement, partitions: [:], priorVisible: nil)
    value["space_partitions"] = prepared.checkpoint(arrangement: arrangement) ?? .null
    return .object(value)
}

private struct NativeLayoutFixture {
    let value: JSONValue
    var topology: JSONValue { value.at(path: "topology")! }
    func scene(_ name: String) -> JSONValue { value.at(path: "scenes.\(name)")! }
    func arrangement(_ name: String) -> JSONValue { Arrangement.bridgeArrangementNative(store: scene(name), topo: topology) }
    func state(_ name: String) -> JSONValue { plannerSpaceState(.object(["arrangement": arrangement(name)]), world: world(name)) }
    func world(_ name: String, focus: Int64? = nil) -> JSONValue {
        let arrangement = arrangement(name)
        var world = value.at(path: "world_context")!.objectValue!
        world["topology"] = topology
        world["focused_window_id"] = focus.map(JSONValue.int) ?? scene(name).at(path: "focus") ?? world["focused_window_id"]
        world["windows"] = .array(Arrangement.allocatedCells(arrangement, topo: topology).flatMap { cell in
            cell.memberIDs.map { id in .object(["window_id": .int(id), "pid": .int(500 + id), "window_generation": .int(1),
                "frame": cell.frame.json, "role": .string("AXWindow"), "subrole": .string("AXStandardWindow"),
                "resizable": .bool(true), "eligible": .bool(true)]) }
        })
        return plannerSpaceWorld(.object(world))
    }
    func minimums(_ name: String) -> [Int64: JSONValue] {
        Dictionary(uniqueKeysWithValues: (scene(name).at(path: "newcomer_minimums")?.objectValue ?? [:]).compactMap { key, value in
            Int64(key).map { ($0, value) }
        })
    }
    func framesMatch(_ arrangement: JSONValue?, expected: JSONValue?) -> Bool {
        guard let arrangement, let frames = expected?.objectValue else { return false }
        let targets = Arrangement.arrangementTargetsRec(bridge: arrangement, topo: topology)
        return frames.allSatisfy { id, frame in targets.at(path: "\(id).frame") == Frame.from(frame)?.json }
    }
    func stagedState(_ name: String, source: Int64, target: Int64, edge: String) -> JSONValue {
        let world = world(name, focus: source), state = state(name)
        let started = ResidentPlanner.plan(actionID: "move.start", state: state, world: world)
        var result = started.state.objectValue ?? state.objectValue!
        var interaction = started.state.at(path: "interaction")?.objectValue ?? ["mode": .string("move"),
            "source_window_id": .int(source), "active_space_key": world.at(path: "active_space_key")!,
            "observer_generation": world.at(path: "observer_generation")!, "topology_revision": world.at(path: "topology_revision")!]
        interaction["cursor_window_id"] = .int(target)
        let cell = Arrangement.allocatedCells(arrangement(name), topo: topology).first { $0.topWindowID == target }!
        let selection = ResidentPlanner.selection(cell: cell, cursorID: target, edge: edge)
        interaction["selection"] = selection; interaction["staged_edge"] = .string(edge)
        interaction["span_window_ids"] = .array([.int(target)]); interaction["selection_history"] = .array([])
        interaction["candidate"] = ResidentPlanner.makeCandidate(operation: "insert", arrangement: arrangement(name),
            sourceID: source, targetID: target, selection: selection, topology: topology, state: state, world: world)
        result["interaction"] = .object(interaction)
        return .object(result)
    }
}

/// Independent frozen geometry covers the accepted native author and actual planner.
/// No expected frame is generated by the implementation under test.
func runResidentPlannerCompletionScenarios(tests: inout SelfTest) {
    runThreeWindowBottomGuidanceScenarios(tests: &tests)
    runResizeIdentityScenario(tests: &tests)
    runMinimumOverlapScenarios(tests: &tests)
    runSplitCutReclaimScenarios(tests: &tests)
    runRowColumnRootInsertScenarios(tests: &tests)
    let path = SelfTestFixtures.path("planner/native_layout_contract.json")
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data) else {
        tests.check(false, "planner-completion/fixture-load"); return
    }
    let fixture = NativeLayoutFixture(value: value), topology = fixture.topology
    tests.check(value.at(path: "scenes")?.objectValue?.count == 10, "planner-completion/ten-independent-frozen-scenes")
    func adopt(_ name: String) -> JSONValue {
        Arrangement.bridgeArrangementNativeAdopt(store: fixture.arrangement(name),
            newcomers: (fixture.scene(name).at(path: "newcomers")?.arrayValue ?? []).compactMap(\.intValue), ndid: 1,
            focused: .null, topo: topology, newcomerMinimums: fixture.minimums(name))
    }
    let constrained = adopt("constrained")
    tests.check(fixture.framesMatch(constrained, expected: fixture.scene("constrained").at(path: "expected_frames")),
        "planner-completion/common-cut-projects-midpoint-to-seven-hundred-known-minimum")
    tests.check(Arrangement.allocationValid(constrained, topo: topology), "planner-completion/constrained-cut-retains-valid-complete-partition")
    let overloaded = adopt("overload"), expectedMembers = fixture.scene("overload").at(path: "expected_member_ids")!.arrayValue!.compactMap(\.intValue)
    tests.check(Arrangement.allocatedWindowIDs(overloaded, topo: topology) == expectedMembers,
        "planner-completion/automatic-empty-interval-conserves-all-managed-members-in-one-overload-leaf")
    let overloadedTargets = Arrangement.arrangementTargetsRec(bridge: overloaded, topo: topology)
    tests.check(overloadedTargets.at(path: "2.presented") == .bool(false) && overloadedTargets.at(path: "2.frame") == .null,
        "planner-completion/overload-surplus-has-explicit-hidden-presentation")
    tests.check(overloadedTargets.at(path: "2.effect_frame") == Frame.from(fixture.scene("overload").at(path: "expected_frame"))?.json
        && overloadedTargets.at(path: "2.effect_frame") == overloadedTargets.at(path: "1.effect_frame")
        && overloadedTargets.at(path: "2.stack_top_window_id") == .int(1),
        "planner-completion/every-stack-member-has-identical-canonical-physical-footprint-and-front-identity")
    let selected = Arrangement.selectingMember(store: overloaded, windowID: 2, topo: topology)
    tests.check(selected.map { Arrangement.allocatedWindowIDs($0, topo: topology) } == [2, 1]
        && selected?.at(path: "bindings.1:0:0.window_id") == fixture.scene("overload").at(path: "expected_selected_top"),
        "planner-completion/direct-member-selection-retains-other-managed-member")
    tests.check(selected?.at(path: "bindings.1:0:0.contents")?.arrayValue?.last?.at(path: "min_size.w") == .int(600),
        "planner-completion/direct-member-selection-retains-hidden-member-known-floor")
    var overloadWorld = fixture.world("overload").objectValue!, incoming = overloadWorld["windows"]!.arrayValue![0].objectValue!
    incoming["window_id"] = .int(2); incoming["pid"] = .int(502); incoming["min_size"] = fixture.minimums("overload")[2]
    overloadWorld["windows"] = .array(overloadWorld["windows"]!.arrayValue! + [.object(incoming)])
    let settledOverload = ResidentPlanner.plan(actionID: "world.reconcile", state: fixture.state("overload"), world: .object(overloadWorld))
    tests.check(settledOverload.status == .accepted && settledOverload.targets.objectValue?.count == 2,
        "planner-completion/resident-settle-keeps-overload-newcomer-managed")
    let memberPlan = ResidentPlanner.plan(actionID: "window.select", state: settledOverload.state, world: .object(overloadWorld),
        arguments: .object(["window_id": .int(2)]))
    tests.check(memberPlan.status == .accepted && memberPlan.focusTarget == 2 && memberPlan.targets.at(path: "2.presented") == .bool(true),
        "planner-completion/direct-member-command-reveals-and-focuses-exact-member")
    let nested = adopt("nested")
    tests.check(fixture.framesMatch(nested, expected: fixture.scene("nested").at(path: "expected_frames")),
        "planner-completion/largest-first-inserts-into-largest-recursive-cell-with-stable-ties")
    tests.check(Arrangement.allocationValid(nested, topo: topology)
        && Arrangement.allocatedCells(nested, topo: topology).allSatisfy { $0.displayID == 1 }
        && nested.at(path: "bindings.1:0:0.nested") != nil, "planner-completion/nested-author-preserves-parcel-ownership-and-physical-display")
    let parentEdge = fixture.stagedState("nested", source: 13, target: 11, edge: "east")
    let run = ResidentPlanner.plan(actionID: "move.level.up", state: parentEdge, world: fixture.world("nested"))
    let parent = ResidentPlanner.plan(actionID: "move.level.up", state: run.state, world: fixture.world("nested"))
    tests.check(run.status == .accepted && run.state.at(path: "interaction.selection.ordered_window_ids") == .array([.int(11), .int(12)]),
        "planner-completion/first-up-selects-geometrically-contiguous-run")
    tests.check(parent.status == .accepted && parent.state.at(path: "interaction.selection.scope") == .string("parent")
        && parent.state.at(path: "interaction.selection.boundary.owner_path") == .array([])
        && parent.state.at(path: "interaction.selection.parcel_path") == .array([.string("1:0:0")]),
        "planner-completion/second-up-selects-one-actual-parent-owned-boundary")
    tests.check(fixture.framesMatch(parent.state.at(path: "interaction.candidate.desired_arrangement"),
        expected: fixture.scene("nested").at(path: "expected_parent_frames")), "planner-completion/parent-insertion-preserves-nested-descendants-and-source-span")
    let parentCommit = ResidentPlanner.plan(actionID: "move.execute.auto", state: parent.state, world: fixture.world("nested"))
    tests.check(parentCommit.status == .accepted && parentCommit.targets == parent.state.at(path: "interaction.candidate.targets"),
        "planner-completion/parent-preview-and-commit-consume-identical-saved-targets")
    // Once the source leaves, the nested parcel fills the display, so the root places it identically.
    let atRoot = ResidentPlanner.plan(actionID: "move.level.up", state: parent.state, world: fixture.world("nested"))
    tests.check(atRoot.status == .accepted && atRoot.state.at(path: "interaction.selection.parcel_path") == .array([])
        && atRoot.state.at(path: "interaction.selection.boundary.owner_path") == .array([])
        && fixture.framesMatch(atRoot.state.at(path: "interaction.candidate.desired_arrangement"),
            expected: fixture.scene("nested").at(path: "expected_parent_frames")),
        "planner-completion/third-up-selects-the-display-root")
    let pastRoot = ResidentPlanner.plan(actionID: "move.level.up", state: atRoot.state, world: fixture.world("nested"))
    tests.check(pastRoot.status == .noop && pastRoot.state == atRoot.state, "planner-completion/selection-stops-at-that-display-root")
    let downRun = ResidentPlanner.plan(actionID: "move.level.down", state: parent.state, world: fixture.world("nested"))
    let downEdge = ResidentPlanner.plan(actionID: "move.level.down", state: downRun.state, world: fixture.world("nested"))
    tests.check(downRun.state.at(path: "interaction.selection") == run.state.at(path: "interaction.selection")
        && downEdge.state.at(path: "interaction.selection") == parentEdge.at(path: "interaction.selection"),
        "planner-completion/down-restores-each-saved-selection-exactly")
    tests.check(parent.state.at(path: "arrangement") == parentEdge.at(path: "arrangement") && parent.targets == .object([:]),
        "planner-completion/staged-parent-preview-keeps-source-and-authoritative-layout-stationary")
    var staleWorld = fixture.world("nested").objectValue!; staleWorld["observer_generation"] = .int(9)
    let stale = ResidentPlanner.plan(actionID: "move.execute.auto", state: parent.state, world: .object(staleWorld))
    tests.check(stale.status == .refused && stale.state == parent.state && stale.targets == .object([:]),
        "planner-completion/stale-preview-never-commits-or-produces-effects")
    let replacement = ResidentPlanner.replacementMoveCandidate(state: parent.state, world: .object(staleWorld))
    tests.check(replacement.status == .accepted && replacement.targets == .object([:])
        && replacement.state.at(path: "interaction.candidate.base.observer_generation") == .int(9),
        "planner-completion/stale-intent-produces-fresh-preview-without-committing")
    var changedFocusWorld = fixture.world("nested").objectValue!; changedFocusWorld["focused_window_id"] = .int(12)
    let pinnedSource = ResidentPlanner.plan(actionID: "move.execute.auto", state: parent.state, world: .object(changedFocusWorld))
    tests.check(pinnedSource.status == .accepted && pinnedSource.targets.at(path: "13.frame") == Frame.from(fixture.scene("nested").at(path: "expected_parent_source_frame"))?.json,
        "planner-completion/unrelated-focus-change-cannot-retarget-captured-source")
    let walkEdge = fixture.stagedState("walk", source: 1, target: 20, edge: "west"), walkWorld = fixture.world("walk")
    let middle = ResidentPlanner.plan(actionID: "move.cursor.south", state: walkEdge, world: walkWorld)
    let bottom = ResidentPlanner.plan(actionID: "move.cursor.south", state: middle.state, world: walkWorld)
    let end = ResidentPlanner.plan(actionID: "move.cursor.south", state: bottom.state, world: walkWorld)
    let perpendicular = ResidentPlanner.plan(actionID: "move.cursor.east", state: middle.state, world: walkWorld)
    tests.check(middle.state.at(path: "interaction.cursor_window_id") == .int(7) && bottom.state.at(path: "interaction.cursor_window_id") == .int(13),
        "planner-completion/staged-edge-walk-follows-geometric-order-rather-than-id-order")
    tests.check(end.status == .noop && end.state == bottom.state && perpendicular.status == .noop && perpendicular.state == middle.state,
        "planner-completion/staged-edge-end-and-perpendicular-keys-do-not-wrap")
    let fullRun = ResidentPlanner.plan(actionID: "move.level.up", state: middle.state, world: walkWorld)
    tests.check(fullRun.state.at(path: "interaction.selection.ordered_window_ids") == fixture.scene("walk").at(path: "expected_order")
        && fixture.framesMatch(fullRun.state.at(path: "interaction.candidate.desired_arrangement"), expected: fixture.scene("walk").at(path: "expected_run_frames")),
        "planner-completion/full-contiguous-run-uses-one-exact-shared-cut")
    let runCursor = ResidentPlanner.plan(actionID: "move.cursor.south", state: fullRun.state, world: walkWorld)
    tests.check(runCursor.state.at(path: "interaction.cursor_window_id") == .int(13)
        && runCursor.state.at(path: "interaction.candidate.targets") == fullRun.state.at(path: "interaction.candidate.targets")
        && runCursor.state.at(path: "interaction.selection.anchor_window_id") == fullRun.state.at(path: "interaction.selection.anchor_window_id"),
        "planner-completion/run-cursor-walk-keeps-selection-anchor-and-preview-allocation-fixed")
    let disconnected = fixture.arrangement("disconnected"), disconnectedCells = Arrangement.allocatedCells(disconnected, topo: topology)
    let disconnectedCursor = disconnectedCells.first { $0.topWindowID == 20 }!
    tests.check(ResidentPlanner.edgeRun(cursor: disconnectedCursor, cells: disconnectedCells, edge: "west").compactMap(\.topWindowID)
        == fixture.scene("disconnected").at(path: "expected_order")!.arrayValue!.compactMap(\.intValue),
        "planner-completion/same-coordinate-disconnected-boundaries-do-not-form-one-run")
    let selfEdge = fixture.stagedState("walk", source: 7, target: 20, edge: "west")
    let selfRun = ResidentPlanner.plan(actionID: "move.level.up", state: selfEdge, world: fixture.world("walk", focus: 7))
    tests.check(selfRun.state.at(path: "interaction.selection.ordered_window_ids") == fixture.scene("walk").at(path: "expected_order")
        && selfRun.state.at(path: "interaction.candidate.ordered_participant_window_ids") == .array([.int(20), .int(13)])
        && fixture.framesMatch(selfRun.state.at(path: "interaction.candidate.desired_arrangement"), expected: fixture.scene("walk").at(path: "expected_self_span_frames")),
        "planner-completion/source-in-span-is-carved-out-after-vacancy-with-survivor-order-conserved")
    let unequal = fixture.arrangement("unequal_depth_run"), unequalCells = Arrangement.allocatedCells(unequal, topo: topology)
    let unequalCursor = unequalCells.first { $0.topWindowID == 20 }!
    var unequalSelection = ResidentPlanner.selection(cell: unequalCursor, cursorID: 20, edge: "east").objectValue!
    unequalSelection["scope"] = .string("run"); unequalSelection["ordered_window_ids"] = fixture.scene("unequal_depth_run").at(path: "expected_east_order")
    let unequalInsert = ResidentPlanner.insert(arrangement: unequal, topology: topology, sourceID: 1, selection: .object(unequalSelection))
    tests.check(fixture.framesMatch(unequalInsert, expected: fixture.scene("unequal_depth_run").at(path: "expected_frames")),
        "planner-completion/unequal-depth-edge-run-projects-one-common-cut-to-all-known-floors")
    let resizeState = fixture.state("resize_face"), resizeWorld = fixture.world("resize_face")
    let resizeStart = ResidentPlanner.plan(actionID: "resize.start", state: resizeState, world: resizeWorld)
    let east = ResidentPlanner.plan(actionID: "resize.adjust.east", state: resizeStart.state, world: resizeWorld)
    let west = ResidentPlanner.plan(actionID: "resize.adjust.west", state: resizeStart.state, world: resizeWorld)
    tests.check(east.targets.at(path: "2.frame") == Frame.from(fixture.scene("resize_face").at(path: "expected_east_frame"))?.json,
        "planner-completion/display-boundary-resize-uses-opposite-interior-face-with-same-sign")
    tests.check(west.targets.at(path: "2.frame") == Frame.from(fixture.scene("resize_face").at(path: "expected_west_frame"))?.json,
        "planner-completion/preferred-interior-face-retains-exact-forty-point-translation")
    let constraintWorld = fixture.world("resize_constraint")
    let constraintStart = ResidentPlanner.plan(actionID: "resize.start", state: fixture.state("resize_constraint"), world: constraintWorld)
    let clamped = ResidentPlanner.plan(actionID: "resize.adjust.east", state: constraintStart.state, world: constraintWorld)
    tests.check(clamped.targets.at(path: "1.frame") == Frame.from(fixture.scene("resize_constraint").at(path: "expected_source_frame"))?.json
        && clamped.targets.at(path: "2.frame") == Frame.from(fixture.scene("resize_constraint").at(path: "expected_target_frame"))?.json,
        "planner-completion/resize-pulse-clamps-at-exact-known-minimum")
    let blocked = ResidentPlanner.plan(actionID: "move.start", state: fixture.state("empty_interval"), world: fixture.world("empty_interval"))
    tests.check(blocked.status == .refused && blocked.reason == "nothing_to_move_to" && blocked.targets == .object([:]),
        "planner-completion/useful-entry-tests-legal-destinations-rather-than-window-count")
    let impossible = fixture.stagedState("empty_interval", source: 1, target: 2, edge: "west")
    let impossibleRefresh = ResidentPlanner.replacementMoveCandidate(state: impossible, world: fixture.world("empty_interval"))
    tests.check(impossibleRefresh.status == .refused && impossibleRefresh.state == impossible && impossibleRefresh.targets == .object([:]),
        "planner-completion/manual-empty-minimum-interval-refuses-atomically")
    var pendingWorld = walkWorld.objectValue!; pendingWorld["complete"] = .bool(false)
    let pending = ResidentPlanner.plan(actionID: "move.start", state: fixture.state("walk"), world: .object(pendingWorld))
    tests.check(pending.status == .refused && pending.reason == "world_incomplete", "planner-completion/pending-world-is-distinct-from-known-useless-entry")
    let accelerated = ResidentPlanner.plan(actionID: "resize.adjust.west", state: resizeStart.state, world: resizeWorld,
        arguments: .object(["step": .int(80)]))
    tests.check(accelerated.status == .refused && accelerated.state == resizeStart.state, "planner-completion/resize-step-cannot-be-accelerated-through-arguments")
    var growthWorld = resizeWorld.objectValue!, growthWindows = resizeWorld.at(path: "windows")!.arrayValue!
    var growing = growthWindows[1].objectValue!; growing["min_size"] = .object(["w": .int(500)])
    growthWindows[1] = .object(growing); growthWorld["windows"] = .array(growthWindows)
    let growth = ResidentPlanner.plan(actionID: "world.reconcile", state: resizeState, world: .object(growthWorld))
    let recutFrames: JSONValue = .object(["1": fixture.scene("resize_face").at(path: "expected_recut_sibling_frame")!,
                                          "2": fixture.scene("resize_face").at(path: "expected_recut_frame")!])
    tests.check(growth.status == .accepted && Arrangement.memberWindows(growth.state.at(path: "arrangement")!).count == 2
        && growth.targets.at(path: "2.frame") == Frame.from(recutFrames.at(path: "2"))?.json
        && growth.targets.at(path: "1.frame") == Frame.from(recutFrames.at(path: "1"))?.json
        && growth.targets.at(path: "1.presented") == .bool(true),
        "planner-completion/discovered-minimum-moves-the-shared-line-to-make-room")
    tests.check(Arrangement.parseSegs(growth.state.at(path: "arrangement.segments")).count == 1
        && Arrangement.allocatedCells(growth.state.at(path: "arrangement")!, topo: topology).allSatisfy {
            $0.memberIDs.count == 1 && $0.binding.at(path: "minimum_fit") == nil },
        "planner-completion/minimum-recut-keeps-the-partition-without-overlap-or-stacking")
    growing["min_size"] = .object(["w": .int(200)]); growthWindows[1] = .object(growing); growthWorld["windows"] = .array(growthWindows)
    let relaxed = ResidentPlanner.plan(actionID: "world.reconcile", state: growth.state, world: .object(growthWorld))
    tests.check([.accepted, .noop].contains(relaxed.status)
        && fixture.framesMatch(relaxed.state.at(path: "arrangement"), expected: recutFrames),
        "planner-completion/known-floor-reduction-keeps-the-recut-line-like-a-resize")
    growing["min_size"] = .object(["w": .int(1300)]); growthWindows[1] = .object(growing); growthWorld["windows"] = .array(growthWindows)
    let unavoidable = ResidentPlanner.plan(actionID: "world.reconcile", state: resizeState, world: .object(growthWorld))
    tests.check(unavoidable.status == .accepted && unavoidable.state.at(path: "arrangement.bindings.1:0:0.minimum_fit") == .string("unavoidable")
        && Arrangement.memberWindows(unavoidable.state.at(path: "arrangement")!).count == 2,
        "planner-completion/minimum-larger-than-display-is-explicit-and-never-ejects-managed-member")
    var closedState = resizeState.objectValue!; closedState["confirmed_focus_window_id"] = .int(2)
    closedState["focus_history"] = .array([.object(["window_id": .int(2), "pid": .int(502), "window_generation": .int(1)]),
        .object(["window_id": .int(1), "pid": .int(501), "window_generation": .int(1)])])
    var closedWorld = resizeWorld.objectValue!; closedWorld["windows"] = .array([resizeWorld.at(path: "windows")!.arrayValue![0]])
    closedWorld["focused_window_id"] = .null
    let closed = ResidentPlanner.plan(actionID: "window.destroyed", state: .object(closedState), world: .object(closedWorld))
    tests.check(closed.status == .accepted && closed.focusTarget == 1, "planner-completion/close-refocus-prefers-proven-unique-absorber")
    var historyState = fixture.state("walk").objectValue!; historyState["confirmed_focus_window_id"] = .int(7)
    historyState["focus_history"] = .array([.object(["window_id": .int(20), "pid": .int(520), "window_generation": .int(99)]),
        .object(["window_id": .int(13), "pid": .int(513), "window_generation": .int(1)])])
    var historyWorld = fixture.world("walk", focus: 7).objectValue!
    historyWorld["windows"] = .array(historyWorld["windows"]!.arrayValue!.filter { $0.at(path: "window_id")?.intValue != 7 })
    historyWorld["focused_window_id"] = .null
    let recent = ResidentPlanner.plan(actionID: "window.destroyed", state: .object(historyState), world: .object(historyWorld))
    tests.check(recent.status == .accepted && recent.focusTarget == 13, "planner-completion/close-with-distributed-reclaim-uses-most-recent-valid-lifetime-history")
    var duplicateWorld = fixture.world("nested").objectValue!
    duplicateWorld["windows"] = .array(duplicateWorld["windows"]!.arrayValue! + [duplicateWorld["windows"]!.arrayValue![0]])
    tests.check(!MoveCandidate.isCurrent(candidate: parent.state.at(path: "interaction.candidate")!, state: parent.state, world: .object(duplicateWorld)),
        "planner-completion/candidate-provenance-rejects-ambiguous-duplicate-window-lifetime")
    let nestedFloorScene = fixture.scene("nested_minimum_reflow"), nestedFloorTopology = nestedFloorScene.at(path: "topology")!
    let nestedFloor = Arrangement.bridgeArrangementNative(store: nestedFloorScene, topo: nestedFloorTopology)
    let nestedFloorCell = Arrangement.allocatedCells(nestedFloor, topo: nestedFloorTopology).first { $0.topWindowID == 11 }!
    var nestedFloorSelection = ResidentPlanner.selection(cell: nestedFloorCell, cursorID: 11, edge: "east").objectValue!
    nestedFloorSelection["scope"] = .string("parent"); nestedFloorSelection["level"] = .int(2)
    nestedFloorSelection["ordered_window_ids"] = nestedFloorScene.at(path: "expected_participants")
    nestedFloorSelection["boundary"] = ResidentPlanner.boundary(frame: nestedFloorCell.canvas, displayID: 1, ownerPath: [], edge: "east")
    let nestedReflow = ResidentPlanner.insert(arrangement: nestedFloor, topology: nestedFloorTopology, sourceID: 13,
        selection: .object(nestedFloorSelection))
    tests.check(fixture.framesMatch(nestedReflow, expected: nestedFloorScene.at(path: "expected_frames")),
        "planner-completion/parent-midpoint-stays-nearest-feasible-while-child-interior-refits-known-minima")
    tests.check(nestedReflow.map { Arrangement.allocationValid($0, topo: nestedFloorTopology) } == true
        && nestedReflow.map { Arrangement.allocatedWindowIDs($0, topo: nestedFloorTopology).sorted() } == [1, 11, 12, 13],
        "planner-completion/nested-minimum-refit-keeps-structural-members-and-exact-gutters")
}

/// A 2x2 whose middle line is two collinear segments. Moving only the right half up puts the
/// bottom-right cell first in y order; each window must still keep its own quadrant.
private func runResizeIdentityScenario(tests: inout SelfTest) {
    let topology = try! JSONValue.parse(Data(#"{"displays":[{"id":1,"frame":{"x":0,"y":0,"w":1920,"h":1243},"usable":{"x":0,"y":38,"w":1920,"h":1205}}],"gap":1,"outer_gap":1}"#.utf8))
    let store = try! JSONValue.parse(Data(#"{"segments":[{"axis":"v","coord":960,"lo":39,"hi":1242},{"axis":"h","coord":640.5,"lo":1,"hi":960},{"axis":"h","coord":640.5,"lo":960,"hi":1919}],"bindings":{"1:0:0":{"window_id":1},"1:1:0":{"window_id":2},"1:0:1":{"window_id":3},"1:1:1":{"window_id":4}},"off_top":[]}"#.utf8))
    let resized = ResidentPlanner.resize(arrangement: Arrangement.bridgeArrangementNative(store: store, topo: topology),
                                         topology: topology, sourceID: 4, direction: .north, step: 40)
    let targets = resized.map { Arrangement.arrangementTargetsRec(bridge: $0, topo: topology) }
    let expected: [Int: Frame] = [1: Frame(x: 1, y: 39, w: 958.5, h: 601), 2: Frame(x: 960.5, y: 39, w: 958.5, h: 561),
                                  3: Frame(x: 1, y: 641, w: 958.5, h: 601), 4: Frame(x: 960.5, y: 601, w: 958.5, h: 641)]
    tests.check(targets.map { targets in expected.allSatisfy { targets.at(path: "\($0.key).frame") == $0.value.json } } == true,
        "planner-completion/resize-that-reorders-cells-keeps-each-window-in-its-own-cell")
}

/// Hand-computed frames: lines move so every known floor fits when some cut does; otherwise a
/// window overlaps only the windows its own cut separates, from the edges it does not share.
/// A cut stored as abutting collinear pieces still reclaims the full-width tile beneath it.
private func runSplitCutReclaimScenarios(tests: inout SelfTest) {
    let path = SelfTestFixtures.path("planner/split-cut-reclaim.json")
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data),
          let topology = value.at(path: "topology"), let store = value.at(path: "store"),
          let goner = value.at(path: "goner")?.intValue, let observed = value.at(path: "observed")?.arrayValue else {
        tests.check(false, "split-cut/fixture-load"); return
    }
    tests.check(Arrangement.allocationValid(store, topo: topology), "split-cut/two-piece-cut-fixture-is-valid-before-planning")
    let pruned = Arrangement.pruneAllocatedWindow(store: store, windowID: goner, topo: topology)?.at(path: "arr")
    let targets = pruned.map { Arrangement.arrangementTargetsRec(bridge: $0, topo: topology) }
    let expected = value.at(path: "expected_prune_frames")?.objectValue ?? [:]
    tests.check(pruned.map { Arrangement.allocationValid($0, topo: topology) } == true && !expected.isEmpty
        && expected.allSatisfy { id, frame in targets?.at(path: "\(id).frame") == Frame.from(frame)?.json },
        "split-cut/full-width-tile-under-two-piece-cut-reclaims-upward-into-every-column")
    func members(_ arrangement: JSONValue?) -> [Int64]? {
        arrangement.map { Arrangement.allocatedWindowIDs($0, topo: topology).sorted() }
    }
    let retired = ResidentPlanner.settle(arrangement: store, observed: Array(observed.prefix(2)), topology: topology, focus: 73)
    tests.check(members(retired) == [73, 2294], "split-cut/settle-retires-both-departed-windows")
    let adopted = ResidentPlanner.settle(arrangement: store, observed: observed, topology: topology, focus: 73)
    tests.check(members(adopted) == [73, 2294, 2545] && adopted.map { Arrangement.allocationValid($0, topo: topology) } == true,
        "split-cut/settle-retires-departed-windows-and-tiles-the-newcomer")
}

/// Sanitized live shape: two windows over one full-width window. Each direction between that and
/// one full-height window beside two stacked windows is one move into the display root, and no
/// move stores a cut as overlapping collinear pieces. Hand-derived frames, rounded to the whole
/// points a commit writes where they come from a plan; gap 1, outer gap 1.
private func runRowColumnRootInsertScenarios(tests: inout SelfTest) {
    let path = SelfTestFixtures.path("planner/row-column-root-insert.json")
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data) else {
        tests.check(false, "row-column/fixture-load"); return
    }
    let fixture = NativeLayoutFixture(value: value), topology = fixture.topology
    func overlapFree(_ arrangement: JSONValue?) -> Bool {
        guard let segments = arrangement?.at(path: "segments").map({ Arrangement.parseSegs($0) }) else { return false }
        return Arrangement.mergingOverlaps(segments).count == segments.count
    }
    func matches(_ targets: JSONValue, _ key: String) -> Bool {
        let expected = value.at(path: key)?.objectValue ?? [:]
        return !expected.isEmpty && expected.allSatisfy { id, frame in targets.at(path: "\(id).frame") == Frame.from(frame)?.json }
    }
    var state = fixture.state("rows"), world = fixture.world("rows", focus: 1)
    func step(_ action: String) -> ResidentPlan {
        let plan = ResidentPlanner.plan(actionID: action, state: state, world: world)
        if plan.status == .accepted { state = plan.state }
        return plan
    }
    func land(_ plan: ResidentPlan, focus: Int64) {
        var observed = world.objectValue!
        observed["focused_window_id"] = .int(focus)
        observed["windows"] = .array(observed["windows"]!.arrayValue!.map { value in
            var row = value.objectValue!
            if let id = row["window_id"]?.intValue, let frame = plan.targets.at(path: "\(id).frame") { row["frame"] = frame }
            return .object(row)
        })
        world = .object(observed)
    }
    // Top-left H: J D U U Return puts it at full height on the left.
    let entered = step("move.start"), down = step("move.cursor.south"), staged = step("move.drop")
    let run = step("move.level.up"), root = step("move.level.up"), pastRoot = step("move.level.up")
    tests.check([entered, down, staged, run, root].allSatisfy { $0.status == .accepted }
        && down.state.at(path: "interaction.cursor_window_id") == .int(3)
        && staged.state.at(path: "interaction.staged_edge") == .string("west")
        && run.state.at(path: "interaction.selection.scope") == .string("run")
        && root.state.at(path: "interaction.selection.scope") == .string("parent")
        && root.state.at(path: "interaction.selection.parcel_path") == .array([])
        && pastRoot.status == .noop && pastRoot.reason == "selection_at_display_root",
        "row-column/flat-root-is-the-owning-parent-one-U-past-the-run")
    let left = step("move.execute.auto")
    tests.check(left.status == .accepted && matches(left.targets, "expected_left_full_frames"),
        "row-column/one-root-insertion-turns-two-rows-into-two-columns")
    let leftArrangement = state.at(path: "arrangement")
    tests.check(overlapFree(leftArrangement) && Arrangement.parseSegs(leftArrangement?.at(path: "segments")).count == 2
        && leftArrangement.map { Arrangement.allocationValid($0, topo: topology) } == true,
        "row-column/root-insertion-stores-one-full-cut-and-one-half-cut")
    // Bottom-right H: H D U U Return puts it back at full width along the bottom.
    land(left, focus: 3)
    let again = step("move.start"), across = step("move.cursor.west"), southEdge = step("move.drop")
    let _ = step("move.level.up"), backRoot = step("move.level.up")
    tests.check([again, across, southEdge, backRoot].allSatisfy { $0.status == .accepted }
        && across.state.at(path: "interaction.cursor_window_id") == .int(1)
        && southEdge.state.at(path: "interaction.staged_edge") == .string("south")
        && backRoot.state.at(path: "interaction.selection.parcel_path") == .array([]),
        "row-column/reverse-gesture-selects-south-of-the-display-root")
    let bottom = step("move.execute.auto")
    tests.check(bottom.status == .accepted && matches(bottom.targets, "expected_bottom_full_frames")
        && overlapFree(state.at(path: "arrangement"))
        && Arrangement.allocatedWindowIDs(state.at(path: "arrangement")!, topo: topology).sorted() == [1, 2, 3],
        "row-column/reverse-root-insertion-restores-two-windows-over-one")

    // A checkpoint that already stores one cut as overlapping pieces still reclaims across it.
    let overlapping = fixture.scene("rows_overlapping_cut")
    let pruned = Arrangement.pruneAllocatedWindow(store: overlapping, windowID: 3, topo: topology)?.at(path: "arr")
    tests.check(pruned.map { matches(Arrangement.arrangementTargetsRec(bridge: $0, topo: topology), "expected_overlapping_prune_frames")
        && Arrangement.allocationValid($0, topo: topology) } == true,
        "row-column/full-width-tile-under-overlapping-cut-pieces-reclaims-upward")
    tests.check(Arrangement.parseSegs(Arrangement.bridgeArrangementNative(store: overlapping, topo: topology).at(path: "segments")).count == 2,
        "row-column/native-bridge-merges-overlapping-pieces-of-one-cut")

    // An edge insertion beside a full-height window emits that line from both sides.
    let columns = fixture.stagedState("columns", source: 3, target: 2, edge: "south")
    let belowArrangement = columns.at(path: "interaction.candidate.desired_arrangement")
    tests.check(belowArrangement.map { Arrangement.allocationValid($0, topo: topology) } == true && overlapFree(belowArrangement)
        && Arrangement.parseSegs(belowArrangement?.at(path: "segments")).count == 2,
        "row-column/edge-insertion-stores-a-shared-line-once")
    tests.check(belowArrangement.flatMap { Arrangement.pruneAllocatedWindow(store: $0, windowID: 1, topo: topology) } != nil,
        "row-column/closing-the-full-height-window-after-an-edge-insertion-reclaims")
}

private func runMinimumOverlapScenarios(tests: inout SelfTest) {
    let path = SelfTestFixtures.path("planner/minimum_overlap.json")
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data),
          let scenes = value.at(path: "scenes")?.objectValue, scenes.count == 9 else {
        tests.check(false, "minimum-overlap/fixture-required"); return
    }
    for (name, scene) in scenes.sorted(by: { $0.key < $1.key }) {
        let topology = scene.at(path: "topology")!
        let store: JSONValue = .object(["segments": scene.at(path: "segments")!, "bindings": scene.at(path: "bindings")!, "off_top": .array([])])
        guard let resolved = Arrangement.resolvingAutomaticOverload(store: Arrangement.bridgeArrangementNative(store: store, topo: topology),
                                                                     topo: topology, focused: nil) else {
            tests.check(false, "minimum-overlap/\(name)-resolves"); continue
        }
        let targets = Arrangement.arrangementTargetsRec(bridge: resolved, topo: topology)
        let cells = Arrangement.allocatedCells(resolved, topo: topology)
        let overlapping = Set(cells.filter { $0.binding.at(path: "minimum_fit") == .string("overlap") }.compactMap(\.topWindowID))
        let frames = scene.at(path: "expected_frames")?.objectValue ?? [:]
        let framesMatch = !frames.isEmpty && frames.allSatisfy { id, frame in targets.at(path: "\(id).frame") == Frame.from(frame)?.json }
        let sameStructure = Arrangement.parseSegs(resolved.at(path: "segments")).count == (scene.at(path: "segments")?.arrayValue?.count ?? -1)
            && cells.allSatisfy { $0.memberIDs.count == 1 }
        if !frames.isEmpty && !framesMatch {
            print("diagnostic minimum-overlap/\(name) frames=\(JSONValue.object(JSONObject(frames.keys.map { ($0, targets.at(path: "\($0).frame") ?? .null) })).canonical())")
        }
        switch scene.at(path: "expect")?.stringValue {
        case "recut":
            tests.check(framesMatch && sameStructure && overlapping.isEmpty && Arrangement.allocationValid(resolved, topo: topology),
                "minimum-overlap/\(name)-moves-lines-so-every-floor-fits")
        case "overlap":
            let expected = Set((scene.at(path: "expected_overlap")?.arrayValue ?? []).compactMap(\.intValue))
            tests.check(framesMatch && sameStructure && overlapping == expected,
                "minimum-overlap/\(name)-grows-from-unshared-edges-within-its-split")
        case "fallback":
            let members = (scene.at(path: "expected_fallback_members")?.arrayValue ?? []).compactMap(\.intValue)
            tests.check(overlapping.isEmpty && cells.contains { $0.memberIDs.count > 1 }
                && Arrangement.allocatedWindowIDs(resolved, topo: topology).sorted() == members,
                "minimum-overlap/\(name)-with-no-fitting-cut-or-overlap-falls-back-to-overload")
        default:
            tests.check(false, "minimum-overlap/\(name)-declares-expectation")
        }
        if name == "quadrant_pair_tight" {
            func frame(_ arrangement: JSONValue?, _ id: Int) -> JSONValue? {
                arrangement.flatMap { Arrangement.arrangementTargetsRec(bridge: $0, topo: topology).at(path: "\(id).frame") }
            }
            let overlap = Frame(x: 385.5, y: 39, w: 574, h: 601).json
            let unrelated = ResidentPlanner.resize(arrangement: resolved, topology: topology, sourceID: 5, direction: .north, step: 40)
            tests.check(unrelated != nil && unrelated != resolved && frame(unrelated, 2) == overlap
                && frame(unrelated, 5) == Frame(x: 960.5, y: 601, w: 958.5, h: 641).json,
                "minimum-overlap/unrelated-resize-keeps-existing-overlap")
            let roomier = ResidentPlanner.resize(arrangement: resolved, topology: topology, sourceID: 1, direction: .west, step: 40)
            tests.check(frame(roomier, 1) == Frame(x: 1, y: 39, w: 439, h: 601).json && frame(roomier, 2) == overlap,
                "minimum-overlap/resize-may-reduce-overhang-of-the-overlapping-window")
            tests.check(ResidentPlanner.resize(arrangement: resolved, topology: topology, sourceID: 1, direction: .east, step: 40) == resolved,
                "minimum-overlap/resize-never-increases-overhang")
            let lowered = Minsize.stampMinSizesArr(arr: resolved, store: .object(["fixture-2": .object(["w": .int(400)])]),
                observed: [.object(["window_id": .int(2), "app": .string("fixture-2")])], topo: topology)
            let withdrawn = Arrangement.resolvingAutomaticOverload(store: Arrangement.bridgeArrangementNative(store: lowered, topo: topology),
                                                                   topo: topology, focused: nil)
            tests.check(frame(withdrawn, 2) == Frame(x: 481, y: 39, w: 478.5, h: 601).json
                && withdrawn.map { Arrangement.allocatedCells($0, topo: topology).allSatisfy { $0.binding.at(path: "minimum_fit") == nil } } == true,
                "minimum-overlap/known-floor-reduction-withdraws-the-overlap")
        }
    }
    // A restart re-adopts windows in ID order: a newcomer wider than the column it splits is
    // placed by height and left to the re-cut and overlap, rather than stacked with Hosts.
    let topology = try! JSONValue.parse(Data(#"{"displays":[{"id":1,"frame":{"x":0,"y":0,"w":1920,"h":1243},"usable":{"x":0,"y":38,"w":1920,"h":1205}}],"gap":1,"outer_gap":1}"#.utf8))
    let three = try! JSONValue.parse(Data(#"{"segments":[{"axis":"v","coord":960,"lo":39,"hi":1242},{"axis":"h","coord":609.5,"lo":1,"hi":960}],"bindings":{"1:0:0":{"window_id":1},"1:1:0":{"window_id":2},"1:0:1":{"window_id":3,"min_size":{"w":960,"h":632}}},"off_top":[]}"#.utf8))
    let adopted = Arrangement.bridgeArrangementNativeAdopt(store: Arrangement.bridgeArrangementNative(store: three, topo: topology),
        newcomers: [4], ndid: 1, focused: .null, topo: topology, newcomerMinimums: [4: .object(["w": .int(1060), "h": .int(732)])])
    let adoptedTargets = Arrangement.arrangementTargetsRec(bridge: adopted, topo: topology)
    // Before the newcomer, v960 already moved to 961.5 for window 3's 960 points.
    let expectedAdoption: [Int: Frame] = [1: Frame(x: 1, y: 39, w: 960, h: 570), 2: Frame(x: 962, y: 39, w: 957, h: 470),
                                          3: Frame(x: 1, y: 610, w: 960, h: 632), 4: Frame(x: 859, y: 510, w: 1060, h: 732)]
    tests.check(adopted != .null && Arrangement.allocatedCells(adopted, topo: topology).allSatisfy { $0.memberIDs.count == 1 }
        && expectedAdoption.allSatisfy { adoptedTargets.at(path: "\($0.key).frame") == $0.value.json },
        "minimum-overlap/newcomer-wider-than-its-cell-splits-and-overlaps-instead-of-stacking")
}

/// Sanitized left-nested terminals/right browser geometry, including exact one-point borders.
private func runThreeWindowBottomGuidanceScenarios(tests: inout SelfTest) {
    let path = SelfTestFixtures.path("planner/three-window-bottom-guidance.json")
    guard let data = FileManager.default.contents(atPath: path), let value = try? JSONValue.parse(data) else {
        tests.check(false, "guidance/sanitized-fixture-required"); return
    }
    let fixture = NativeLayoutFixture(value: value)
    var state = fixture.state("three"), world = fixture.world("three", focus: 3)
    tests.check(Arrangement.allocationValid(fixture.scene("three"), topo: fixture.topology)
        && Arrangement.allocationValid(state.at(path: "arrangement")!, topo: fixture.topology),
        "guidance/inset-boundary-three-window-fixture-is-valid-before-planning")
    func step(_ action: String) -> ResidentPlan {
        let plan = ResidentPlanner.plan(actionID: action, state: state, world: world)
        if plan.status == .accepted { state = plan.state }
        return plan
    }
    let entered = step("move.start"), left = step("move.cursor.west"), lower = step("move.cursor.south")
    let staged = step("move.drop"), rotated = step("move.rotate")
    let run = step("move.level.up"), parent = step("move.level.up"), root = step("move.level.up")
    let pastRoot = step("move.level.up"), backToParent = step("move.level.down")
    tests.check([entered,left,lower,staged,rotated,run,parent,root,backToParent].allSatisfy { $0.status == .accepted }
        && lower.state.at(path: "interaction.cursor_window_id") == .int(2)
        && staged.state.at(path: "interaction.staged_edge") == .string("east")
        && rotated.state.at(path: "interaction.staged_edge") == .string("south")
        && parent.state.at(path: "interaction.selection.scope") == .string("parent")
        && root.state.at(path: "interaction.selection.parcel_path") == .array([])
        && root.state.at(path: "interaction.candidate.targets") == parent.state.at(path: "interaction.candidate.targets")
        && pastRoot.status == .noop && pastRoot.reason == "selection_at_display_root"
        && backToParent.state.at(path: "interaction.selection") == parent.state.at(path: "interaction.selection"),
        "guidance/browser-H-J-D-C-U-U-selects-south-parent-third-U-root-fourth-U-noop")
    let bottom = step("move.execute.auto")
    tests.check(bottom.status == .accepted
        && bottom.targets.at(path: "3.frame") == Frame.from(value.at(path: "expected_browser_bottom_frame"))?.json,
        "guidance/Return-puts-browser-full-width-at-bottom")
    // Land the first immutable targets in the hermetic observation before the second gesture.
    var observed = world.objectValue!
    observed["focused_window_id"] = .int(2)
    observed["windows"] = .array(observed["windows"]!.arrayValue!.map { value in
        var row = value.objectValue!
        if let id = row["window_id"]?.intValue, let frame = bottom.targets.at(path: "\(id).frame") { row["frame"] = frame }
        return .object(row)
    })
    world = .object(observed)
    let secondEnter = step("move.start"), upper = step("move.cursor.north"), secondStage = step("move.drop")
    var rotations = 0, rotatesAccepted = true
    while state.at(path: "interaction.staged_edge") != .string("east"), rotations < 4 {
        rotations += 1; rotatesAccepted = rotatesAccepted && step("move.rotate").status == .accepted
    }
    let final = step("move.execute.auto")
    tests.check([secondEnter,upper,secondStage].allSatisfy { $0.status == .accepted }
        && upper.state.at(path: "interaction.cursor_window_id") == .int(1) && rotatesAccepted && rotations == 2,
        "guidance/lower-terminal-K-D-C-C-selects-east-of-upper-terminal")
    let expected = value.at(path: "expected_final_frames")!.objectValue!
    tests.check(final.status == .accepted && expected.allSatisfy { id, frame in
        final.targets.at(path: "\(id).frame") == Frame.from(frame)?.json
    } && Arrangement.allocatedWindowIDs(state.at(path: "arrangement")!, topo: fixture.topology).sorted() == [1,2,3],
        "guidance/final-terminals-share-top-row-browser-stays-full-bottom-and-all-members-survive")
    let display = Project.normTopology(fixture.topology).displays[0].frame
    tests.check((final.targets.objectValue ?? [:]).values.allSatisfy { value in
        guard let frame = Frame.from(value.at(path: "frame")) else { return false }
        let envelope = BorderRing(windowId: value.at(path: "window_id")!.intValue!, frame: frame, role: .focus).envelope(thickness: 1)
        return envelope.x >= display.x && envelope.y >= display.y && envelope.maxX <= display.maxX && envelope.maxY <= display.maxY
    }, "guidance/every-final-one-point-border-is-inside-the-display-canvas")
}
