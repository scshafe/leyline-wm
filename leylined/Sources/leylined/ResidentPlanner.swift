import Foundation
import LeylineModel

struct ResidentPlan: Sendable {
    let status: WmStatus
    let reason: String?
    let state: JSONValue
    let targets: JSONValue
    let focusTarget: Int64?
}

/// @canonical resident_action_planner -- four retained workflows use native model geometry.
/// Input is a complete resident world with topology, observed windows and focused_window_id.
/// Returned state/targets are immutable drafts; only the transaction/journal gate may commit them.
enum ResidentPlanner {
    /// Actual AX rectangles and immutable previews use the same aligned edges.
    static func windowTargets(_ targets: JSONValue) -> JSONValue {
        var result: JSONObject = [:]
        for (id, target) in targets.objectValue ?? [:] {
            var entry = target.objectValue ?? [:]
            for key in ["frame", "effect_frame"] {
                if let frame = Frame.from(entry[key]) { entry[key] = frame.roundedEdges().json }
            }
            result[id] = .object(entry)
        }
        return .object(result)
    }
    /// Publish a fresh preview of saved intent; this API never commits frames or returns AX targets.
    static func replacementMoveCandidate(state: JSONValue, world: JSONValue, priorInteraction: JSONValue? = nil) -> ResidentPlan {
        plan(actionID: "move.refresh_preview", state: state, world: world,
            arguments: .object(["interaction": priorInteraction ?? state.at(path: "interaction") ?? .null]))
    }
    static func plan(actionID: String, state: JSONValue, world: JSONValue,
                     arguments: JSONValue = .object([:])) -> ResidentPlan {
        func refusal(_ reason: String) -> ResidentPlan {
            ResidentPlan(status: .refused, reason: reason, state: state, targets: .object([:]), focusTarget: nil)
        }
        guard world.at(path: "complete")?.boolValue == true else { return refusal("world_incomplete") }
        guard world.at(path: "trusted")?.boolValue == true else { return refusal("ax_untrusted") }
        let reconcile = ["world.reconcile", "layout.regutter", "window.created", "window.destroyed", "window.minimized", "window.deminimized", "window.relocated"].contains(actionID)
        let partitioned = world.at(path: "space_contexts") != nil
        let heldAction = (actionID.hasPrefix("move.") && actionID != "move.start")
            || (actionID.hasPrefix("resize.") && actionID != "resize.start")
        let heldSourceID = state.at(path: "interaction.source_window_id")?.intValue ?? arguments.at(path: "interaction.source_window_id")?.intValue
        let heldSource = (world.at(path: "windows")?.arrayValue ?? []).first { $0.at(path: "window_id")?.intValue == heldSourceID }
        if !partitioned || !reconcile {
            guard (heldAction ? heldSource?.at(path: "space_enabled") ?? world.at(path: "space_enabled") : world.at(path: "space_enabled"))?.boolValue == true else { return refusal("space_disabled") }
        }
        let space = (heldAction ? heldSource?.at(path: "space_key") : nil)?.stringValue ?? world.at(path: "active_space_key")?.stringValue ?? ""
        if !partitioned || !reconcile {
            guard !space.isEmpty else { return refusal("active_space_unknown") }
        }
        let topology = world.at(path: "topology") ?? .object([:])
        let normalized = Project.normTopology(topology)
        guard !normalized.displays.isEmpty, normalized.displays.allSatisfy({ $0.id != nil && $0.usable.w > 0 && $0.usable.h > 0 }) else {
            return refusal("topology_unavailable")
        }
        var draft = state.objectValue ?? [:]
        let minimums = state.at(path: "minimum_sizes") ?? .object([:])
        guard Minsize.validStore(minimums) else { return refusal("minimum_store_invalid") }
        let priorArrangement = state.at(path: "arrangement") ?? emptyArrangement
        let windows = (world.at(path: "windows")?.arrayValue ?? []).map { window -> JSONValue in
            var object = window.objectValue ?? [:]
            if let minimum = Minsize.minimumForWindow(window, store: minimums, topo: topology) { object["min_size"] = minimum }
            return .object(object)
        }
        let rules = world.at(path: "rules") ?? .array([])
        let eligible = windows.filter { Autotile.tileable($0, rules)
            && $0.at(path: "minimized")?.boolValue != true && $0.at(path: "space_enabled")?.boolValue != false }
        let focus = world.at(path: "focused_window_id")?.intValue
            ?? world.at(path: "focused.id")?.intValue
        let partitions: ResidentSpacePartitions.Prepared?
        if partitioned {
            switch ResidentSpacePartitions.prepare(state: state, world: world, topology: topology,
                                                    observed: eligible, reconcile: reconcile) {
            case .failure(let failure): return refusal(failure.reason)
            case .success(let prepared): partitions = prepared
            }
        } else { partitions = nil }
        let stamped = Minsize.stampMinSizesArr(arr: partitions?.arrangement ?? priorArrangement,
            store: minimums, observed: eligible, topo: topology)
        let arrangement = Arrangement.bridgeArrangementNative(
            store: Arrangement.deriveNested(arr: stamped, topo: topology), topo: topology)

        func accepted(_ arrangement: JSONValue? = nil, focusTarget: Int64? = nil, exactTargets: JSONValue? = nil) -> ResidentPlan {
            if let arrangement { draft["arrangement"] = arrangement }
            if let partitions {
                let authored = arrangement ?? partitions.arrangement
                guard let checkpoint = partitions.checkpoint(arrangement: authored) else {
                    return refusal("space_partition_conservation_failed")
                }
                draft["arrangement"] = authored
                draft["space_partitions"] = checkpoint
            }
            let targets = windowTargets(exactTargets ?? arrangement.map { Arrangement.arrangementTargetsRec(bridge: $0, topo: topology) } ?? .object([:]))
            var authoredFocus = focusTarget
            if authoredFocus == nil, let arrangement {
                let stacks = Arrangement.allocatedCells(arrangement, topo: topology).filter { $0.memberIDs.count > 1 }
                let hiddenPlacement = stacks.contains { cell in
                    (cell.binding.at(path: "contents")?.arrayValue ?? []).dropFirst().contains { member in
                        guard let id = member.at(path: "window_id")?.intValue,
                              let desired = Frame.from(member.at(path: "effect_frame")) else { return false }
                        let actual = windows.first(where: { $0.at(path: "window_id")?.intValue == id }).flatMap { Frame.from($0.at(path: "frame")) }
                        return actual.map { !Geometry.frameEq($0, desired, tol: 0.5) } ?? true
                    }
                }
                if hiddenPlacement {
                    authoredFocus = focus.flatMap { id in Arrangement.allocatedCells(arrangement, topo: topology).contains(where: { $0.topWindowID == id }) ? id : nil }
                        ?? stacks.first?.topWindowID
                }
            }
            return ResidentPlan(status: .accepted, reason: nil, state: .object(draft), targets: targets, focusTarget: authoredFocus)
        }
        func noop(_ reason: String) -> ResidentPlan {
            ResidentPlan(status: .noop, reason: reason, state: state, targets: .object([:]), focusTarget: nil)
        }
        if reconcile {
            // A positive current managed focus wins even while its confirmed
            // history append waits behind command/effect quiescence.
            let currentManagedFocus = focus.flatMap { id in
                eligible.contains { $0.at(path: "window_id")?.intValue == id }
                    && Arrangement.allocatedWindowIDs(arrangement, topo: topology).contains(id) ? id : nil
            }
            let lifecycleCauses = Set((arguments.at(path: "lifecycle_causes")?.arrayValue ?? []).compactMap(\.stringValue)
                + [arguments.at(path: "lifecycle_cause")?.stringValue, actionID].compactMap { $0 })
            let removedByLifecycle = !lifecycleCauses.isDisjoint(with: ["window.destroyed", "window.minimized"])
            if partitions != nil {
                let wanted = Set(eligible.compactMap { $0.at(path: "window_id")?.intValue })
                let confirmed = state.at(path: "confirmed_focus_window_id")?.intValue ?? focus
                var absorbers: [Int64] = []
                if removedByLifecycle, currentManagedFocus == nil, let confirmed,
                   !wanted.contains(confirmed), Arrangement.allocatedWindowIDs(priorArrangement, topo: topology).contains(confirmed),
                   let prune = Arrangement.pruneAllocatedWindow(store: priorArrangement, windowID: confirmed, topo: topology, focused: confirmed),
                   let absorber = prune.at(path: "absorber")?.intValue { absorbers = [absorber] }
                let refocus = removedByLifecycle && currentManagedFocus == nil && confirmed.map({ !wanted.contains($0) }) == true
                    ? lifecycleFocusTarget(absorbers: absorbers, state: state, eligible: eligible) : nil
                let authored = refocus.flatMap { Arrangement.selectingMember(store: arrangement, windowID: $0, topo: topology) } ?? arrangement
                let result = accepted(authored, focusTarget: refocus)
                guard result.status == .accepted else { return result }
                var reconciled = result.state.objectValue ?? [:]
                if let interaction = retainedInteraction(state: state, newState: result.state, checkpoint: result.state.at(path: "space_partitions"), world: world) {
                    reconciled["interaction"] = interaction
                } else { reconciled.removeValue(forKey: "interaction") }
                let retainedState = JSONValue.object(reconciled)
                if actionID == "layout.regutter" {
                    let members = Set(eligible.filter { $0.at(path: "space_key")?.stringValue == space }
                        .compactMap { $0.at(path: "window_id")?.intValue.map(String.init) })
                    let scopedTargets = JSONObject(unordered: Dictionary(uniqueKeysWithValues:
                        (result.targets.objectValue ?? [:]).filter { members.contains($0.key) }.map { ($0.key, $0.value) }))
                    return ResidentPlan(status: .accepted, reason: nil, state: retainedState,
                        targets: .object(scopedTargets), focusTarget: nil)
                }
                return retainedState == state && result.focusTarget == nil ? noop("layout_unchanged") : ResidentPlan(status: .accepted, reason: nil,
                    state: retainedState, targets: result.targets, focusTarget: result.focusTarget)
            }
            guard let settled = settleWithEvidence(arrangement: arrangement, observed: eligible, topology: topology, focus: focus) else {
                return refusal("native_settle_shape_or_constraints_unsupported")
            }
            let departed = Set(Arrangement.allocatedWindowIDs(arrangement, topo: topology))
                .subtracting(eligible.compactMap { $0.at(path: "window_id")?.intValue })
            let confirmed = state.at(path: "confirmed_focus_window_id")?.intValue ?? focus
            let fallback = currentManagedFocus == nil && confirmed.map(departed.contains) == true
                ? lifecycleFocusTarget(absorbers: settled.absorbers, state: state, eligible: eligible) : nil
            let authored = fallback.flatMap { Arrangement.selectingMember(store: settled.arrangement, windowID: $0, topo: topology) } ?? settled.arrangement
            let planned = accepted(authored, focusTarget: fallback)
            return actionID != "layout.regutter" && authored == arrangement && fallback == nil && planned.focusTarget == nil ? noop("layout_unchanged") : planned
        }
        if actionID == "window.select" {
            guard let id = arguments.at(path: "window_id")?.intValue,
                  eligible.contains(where: { $0.at(path: "window_id")?.intValue == id }),
                  let selected = Arrangement.selectingMember(store: arrangement, windowID: id, topo: topology) else {
                return refusal("member_not_available")
            }
            return accepted(selected, focusTarget: id)
        }
        let cells = Arrangement.allocatedCells(arrangement, topo: topology)
        let navWindows = cells.compactMap { cell -> NavWindow? in
            guard let id = cell.topWindowID,
                  eligible.contains(where: { $0.at(path: "window_id")?.intValue == id }),
                  let frame = Frame.from(cell.binding.at(path: "frame")) else { return nil }
            return NavWindow(id: Int(id), display: Int(cell.displayID), frame: navRect(frame))
        }
        let navigation = SpatialNav(displayFrames: normalized.displays.map { navRect($0.frame) }, windows: navWindows)
        if actionID.hasPrefix("nav.focus."), let direction = NavDirection(rawValue: String(actionID.dropFirst("nav.focus.".count))) {
            guard let focus, navWindows.contains(where: { $0.id == Int(focus) }) else { return refusal("focus_not_managed") }
            guard let winner = navigation.explain(sourceId: Int(focus), direction: direction).winner else { return noop("no_navigation_candidate") }
            return accepted(focusTarget: Int64(winner))
        }
        if actionID == "move.start" || actionID == "resize.start" {
            guard let focus, let source = cells.first(where: { $0.topWindowID == focus }) else { return refusal("focus_not_managed") }
            if actionID == "move.start" {
                guard cells.contains(where: { target in
                    guard let id = target.topWindowID, id != focus else { return false }
                    if swap(arrangement: arrangement, topology: topology, sourceID: focus, targetID: id) != nil { return true }
                    return ["north", "east", "south", "west"].contains { edge in
                        insert(arrangement: arrangement, topology: topology, sourceID: focus,
                            selection: selection(cell: target, cursorID: id, edge: edge)) != nil
                    }
                }) else { return refusal("nothing_to_move_to") }
            } else {
                guard [NavDirection.north, .east, .south, .west].contains(where: { direction in
                    resize(arrangement: arrangement, topology: topology, sourceID: focus, direction: direction, step: 40)
                        .map { $0 != arrangement } == true
                }) else { return refusal("nothing_to_resize") }
            }
            draft["interaction"] = .object([
                "mode": .string(actionID == "move.start" ? "move" : "resize"),
                "source_window_id": .int(focus), "cursor_window_id": .int(focus),
                "active_space_key": .string(space),
                "observer_generation": world.at(path: "observer_generation") ?? .null,
                "topology_revision": world.at(path: "topology_revision") ?? .null,
                "staged_edge": .null, "span_window_ids": .array([]),
                "source_frame": source.frame.json, "selection_history": .array([]),
            ])
            return accepted()
        }
        let refreshing = actionID == "move.refresh_preview"
        guard var interaction = (refreshing ? arguments.at(path: "interaction") : state.at(path: "interaction"))?.objectValue,
              let sourceID = interaction["source_window_id"]?.intValue,
              (refreshing || interaction["active_space_key"]?.stringValue == (eligible.first(where: { $0.at(path: "window_id")?.intValue == sourceID })?.at(path: "space_key")?.stringValue ?? space)),
              refreshing || ["move.execute.auto", "move.execute.swap", "move.drop"].contains(actionID) || interaction["observer_generation"] == world.at(path: "observer_generation"),
              refreshing || ["move.execute.auto", "move.execute.swap", "move.drop"].contains(actionID) || interaction["topology_revision"] == world.at(path: "topology_revision"),
              cells.contains(where: { $0.memberIDs.contains(sourceID) }) else { return refusal("interaction_context_invalid") }
        let mode = interaction["mode"]?.stringValue
        if actionID == "move.off" || actionID == "resize.off" {
            draft.removeValue(forKey: "interaction"); return accepted()
        }
        if actionID == "move.cancel" {
            if interaction["staged_edge"] != nil && interaction["staged_edge"] != .null {
                interaction["staged_edge"] = .null; interaction["span_window_ids"] = .array([])
                interaction.removeValue(forKey: "selection"); interaction.removeValue(forKey: "candidate")
                interaction["selection_history"] = .array([])
                draft["interaction"] = .object(interaction)
            } else { draft.removeValue(forKey: "interaction") }
            return accepted()
        }
        if mode == "resize", actionID.hasPrefix("resize.adjust."),
           let direction = NavDirection(rawValue: String(actionID.dropFirst("resize.adjust.".count))) {
            let amount = arguments.at(path: "step")?.numberValue ?? 40
            guard amount == 40 else { return refusal("invalid_resize_step") }
            guard let resized = resize(arrangement: arrangement, topology: topology, sourceID: sourceID,
                                        direction: direction, step: amount) else { return refusal("resize_partition_or_min_fit_refused") }
            return resized == arrangement ? noop("divider_at_constraint") : accepted(resized)
        }
        guard mode == "move", let cursorID = interaction["cursor_window_id"]?.intValue else { return refusal("wrong_interaction_mode") }
        func publishSelection(_ selected: JSONValue, operation: String, history: [JSONValue]? = nil) -> ResidentPlan {
            let target = selected.at(path: "cursor_window_id")?.intValue ?? cursorID
            interaction["cursor_window_id"] = .int(target); interaction["selection"] = selected
            if operation == "insert" {
                interaction["staged_edge"] = selected.at(path: "boundary.side")
                interaction["span_window_ids"] = selected.at(path: "ordered_window_ids")
            }
            if let history { interaction["selection_history"] = .array(history) }
            guard let candidate = makeCandidate(operation: operation, arrangement: arrangement,
                sourceID: sourceID, targetID: target, selection: selected, topology: topology, state: state, world: world) else {
                if operation == "insert" { return refusal("move_partition_or_min_fit_refused") }
                interaction.removeValue(forKey: "candidate")
                draft["interaction"] = .object(interaction); return accepted()
            }
            interaction["candidate"] = candidate; draft["interaction"] = .object(interaction)
            return accepted()
        }
        if refreshing {
            guard let priorSelection = interaction["selection"],
                  let selected = resolvedSelection(priorSelection, sourceID: sourceID, arrangement: arrangement, topology: topology) else {
                return refusal("move_selection_scope_unavailable")
            }
            interaction["observer_generation"] = world.at(path: "observer_generation") ?? .null
            interaction["topology_revision"] = world.at(path: "topology_revision") ?? .null
            interaction["active_space_key"] = eligible.first(where: { $0.at(path: "window_id")?.intValue == sourceID })?.at(path: "space_key")
                ?? world.at(path: "active_space_key") ?? .null
            let operation = interaction["staged_edge"]?.stringValue == nil ? "swap" : "insert"
            return publishSelection(selected, operation: operation, history: [])
        }
        if actionID.hasPrefix("move.cursor."), let direction = NavDirection(rawValue: String(actionID.dropFirst("move.cursor.".count))) {
            if let edge = interaction["staged_edge"]?.stringValue {
                let vertical = edge == "east" || edge == "west"
                guard vertical ? (direction == .north || direction == .south) : (direction == .west || direction == .east) else {
                    return noop("staged_edge_perpendicular")
                }
                if var selected = interaction["selection"]?.objectValue,
                   selected["scope"]?.stringValue != "edge" {
                    let ordered = (selected["ordered_window_ids"]?.arrayValue ?? []).compactMap(\.intValue)
                    guard let index = ordered.firstIndex(of: cursorID) else { return refusal("staged_cursor_unavailable") }
                    let next = index + ((direction == .south || direction == .east) ? 1 : -1)
                    guard ordered.indices.contains(next) else { return noop("staged_edge_end") }
                    selected["cursor_window_id"] = .int(ordered[next]); interaction["cursor_window_id"] = .int(ordered[next])
                    interaction["selection"] = .object(selected)
                    if var candidate = interaction["candidate"]?.objectValue {
                        candidate["selection"] = .object(selected); interaction["candidate"] = .object(candidate)
                    }
                    draft["interaction"] = .object(interaction); return accepted()
                }
                guard let cursor = cells.first(where: { $0.topWindowID == cursorID }) else { return refusal("staged_cursor_unavailable") }
                let run = edgeRun(cursor: cursor, cells: cells, edge: edge)
                guard let index = run.firstIndex(where: { $0.topWindowID == cursorID }) else { return refusal("staged_edge_unavailable") }
                let next = index + ((direction == .south || direction == .east) ? 1 : -1)
                guard run.indices.contains(next), let winner = run[next].topWindowID else { return noop("staged_edge_end") }
                return publishSelection(selection(cell: run[next], cursorID: winner, edge: edge), operation: "insert", history: [])
            }
            guard let winner = navigation.explain(sourceId: Int(cursorID), direction: direction).winner,
                  let target = cells.first(where: { $0.topWindowID == Int64(winner) }),
                  let source = cells.first(where: { $0.memberIDs.contains(sourceID) }),
                  let display = normalized.displays.first(where: { $0.id == target.displayID }) else { return noop("no_cursor_candidate") }
            let edge = dropSide(target: target.frame, source: source.frame, display: display.frame)
            return publishSelection(selection(cell: target, cursorID: Int64(winner), edge: edge, staged: false), operation: "swap")
        }
        if actionID == "move.drop", interaction["staged_edge"] == nil || interaction["staged_edge"] == .null {
            guard cursorID != sourceID, let cursor = cells.first(where: { $0.topWindowID == cursorID }),
                  let source = cells.first(where: { $0.memberIDs.contains(sourceID) }),
                  let display = normalized.displays.first(where: { $0.id == cursor.displayID }) else { return refusal("invalid_insert_target") }
            let edge = dropSide(target: cursor.frame, source: source.frame, display: display.frame)
            return publishSelection(selection(cell: cursor, cursorID: cursorID, edge: edge), operation: "insert", history: [])
        }
        if actionID == "move.rotate" {
            guard let edge = interaction["staged_edge"]?.stringValue else { return noop("no_staged_edge") }
            let cycle = ["north", "east", "south", "west"]
            guard let cursor = cells.first(where: { $0.topWindowID == cursorID }) else { return refusal("invalid_insert_target") }
            let rotated = cycle[((cycle.firstIndex(of: edge) ?? 3) + 1) % 4]
            return publishSelection(selection(cell: cursor, cursorID: cursorID, edge: rotated), operation: "insert", history: [])
        }
        if actionID == "move.level.up" || actionID == "move.level.down" {
            guard let edge = interaction["staged_edge"]?.stringValue, let selected = interaction["selection"],
                  let cursor = cells.first(where: { $0.topWindowID == cursorID }) else { return refusal("no_staged_edge") }
            var history = interaction["selection_history"]?.arrayValue ?? []
            if actionID == "move.level.down" {
                guard let previous = history.popLast() else { return noop("selection_at_edge") }
                return publishSelection(previous, operation: "insert", history: history)
            }
            guard let expanded = expandedSelection(selected, cursor: cursor, cells: cells, arrangement: arrangement,
                topology: topology, edge: edge) else { return noop("selection_at_display_root") }
            history.append(selected)
            return publishSelection(expanded, operation: "insert", history: history)
        }
        if ["move.execute.auto", "move.execute.swap", "move.drop"].contains(actionID) {
            let stagedEdge = interaction["staged_edge"]?.stringValue
            if stagedEdge != nil {
                if actionID == "move.execute.swap" { return refusal("insert_staged_swap_refused") }
            } else {
                guard cursorID != sourceID else { return noop("source_is_cursor") }
            }
            guard let candidate = interaction["candidate"] else { return refusal("move_candidate_unavailable") }
            guard MoveCandidate.isCurrent(candidate: candidate, state: state, world: world) else { return refusal("move_candidate_stale") }
            guard let changed = candidate.at(path: "desired_arrangement"), let targets = candidate.at(path: "targets") else {
                return refusal("move_candidate_invalid")
            }
            draft.removeValue(forKey: "interaction"); return accepted(changed, exactTargets: targets)
        }
        return refusal("action_not_retained_or_unsupported")
    }

