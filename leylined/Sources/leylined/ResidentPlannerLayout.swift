import Foundation
import LeylineModel

extension ResidentPlanner {
    static func navRect(_ frame: Frame) -> NavRect { NavRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h) }
    static func key(_ cell: Arrangement.Comp) -> String { "\(cell.displayId ?? 0):\(cell.i0):\(cell.j0)" }

    static func boundary(frame: Frame, displayID: Int64, ownerPath: [String], edge: String) -> JSONValue {
        let vertical = edge == "east" || edge == "west"
        let coordinate = edge == "west" ? frame.x : edge == "east" ? frame.maxX : edge == "north" ? frame.y : frame.maxY
        return .object(["axis": .string(vertical ? "v" : "h"), "coord": .double(coordinate),
            "lo": .double(vertical ? frame.y : frame.x), "hi": .double(vertical ? frame.maxY : frame.maxX),
            "side": .string(edge), "display_id": .int(displayID), "owner_path": .array(ownerPath.map(JSONValue.string))])
    }

    static func selection(cell: Arrangement.AllocatedCell, cursorID: Int64, edge: String, staged: Bool = true) -> JSONValue {
        .object(["scope": .string("edge"), "level": .int(0), "staged": .bool(staged),
            "anchor_window_id": .int(cursorID), "cursor_window_id": .int(cursorID),
            "ordered_window_ids": .array([.int(cursorID)]),
            "parcel_path": .array(cell.ownerPath.map(JSONValue.string)),
            "boundary": boundary(frame: cell.frame, displayID: cell.displayID, ownerPath: cell.ownerPath, edge: edge)])
    }

    static func collinear(_ a: Frame, _ b: Frame, edge: String) -> Bool {
        switch edge {
        case "west": return abs(a.x - b.x) <= 4
        case "east": return abs(a.maxX - b.maxX) <= 4
        case "north": return abs(a.y - b.y) <= 4
        default: return abs(a.maxY - b.maxY) <= 4
        }
    }

    /// Finite geometry order within one actual owner and connected edge component.
    static func edgeRun(cursor: Arrangement.AllocatedCell, cells: [Arrangement.AllocatedCell], edge: String) -> [Arrangement.AllocatedCell] {
        let vertical = edge == "east" || edge == "west"
        let candidates = cells.filter { $0.displayID == cursor.displayID && $0.ownerPath == cursor.ownerPath
            && collinear(cursor.frame, $0.frame, edge: edge) && $0.topWindowID != nil }
            .sorted { a, b in
                let ap = vertical ? a.frame.y : a.frame.x, bp = vertical ? b.frame.y : b.frame.x
                return ap == bp ? a.anchor < b.anchor : ap < bp
            }
        var components: [[Arrangement.AllocatedCell]] = []
        for cell in candidates {
            if let previous = components.last?.last,
               abs((vertical ? previous.frame.maxY : previous.frame.maxX) - (vertical ? cell.frame.y : cell.frame.x)) <= 4 {
                components[components.count - 1].append(cell)
            } else { components.append([cell]) }
        }
        return components.first(where: { $0.contains(where: { $0.anchor == cursor.anchor }) }) ?? []
    }

    static func expandedSelection(_ selected: JSONValue, cursor: Arrangement.AllocatedCell,
                                  cells: [Arrangement.AllocatedCell], arrangement: JSONValue,
                                  topology: JSONValue, edge: String) -> JSONValue? {
        var result = selected.objectValue ?? [:]
        let level = selected.at(path: "level")?.intValue ?? 0
        if selected.at(path: "scope")?.stringValue == "edge" {
            let run = edgeRun(cursor: cursor, cells: cells, edge: edge)
            guard let frame = Geometry.union(run.map(\.frame)) else { return nil }
            result["scope"] = .string("run"); result["level"] = .int(level + 1)
            result["ordered_window_ids"] = .array(run.compactMap(\.topWindowID).map(JSONValue.int))
            result["boundary"] = boundary(frame: frame, displayID: cursor.displayID, ownerPath: cursor.ownerPath, edge: edge)
            return .object(result)
        }
        let currentPath = (selected.at(path: "parcel_path")?.arrayValue ?? []).compactMap(\.stringValue)
        let targetPath = selected.at(path: "scope")?.stringValue == "parent" ? Array(currentPath.dropLast()) : currentPath
        guard !targetPath.isEmpty else { return nil }
        let descendants = cells.filter { $0.displayID == cursor.displayID && $0.ownerPath.starts(with: targetPath) }
        guard let frame = ownerCanvas(arrangement: arrangement, topology: topology, displayID: cursor.displayID, path: targetPath) else { return nil }
        let vertical = edge == "east" || edge == "west"
        let ordered = descendants.sorted { a, b in
            let ap = vertical ? a.frame.y : a.frame.x, bp = vertical ? b.frame.y : b.frame.x
            if ap != bp { return ap < bp }
            let aq = vertical ? a.frame.x : a.frame.y, bq = vertical ? b.frame.x : b.frame.y
            return aq == bq ? a.anchor < b.anchor : aq < bq
        }
        result["scope"] = .string("parent"); result["level"] = .int(level + 1)
        result["parcel_path"] = .array(targetPath.map(JSONValue.string))
        result["ordered_window_ids"] = .array(ordered.compactMap(\.topWindowID).map(JSONValue.int))
        result["boundary"] = boundary(frame: frame, displayID: cursor.displayID, ownerPath: Array(targetPath.dropLast()), edge: edge)
        return .object(result)
    }

    /// Rebind only saved window/owner intent to a fresh model; no positional target is guessed.
    static func resolvedSelection(_ selected: JSONValue, sourceID: Int64,
                                  arrangement: JSONValue, topology: JSONValue) -> JSONValue? {
        guard let scope = selected.at(path: "scope")?.stringValue,
              let edge = selected.at(path: "boundary.side")?.stringValue,
              let cursorID = selected.at(path: "cursor_window_id")?.intValue else { return nil }
        let ids = (selected.at(path: "ordered_window_ids")?.arrayValue ?? []).compactMap(\.intValue).filter { $0 != sourceID }
        let cells = Arrangement.allocatedCells(arrangement, topo: topology)
        let participants = ids.compactMap { id in cells.first(where: { $0.topWindowID == id }) }
        guard !participants.isEmpty, participants.count == ids.count,
              let first = participants.first, participants.allSatisfy({ $0.displayID == first.displayID }) else { return nil }
        var result = selected.objectValue ?? [:]
        if scope == "edge" {
            let rebound = selection(cell: first, cursorID: cursorID, edge: edge,
                staged: selected.at(path: "staged")?.boolValue ?? true)
            result["boundary"] = rebound.at(path: "boundary")
            result["parcel_path"] = rebound.at(path: "parcel_path")
            return .object(result)
        }
        if scope == "run" {
            guard participants.allSatisfy({ $0.ownerPath == first.ownerPath && collinear($0.frame, first.frame, edge: edge) }),
                  let frame = Geometry.union(participants.map(\.frame)) else { return nil }
            result["boundary"] = boundary(frame: frame, displayID: first.displayID, ownerPath: first.ownerPath, edge: edge)
            result["parcel_path"] = .array(first.ownerPath.map(JSONValue.string))
            return .object(result)
        }
        guard scope == "parent" else { return nil }
        var path = first.ownerPath
        for participant in participants.dropFirst() {
            while !participant.ownerPath.starts(with: path) { guard !path.isEmpty else { return nil }; path.removeLast() }
        }
        guard !path.isEmpty,
              let frame = ownerCanvas(arrangement: arrangement, topology: topology, displayID: first.displayID, path: path),
              Set(cells.filter { $0.displayID == first.displayID && $0.ownerPath.starts(with: path) }.compactMap(\.topWindowID)) == Set(ids) else { return nil }
        result["parcel_path"] = .array(path.map(JSONValue.string))
        result["boundary"] = boundary(frame: frame, displayID: first.displayID, ownerPath: Array(path.dropLast()), edge: edge)
        return .object(result)
    }

    static func ownerCanvas(arrangement: JSONValue, topology: JSONValue, displayID: Int64, path: [String]) -> Frame? {
        Arrangement.ownerCanvas(arrangement, topo: topology, displayID: displayID, path: path)
    }

    /// One immutable draft backs the preview and its eventual transaction.
    static func makeCandidate(operation: String, arrangement: JSONValue, sourceID: Int64, targetID: Int64,
                              selection: JSONValue, topology: JSONValue, state: JSONValue, world: JSONValue) -> JSONValue? {
        let desired: JSONValue
        if operation == "insert" {
            guard let inserted = insert(arrangement: arrangement, topology: topology, sourceID: sourceID, selection: selection) else { return nil }
            desired = inserted
        } else {
            guard sourceID != targetID, let swapped = swap(arrangement: arrangement, topology: topology,
                sourceID: sourceID, targetID: targetID) else { return nil }
            desired = swapped
        }
        let targets = windowTargets(Arrangement.arrangementTargetsRec(bridge: desired, topo: topology))
        let priorTargets = windowTargets(Arrangement.arrangementTargetsRec(bridge: state.at(path: "arrangement") ?? arrangement, topo: topology))
        var affected: JSONObject = [:]
        for (id, target) in targets.objectValue ?? [:] {
            if target.at(path: "frame") != priorTargets.at(path: "\(id).frame")
                || target.at(path: "effect_frame") != priorTargets.at(path: "\(id).effect_frame")
                || target.at(path: "presented") != priorTargets.at(path: "\(id).presented") { affected[id] = target }
        }
        let participants = (selection.at(path: "ordered_window_ids")?.arrayValue ?? []).compactMap(\.intValue).filter { $0 != sourceID }
        let identityIDs = Set(affected.keys.compactMap(Int64.init)).union([sourceID, targetID]).union(participants)
        var identities: JSONObject = [:]
        for window in world.at(path: "windows")?.arrayValue ?? [] {
            guard let id = window.at(path: "window_id")?.intValue, identityIDs.contains(id) else { continue }
            var identity: JSONObject = [:]
            for field in ["pid", "window_generation", "observer_epoch", "space_key", "space_uuid", "display_id"] {
                if let value = window.at(path: field), value != .null { identity[field] = value }
            }
            identities[String(id)] = .object(identity)
        }
        var base: JSONObject = ["arrangement": state.at(path: "arrangement") ?? emptyArrangement,
            "minimum_sizes": state.at(path: "minimum_sizes") ?? .object([:]),
            "active_space_key": (world.at(path: "windows")?.arrayValue ?? []).first(where: { $0.at(path: "window_id")?.intValue == sourceID })?.at(path: "space_key")
                ?? world.at(path: "active_space_key") ?? .null,
            "observer_epoch": world.at(path: "observer_epoch") ?? .null,
            "observer_generation": world.at(path: "observer_generation") ?? .null,
            "topology_revision": world.at(path: "topology_revision") ?? .null,
            "window_identities": .object(identities)]
        if let revision = state.at(path: "model_state_revision") { base["state_revision"] = revision }
        let token = "\(sourceID):\(world.at(path: "observer_generation")?.intValue ?? 0):\(operation):\(selection.canonical())"
        return .object(["schema": .string("leyline/move-candidate/v1"), "candidate_id": .string(token),
            "operation": .string(operation), "source_window_id": .int(sourceID),
            "target_window_id": operation == "swap" ? .int(targetID) : .null, "selection": selection,
            "ordered_participant_window_ids": .array(participants.map(JSONValue.int)), "base": .object(base),
            "desired_arrangement": desired, "targets": targets, "affected_frames": .object(affected)])
    }

    static func lifecycleFocusTarget(absorbers: [Int64], state: JSONValue, eligible: [JSONValue]) -> Int64? {
        let ids = Set(eligible.compactMap { $0.at(path: "window_id")?.intValue })
        if let absorber = absorbers.first(where: ids.contains) { return absorber }
        for entry in state.at(path: "focus_history")?.arrayValue ?? [] {
            guard let id = entry.intValue ?? entry.at(path: "window_id")?.intValue, ids.contains(id),
                  let observed = eligible.first(where: { $0.at(path: "window_id")?.intValue == id }) else { continue }
            let identityMatches = ["pid", "window_generation", "space_key", "display_id"].allSatisfy { field in
                entry.at(path: field).map { expected in
                    let actual = field == "display_id" && expected.stringValue != nil && observed.at(path: field)?.intValue != nil
                        ? observed.at(path: "display_uuid") : observed.at(path: field)
                    return actual == expected
                } ?? true
            }
            if identityMatches { return id }
        }
        return nil
    }

    static func settle(arrangement: JSONValue, observed: [JSONValue], topology: JSONValue, focus: Int64?) -> JSONValue? {
        settleWithEvidence(arrangement: arrangement, observed: observed, topology: topology, focus: focus)?.arrangement
    }

    /// Every eligible managed identity survives settle, including overload and nested members.
    static func settleWithEvidence(arrangement: JSONValue, observed: [JSONValue], topology: JSONValue,
                                   focus: Int64?) -> (arrangement: JSONValue, absorbers: [Int64])? {
        var result = Arrangement.bridgeArrangementNative(store: Arrangement.deriveNested(arr: arrangement, topo: topology), topo: topology)
        let normalized = Project.normTopology(topology)
        let wanted = Set(observed.compactMap { $0.at(path: "window_id")?.intValue })
        var absorbers: [Int64] = []
        for id in Set(Arrangement.allocatedWindowIDs(result, topo: topology)).subtracting(wanted).sorted() {
            guard let pruned = Arrangement.pruneAllocatedWindow(store: result, windowID: id, topo: topology, focused: focus),
                  let value = pruned.at(path: "arr") else { return nil }
            result = value
            if let absorber = pruned.at(path: "absorber")?.intValue { absorbers.append(absorber) }
        }
        for window in observed.sorted(by: { ($0.at(path: "window_id")?.intValue ?? 0) < ($1.at(path: "window_id")?.intValue ?? 0) }) {
            guard let id = window.at(path: "window_id")?.intValue,
                  let frame = Frame.from(window.at(path: "frame")),
                  let displayID = Geometry.assignDisplay(frame, normalized.displays) else { return nil }
            if let cell = Arrangement.allocatedCells(result, topo: topology).first(where: { $0.memberIDs.contains(id) }) {
                if cell.displayID == displayID { continue }
                guard let pruned = Arrangement.pruneAllocatedWindow(store: result, windowID: id, topo: topology, focused: focus),
                      let value = pruned.at(path: "arr") else { return nil }
                result = value
            }
            if !Arrangement.allocatedCells(result, topo: topology).contains(where: { $0.displayID == displayID }) {
                var object = result.objectValue ?? [:], bindings = object["bindings"]?.objectValue ?? [:]
                bindings["\(displayID):0:0"] = .object(["window_id": .int(id), "min_size": window.at(path: "min_size") ?? .object([:])])
                object["bindings"] = .object(bindings)
                result = Arrangement.bridgeArrangementNative(store: .object(object), topo: topology)
            } else {
                result = Arrangement.bridgeArrangementNativeAdopt(store: result, newcomers: [id], ndid: displayID,
                    focused: focus.map(JSONValue.int) ?? .null, topo: topology, insertionPolicy: "largest_first",
                    newcomerMinimums: [id: window.at(path: "min_size") ?? .object([:])], allowOverload: true)
                if result == .null { return nil }
            }
        }
        func stamp(_ bag: JSONValue) -> JSONValue {
            var object = bag.objectValue ?? [:]
            object["bindings"] = .object((object["bindings"]?.objectValue ?? [:]).mapValues { value in
                var binding = value.objectValue ?? [:]
                if let nested = binding["nested"] { binding["nested"] = stamp(nested) }
                if let id = binding["window_id"]?.intValue,
                   let minimum = observed.first(where: { $0.at(path: "window_id")?.intValue == id })?.at(path: "min_size") { binding["min_size"] = minimum }
                if let members = binding["contents"]?.arrayValue {
                    binding["contents"] = .array(members.map { value in
                        var member = value.objectValue ?? [:]
                        if let id = member["window_id"]?.intValue,
                           let minimum = observed.first(where: { $0.at(path: "window_id")?.intValue == id })?.at(path: "min_size") { member["min_size"] = minimum }
                        return .object(member)
                    })
                }
                return .object(binding)
            })
            return .object(object)
        }
        let stamped = Arrangement.bridgeArrangementNative(store: stamp(result), topo: topology)
        let focusedHidden = focus.flatMap { id in Arrangement.allocatedCells(stamped, topo: topology).first(where: { $0.memberIDs.contains(id) && $0.topWindowID != id }) }
        let resolution = focusedHidden.flatMap { _ in focus.flatMap { Arrangement.selectingMember(store: stamped, windowID: $0, topo: topology) } }
            ?? Arrangement.resolvingAutomaticOverload(store: stamped, topo: topology, focused: focus)
        guard let resolved = resolution else { return nil }
        result = resolved
        let actual = Arrangement.allocatedWindowIDs(result, topo: topology)
        return actual.count == wanted.count && Set(actual) == wanted ? (result, absorbers) : nil
    }

    static func swap(arrangement: JSONValue, topology: JSONValue, sourceID: Int64, targetID: Int64) -> JSONValue? {
        let cells = Arrangement.allocatedCells(arrangement, topo: topology)
        guard let source = cells.first(where: { $0.topWindowID == sourceID }),
              let target = cells.first(where: { $0.topWindowID == targetID }),
              var sourceOwner = Arrangement.ownerBag(arrangement, path: source.ownerPath)?.objectValue,
              var sourceBindings = sourceOwner["bindings"]?.objectValue else { return nil }
        let sourceTop = source.binding.at(path: "contents")?.arrayValue?.first ?? source.binding
        let targetTop = target.binding.at(path: "contents")?.arrayValue?.first ?? target.binding
        sourceBindings[source.anchor] = replacingTop(source.binding, member: targetTop); sourceOwner["bindings"] = .object(sourceBindings)
        guard let first = Arrangement.replacingOwnerBag(arrangement, path: source.ownerPath, bag: .object(sourceOwner)),
              var targetOwner = Arrangement.ownerBag(first, path: target.ownerPath)?.objectValue,
              var targetBindings = targetOwner["bindings"]?.objectValue else { return nil }
        targetBindings[target.anchor] = replacingTop(target.binding, member: sourceTop); targetOwner["bindings"] = .object(targetBindings)
        guard let changed = Arrangement.replacingOwnerBag(first, path: target.ownerPath, bag: .object(targetOwner)) else { return nil }
        return minFit(Arrangement.bridgeArrangementNative(store: changed, topo: topology), topology)
    }

    static func replacingTop(_ binding: JSONValue, member: JSONValue) -> JSONValue {
        var result = binding.objectValue ?? [:]
        let surplus = Array((binding.at(path: "contents")?.arrayValue ?? []).dropFirst())
        result["window_id"] = member.at(path: "window_id")
        result["min_size"] = member.at(path: "min_size") ?? member.at(path: "binding.min_size") ?? .object([:])
        result["contents"] = .array([member] + surplus)
        return .object(result)
    }

    static func dropSide(target: Frame, source: Frame, display: Frame) -> String {
        let aspect = log(display.w / display.h)
        if abs(log((target.w / 2) / target.h) - aspect) <= abs(log(target.w / (target.h / 2)) - aspect) {
            return source.x + source.w / 2 <= target.x + target.w / 2 ? "west" : "east"
        }
        return source.y + source.h / 2 <= target.y + target.h / 2 ? "north" : "south"
    }

    static func minFit(_ arrangement: JSONValue, _ topology: JSONValue) -> JSONValue? {
        let targets = Arrangement.arrangementTargetsRec(bridge: arrangement, topo: topology)
        for cell in Arrangement.allocatedCells(arrangement, topo: topology) {
            guard let id = cell.topWindowID, let frame = Frame.from(targets.at(path: "\(id).frame")) else { return nil }
            if cell.binding.at(path: "minimum_fit")?.stringValue == "unavoidable" { continue }
            if frame.x < cell.frame.x - 0.5 || frame.y < cell.frame.y - 0.5
                || frame.maxX > cell.frame.maxX + 0.5 || frame.maxY > cell.frame.maxY + 0.5 { return nil }
        }
        return arrangement
    }

    struct OwnerPiece {
        let displayID: Int64
        var frame: Frame
        let binding: JSONValue?
        let selected: Bool
    }

    /// Simulate vacancy, then project the anchor midpoint onto every participant's cut interval.
    /// A contiguous boundary can have unequal inward depths; one common strip still conserves it.
    static func insert(arrangement: JSONValue, topology: JSONValue, sourceID: Int64, selection: JSONValue) -> JSONValue? {
        guard let edge = selection.at(path: "boundary.side")?.stringValue,
              ["north", "east", "south", "west"].contains(edge),
              let displayID = selection.at(path: "boundary.display_id")?.intValue,
              let source = Arrangement.allocatedCells(arrangement, topo: topology).first(where: { $0.memberIDs.contains(sourceID) }),
              let sourceMember = (source.binding.at(path: "contents")?.arrayValue ?? [source.binding])
                .first(where: { $0.at(path: "window_id")?.intValue == sourceID }),
              let pruned = Arrangement.pruneAllocatedWindow(store: arrangement, windowID: sourceID, topo: topology, focused: sourceID),
              let base = pruned.at(path: "arr") else { return nil }
        guard let currentSelection = resolvedSelection(selection, sourceID: sourceID, arrangement: base, topology: topology) else { return nil }
        let participants = Set((selection.at(path: "ordered_window_ids")?.arrayValue ?? []).compactMap(\.intValue)).subtracting([sourceID])
        guard !participants.isEmpty else { return nil }
        let path = (currentSelection.at(path: "boundary.owner_path")?.arrayValue ?? []).compactMap(\.stringValue)
        guard let owner = Arrangement.ownerBag(base, path: path)?.objectValue,
              let canvas = ownerCanvas(arrangement: base, topology: topology, displayID: displayID, path: path) else { return nil }
        let normalized = Project.normTopology(topology)
        guard let displayCanvas = ownerCanvas(arrangement: base, topology: topology, displayID: displayID, path: []) else { return nil }
        let local = path.isEmpty ? topology : Arrangement.localTopology(canvas: canvas, displayID: 0, gap: normalized.gap)
        let bindings = owner["bindings"]?.objectValue ?? [:]
        let rawCells = Arrangement.cellsMd(Arrangement.parseSegs(owner["segments"]), Project.normTopology(local))
        let parcelPath = (currentSelection.at(path: "parcel_path")?.arrayValue ?? []).compactMap(\.stringValue)
        let parentAnchor = currentSelection.at(path: "scope")?.stringValue == "parent" ? parcelPath.last : nil
        var pieces = rawCells.map { cell -> OwnerPiece in
            let binding = bindings[key(cell)]
            let selected = parentAnchor.map { key(cell) == $0 } ?? (binding.map { participants.contains($0.at(path: "window_id")?.intValue ?? 0) } ?? false)
            return OwnerPiece(displayID: cell.displayId ?? 0, frame: cell.frame, binding: binding, selected: selected)
        }
        let chosen = pieces.filter(\.selected)
        guard !chosen.isEmpty, chosen.allSatisfy({ $0.displayID == (path.isEmpty ? displayID : 0) }),
              let union = Geometry.union(chosen.map(\.frame)) else { return nil }
        if parentAnchor == nil {
            guard chosen.count == participants.count else { return nil }
        } else {
            let descendants = Arrangement.allocatedCells(base, topo: topology).filter { $0.displayID == displayID && $0.ownerPath.starts(with: parcelPath) }
            guard Set(descendants.compactMap(\.topWindowID)) == participants else { return nil }
        }
        let vertical = edge == "east" || edge == "west", sourceLow = edge == "west" || edge == "north"
        let ordered = chosen.sorted { (vertical ? $0.frame.y : $0.frame.x) < (vertical ? $1.frame.y : $1.frame.x) }
        for (index, piece) in ordered.enumerated() {
            guard collinear(piece.frame, union, edge: edge) else { return nil }
            if index > 0 {
                let prior = ordered[index - 1].frame
                guard abs((vertical ? prior.maxY : prior.maxX) - (vertical ? piece.frame.y : piece.frame.x)) <= 4 else { return nil }
            }
        }
        let sourceMin = Arrangement.allocationMinimum(sourceMember, frame: source.frame, gap: normalized.gap)
        let insetUnion = inset(union, canvas: displayCanvas, gap: normalized.gap)
        guard (vertical ? insetUnion.h : insetUnion.w) + 0.5 >= (vertical ? sourceMin.h : sourceMin.w) else { return nil }
        var lower = -Double.infinity, upper = Double.infinity
        for piece in chosen {
            guard let binding = piece.binding else { return nil }
            let minimum = Arrangement.allocationMinimum(binding, frame: piece.frame, gap: normalized.gap)
            guard let interval = Arrangement.feasibleCutInterval(canvas: piece.frame, vertical: vertical,
                lowMinimum: sourceLow ? (vertical ? sourceMin.w : sourceMin.h) : (vertical ? minimum.w : minimum.h),
                highMinimum: sourceLow ? (vertical ? minimum.w : minimum.h) : (vertical ? sourceMin.w : sourceMin.h),
                lowPerpendicularMinimum: sourceLow ? 0 : (vertical ? minimum.h : minimum.w),
                highPerpendicularMinimum: sourceLow ? (vertical ? minimum.h : minimum.w) : 0,
                gap: normalized.gap, ownerCanvas: displayCanvas) else { return nil }
            lower = max(lower, interval.lower); upper = min(upper, interval.upper)
        }
        guard lower <= upper else { return nil }
        let anchorID = selection.at(path: "anchor_window_id")?.intValue
        let anchor = chosen.first(where: { $0.binding?.at(path: "window_id")?.intValue == anchorID }) ?? chosen[0]
        let proposed = vertical ? anchor.frame.x + anchor.frame.w / 2 : anchor.frame.y + anchor.frame.h / 2
        let cut = min(max(proposed, lower), upper)
        for index in pieces.indices where pieces[index].selected {
            let original = pieces[index].frame
            if vertical {
                pieces[index].frame.x = sourceLow ? cut : original.x
                pieces[index].frame.w = sourceLow ? original.maxX - cut : cut - original.x
            } else {
                pieces[index].frame.y = sourceLow ? cut : original.y
                pieces[index].frame.h = sourceLow ? original.maxY - cut : cut - original.y
            }
        }
        var inserted = union
        if vertical {
            inserted.x = sourceLow ? union.x : cut
            inserted.w = sourceLow ? cut - union.x : union.maxX - cut
        } else {
            inserted.y = sourceLow ? union.y : cut
            inserted.h = sourceLow ? cut - union.y : union.maxY - cut
        }
        pieces.append(OwnerPiece(displayID: path.isEmpty ? displayID : 0, frame: inserted, binding: sourceMember, selected: false))
        guard let rebuilt = rebuildOwner(pieces: pieces, prior: .object(owner), topology: local),
              let changed = Arrangement.replacingOwnerBag(base, path: path, bag: rebuilt) else { return nil }
        let result = Arrangement.bridgeArrangementNative(store: changed, topo: topology)
        let before = Arrangement.allocatedWindowIDs(arrangement, topo: topology), after = Arrangement.allocatedWindowIDs(result, topo: topology)
        guard before.count == after.count, Set(before) == Set(after) else { return nil }
        return minFit(result, topology)
    }

    static func inset(_ frame: Frame, canvas: Frame, gap: Double) -> Frame {
        let left = abs(frame.x - canvas.x) <= 4 ? 0 : gap / 2
        let right = abs(frame.maxX - canvas.maxX) <= 4 ? 0 : gap / 2
        let top = abs(frame.y - canvas.y) <= 4 ? 0 : gap / 2
        let bottom = abs(frame.maxY - canvas.maxY) <= 4 ? 0 : gap / 2
        return Frame(x: frame.x + left, y: frame.y + top, w: frame.w - left - right, h: frame.h - top - bottom)
    }

    /// Rebuild only the owning parcel; complete nested and stack bindings remain opaque values.
    static func rebuildOwner(pieces: [OwnerPiece], prior: JSONValue, topology: JSONValue) -> JSONValue? {
        let normalized = Project.normTopology(topology)
        let canvases = Arrangement.bags(Arrangement.parseSegs(prior.at(path: "segments")), normalized)
        var segments: [JSONValue] = []
        for piece in pieces {
            guard let canvas = canvases.first(where: { $0.displayId == piece.displayID })?.rect else { return nil }
            let f = piece.frame
            for (axis, coordinate, lo, hi, interior) in [
                ("v", f.x, f.y, f.maxY, abs(f.x - canvas.x) > 4),
                ("v", f.maxX, f.y, f.maxY, abs(f.maxX - canvas.maxX) > 4),
                ("h", f.y, f.x, f.maxX, abs(f.y - canvas.y) > 4),
                ("h", f.maxY, f.x, f.maxX, abs(f.maxY - canvas.maxY) > 4)] where interior {
                let segment: JSONValue = .object(["axis": .string(axis), "coord": .double(coordinate),
                    "lo": .double(lo), "hi": .double(hi), "relation": .string("pinned")])
                if !segments.contains(segment) { segments.append(segment) }
            }
        }
        let parsed = Arrangement.parseSegs(.array(segments))
        guard Arrangement.validMd(parsed, normalized).at(path: "ok")?.boolValue == true else { return nil }
        let cells = Arrangement.cellsMd(parsed, normalized)
        var bindings: JSONObject = [:]
        for piece in pieces {
            guard let cell = cells.first(where: { $0.displayId == piece.displayID && Geometry.frameEq($0.frame, piece.frame, tol: 0.5) }) else { return nil }
            if let binding = piece.binding {
                guard bindings[key(cell)] == nil else { return nil }
                bindings[key(cell)] = binding
            }
        }
        var result = prior.objectValue ?? [:]
        result["segments"] = .array(segments); result["bindings"] = .object(bindings)
        return .object(result)
    }

    /// Preferred face first, then opposite interior face; the physical translation sign is unchanged.
    /// The fixed 40-point pulse is clamped by the complete nested participant minima.
    static func resize(arrangement: JSONValue, topology: JSONValue, sourceID: Int64,
                       direction: NavDirection, step: Double) -> JSONValue? {
        guard let source = Arrangement.allocatedCells(arrangement, topo: topology).first(where: { $0.topWindowID == sourceID }) else { return nil }
        let vertical = direction == .east || direction == .west
        let axis = vertical ? "v" : "h"
        let preferred = direction == .east ? source.frame.maxX : direction == .west ? source.frame.x
            : direction == .south ? source.frame.maxY : source.frame.y
        let opposite = direction == .east ? source.frame.x : direction == .west ? source.frame.maxX
            : direction == .south ? source.frame.y : source.frame.maxY
        let sign: Double = direction == .west || direction == .north ? -1 : 1
        let lo = vertical ? source.frame.y : source.frame.x, hi = vertical ? source.frame.maxY : source.frame.maxX
        let paths = stride(from: source.ownerPath.count, through: 0, by: -1).map { Array(source.ownerPath.prefix($0)) }
        var chosen: (path: [String], bag: JSONValue, coordinate: Double, hit: [Int])?
        for coordinate in [preferred, opposite] {
            for path in paths {
                guard let bag = Arrangement.ownerBag(arrangement, path: path) else { return nil }
                let segments = Arrangement.parseSegs(bag.at(path: "segments"))
                let hit = segments.indices.filter { segments[$0].axis == axis && abs(segments[$0].coord - coordinate) <= 4
                    && min(segments[$0].hi, hi) - max(segments[$0].lo, lo) > 4 }
                if !hit.isEmpty { chosen = (path, bag, coordinate, hit); break }
            }
            if chosen != nil { break }
        }
        guard let chosen else { return arrangement }
        func draft(distance: Double) -> JSONValue? {
            let segments = Arrangement.translatedSegments(Arrangement.parseSegs(chosen.bag.at(path: "segments")),
                indices: chosen.hit, distance: distance * sign)
            guard let canvas = ownerCanvas(arrangement: arrangement, topology: topology, displayID: source.displayID, path: chosen.path) else { return nil }
            let local = chosen.path.isEmpty ? topology : Arrangement.localTopology(canvas: canvas, displayID: 0, gap: Project.normTopology(topology).gap)
            guard Arrangement.validMd(segments, Project.normTopology(local)).at(path: "ok")?.boolValue == true else { return nil }
            var bag = chosen.bag.objectValue ?? [:]; bag["segments"] = .array(segments.map(\.json))
            // Rekey by old allocation origin, so a moving divider cannot swap leaf identity.
            let oldCells = Arrangement.cellsMd(Arrangement.parseSegs(chosen.bag.at(path: "segments")), Project.normTopology(local))
            let newCells = Arrangement.cellsMd(segments, Project.normTopology(local))
            let bindings = chosen.bag.at(path: "bindings")?.objectValue ?? [:]
            guard oldCells.count == newCells.count else { return nil }
            var rebound: JSONObject = [:]
            for (index, cell) in oldCells.enumerated() { if let binding = bindings[key(cell)] { rebound[key(newCells[index])] = binding } }
            bag["bindings"] = .object(rebound)
            guard let changed = Arrangement.replacingOwnerBag(arrangement, path: chosen.path, bag: .object(bag)) else { return nil }
            return minFit(Arrangement.bridgeArrangementNative(store: changed, topo: topology), topology)
        }
        if let full = draft(distance: step) { return full }
        var low = 0.0, high = step
        var result = arrangement
        while high - low > 0.5 {
            let mid = ((low + high) / 2).rounded(.down)
            if mid <= low { break }
            if let partial = draft(distance: mid) { low = mid; result = partial }
            else { high = mid }
        }
        return result
    }
}