    static let emptyArrangement: JSONValue = .object([
        "segments": .array([]), "bindings": .object([:]), "off_top": .array([]), "promotions": .array([])])

    /// Reconcile may change unrelated visible Spaces without changing a held mode's participants.
    /// Whole referenced partition equality protects the collinear resize group as well as staged spans.
    private static func retainedInteraction(state: JSONValue, newState: JSONValue, checkpoint: JSONValue?, world: JSONValue) -> JSONValue? {
        guard var interaction = state.at(path: "interaction")?.objectValue,
              let mode = interaction["mode"]?.stringValue, mode != "default",
              world.at(path: "mode")?.stringValue == mode,
              let sourceID = interaction["source_window_id"]?.intValue,
              let cursorID = interaction["cursor_window_id"]?.intValue,
              let origin = interaction["active_space_key"]?.stringValue,
              let prior = state.at(path: "space_partitions"), let checkpoint,
              let oldVisible = prior.at(path: "visible")?.objectValue,
              let newVisible = checkpoint.at(path: "visible")?.objectValue,
              let oldPartitions = prior.at(path: "partitions")?.objectValue,
              let newPartitions = checkpoint.at(path: "partitions")?.objectValue else { return nil }
        let references = Set([sourceID, cursorID] + (interaction["span_window_ids"]?.arrayValue ?? []).compactMap(\.intValue))
        let cells = Arrangement.allocatedCells(state.at(path: "arrangement") ?? emptyArrangement,
            topo: world.at(path: "topology") ?? .object([:]))
        for id in references {
            guard let cell = cells.first(where: { $0.memberIDs.contains(id) }) else { return nil }
            let display = String(cell.displayID)
            guard
                  let oldContext = oldVisible[display], oldContext.at(path: "space_enabled")?.boolValue == true,
                  let newContext = newVisible[display], newContext == oldContext,
                  let key = oldContext.at(path: "partition_key")?.stringValue,
                  let oldPart = oldPartitions[key], let newPart = newPartitions[key],
                  oldPart.at(path: "observer_epoch") == world.at(path: "observer_epoch"),
                  oldPart.at(path: "observer_epoch") == newPart.at(path: "observer_epoch"),
                  oldPart.at(path: "space_uuid") == newPart.at(path: "space_uuid"),
                  oldPart.at(path: "display_geometry") == newPart.at(path: "display_geometry"),
                  oldPart.at(path: "arrangement") == newPart.at(path: "arrangement"),
                  let identities = oldPart.at(path: "window_identities")?.objectValue,
                  identities[String(id)] != nil,
                  oldPart.at(path: "window_identities") == newPart.at(path: "window_identities") else { return nil }
            if id == sourceID && (oldPart.at(path: "space_key")?.stringValue != origin
                || newPart.at(path: "space_key")?.stringValue != origin) { return nil }
        }
        interaction["observer_generation"] = world.at(path: "observer_generation") ?? .null
        interaction["topology_revision"] = world.at(path: "topology_revision") ?? .null
        if let candidate = interaction["candidate"], let selected = interaction["selection"],
           let arrangement = newState.at(path: "arrangement"),
           let replacement = makeCandidate(operation: candidate.at(path: "operation")?.stringValue ?? "insert",
                arrangement: arrangement, sourceID: sourceID, targetID: cursorID, selection: selected,
                topology: world.at(path: "topology") ?? .object([:]), state: newState, world: world) {
            interaction["candidate"] = replacement
        } else if interaction["candidate"] != nil { return nil }
        return .object(interaction)
    }
}
