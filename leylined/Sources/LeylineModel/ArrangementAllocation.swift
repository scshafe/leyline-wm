import Foundation

extension Arrangement {
    /// A leaf allocation retains its containing parcel path and every overload member.
    /// The display identity is inherited through nested local `0:i:j` anchors.
    public struct AllocatedCell: Sendable {
        public let displayID: Int64
        public let ownerPath: [String]
        public let anchor: String
        public let frame: Frame
        public let canvas: Frame
        public let binding: JSONValue
        public var memberIDs: [Int64] { Arrangement.memberIDs(binding) }
        public var topWindowID: Int64? { memberIDs.first }
    }

    /// @canonical arrangement_member_inventory -- stacks are allocated leaves, never dropped IDs.
    public static func memberIDs(_ binding: JSONValue) -> [Int64] {
        if let contents = binding.at(path: "contents")?.arrayValue, !contents.isEmpty {
            return contents.compactMap { $0.at(path: "window_id")?.intValue }
        }
        return binding.at(path: "window_id")?.intValue.map { [$0] } ?? []
    }

    /// Every current managed member record, retaining duplicates for caller validation.
    /// Saved overload recovery geometry is checkpoint data, not a second membership inventory.
    public static func memberWindows(_ store: JSONValue) -> [JSONValue] {
        (store.at(path: "bindings")?.objectValue ?? [:]).values.flatMap { binding in
            if let nested = binding.at(path: "nested") { return memberWindows(nested) }
            return binding.at(path: "contents")?.arrayValue ?? [binding]
        }
    }

    /// @canonical recursive_allocation_inventory -- the model/planner share this geometric view.
    public static func allocatedCells(_ store: JSONValue, topo: JSONValue) -> [AllocatedCell] {
        let T = Project.normTopology(topo)
        let derived = deriveNested(arr: store, topo: topo)
        func walk(_ bag: JSONValue, canvas: Frame, localDisplay: Int64,
                  display: Int64, path: [String]) -> [AllocatedCell] {
            let bindings = bag.at(path: "bindings")?.objectValue ?? [:]
            return cells(parseSegs(bag.at(path: "segments")), canvas).flatMap { cell -> [AllocatedCell] in
                let anchor = "\(localDisplay):\(cell.i0):\(cell.j0)"
                guard let binding = bindings[anchor] else { return [] }
                if let nested = binding.at(path: "nested"), nested.objectValue != nil {
                    return walk(nested, canvas: cell.frame, localDisplay: 0, display: display, path: path + [anchor])
                }
                return [AllocatedCell(displayID: display, ownerPath: path, anchor: anchor,
                    frame: cell.frame, canvas: canvas, binding: binding)]
            }
        }
        var result: [AllocatedCell] = []
        for bag in bags(parseSegs(derived.at(path: "segments")), T) {
            guard let canvas = bag.rect, let display = bag.displayId else { continue }
            var root = derived.objectValue ?? [:]
            root["segments"] = .array(bag.segments.map(\.json))
            result += walk(.object(root), canvas: canvas, localDisplay: display, display: display, path: [])
        }
        return result.sortedStableBy { .array([.int($0.displayID), .double($0.frame.y), .double($0.frame.x),
            .string(($0.ownerPath + [$0.anchor]).joined(separator: "/"))]) }
    }

    public static func allocatedWindowIDs(_ store: JSONValue, topo: JSONValue) -> [Int64] {
        allocatedCells(store, topo: topo).flatMap(\.memberIDs)
    }

    /// Validate recursive partition geometry and complete member identity before publishing it.
    public static func allocationValid(_ store: JSONValue, topo: JSONValue) -> Bool {
        var seen = Set<Int64>()
        func check(_ bag: JSONValue, topology: JSONValue) -> Bool {
            guard bag.objectValue != nil, let rawSegments = bag.at(path: "segments")?.arrayValue,
                  let bindings = bag.at(path: "bindings")?.objectValue,
                  (bag.at(path: "off_top")?.arrayValue ?? []).isEmpty else { return false }
            let segments = parseSegs(.array(rawSegments)), normalized = Project.normTopology(topology)
            guard segments.count == rawSegments.count,
                  segments.allSatisfy({ ["v", "h"].contains($0.axis) && [$0.coord, $0.lo, $0.hi].allSatisfy(\.isFinite) }),
                  bagsWithRejected(segments, normalized).rejected.isEmpty,
                  validMd(segments, normalized).at(path: "ok")?.boolValue == true else { return false }
            let cells = cellsMd(segments, normalized)
            for (anchor, binding) in bindings {
                guard let cell = cells.first(where: { anchorKey($0) == anchor }), binding.objectValue != nil else { return false }
                if let nested = binding.at(path: "nested") {
                    guard check(nested, topology: localTopology(canvas: cell.frame, displayID: 0, gap: normalized.gap)) else { return false }
                } else {
                    let members = binding.at(path: "contents")?.arrayValue ?? [binding]
                    guard !members.isEmpty, let top = members.first?.at(path: "window_id")?.intValue,
                          binding.at(path: "window_id")?.intValue == top else { return false }
                    for member in members {
                        guard let id = member.at(path: "window_id")?.intValue, id > 0, seen.insert(id).inserted else { return false }
                        if let minimum = member.at(path: "min_size") ?? member.at(path: "binding.min_size"),
                           !Minsize.validStore(.object(["member": minimum])) { return false }
                    }
                    if let minimum = binding.at(path: "min_size") ?? binding.at(path: "binding.min_size"),
                       !Minsize.validStore(.object(["binding": minimum])) { return false }
                }
            }
            return true
        }
        return check(deriveNested(arr: store, topo: topo), topology: topo)
    }

    /// Known presented-member floor, composed upward through opaque nested allocations.
    public static func allocationMinimum(_ binding: JSONValue, frame: Frame, gap: Double) -> (w: Double, h: Double) {
        guard let nested = binding.at(path: "nested"), let bindings = nested.at(path: "bindings")?.objectValue else {
            let minimum = binding.at(path: "min_size") ?? binding.at(path: "binding.min_size")
                ?? binding.at(path: "contents")?.arrayValue?.first?.at(path: "min_size")
                ?? binding.at(path: "contents")?.arrayValue?.first?.at(path: "binding.min_size") ?? .object([:])
            var result = (w: minimum.at(path: "w")?.numberValue ?? 0, h: minimum.at(path: "h")?.numberValue ?? 0)
            for member in binding.at(path: "contents")?.arrayValue ?? [] {
                let floor = member.at(path: "min_size") ?? member.at(path: "binding.min_size") ?? .object([:])
                result.w = max(result.w, floor.at(path: "w")?.numberValue ?? 0)
                result.h = max(result.h, floor.at(path: "h")?.numberValue ?? 0)
            }
            return result
        }
        var result = (w: 0.0, h: 0.0)
        var childMinimums: [(frame: Frame, w: Double, h: Double)] = []
        for var cell in cells(parseSegs(nested.at(path: "segments")), frame) {
            cell.displayId = 0
            guard let child = bindings[anchorKey(cell)], cell.frame.w > 0, cell.frame.h > 0 else { continue }
            let minimum = allocationMinimum(child, frame: cell.frame, gap: gap)
            childMinimums.append((cell.frame, minimum.w, minimum.h))
        }
        let xs = Array(Set(childMinimums.flatMap { [$0.frame.x, $0.frame.maxX] })).sorted()
        let ys = Array(Set(childMinimums.flatMap { [$0.frame.y, $0.frame.maxY] })).sorted()
        for pair in zip(ys, ys.dropFirst()) {
            let mid = (pair.0 + pair.1) / 2
            let row = childMinimums.filter { $0.frame.y <= mid && mid < $0.frame.maxY }
            result.w = max(result.w, row.reduce(0) { $0 + $1.w } + gap * Double(max(row.count - 1, 0)))
        }
        for pair in zip(xs, xs.dropFirst()) {
            let mid = (pair.0 + pair.1) / 2
            let column = childMinimums.filter { $0.frame.x <= mid && mid < $0.frame.maxX }
            result.h = max(result.h, column.reduce(0) { $0 + $1.h } + gap * Double(max(column.count - 1, 0)))
        }
        return result
    }

    /// @canonical divider_translation -- move an owned line and its perpendicular riders.
    public static func translatedSegments(_ original: [Seg], indices: [Int], distance: Double) -> [Seg] {
        guard let first = indices.first else { return original }
        let axis = original[first].axis, coordinate = original[first].coord
        let moved = indices.map { original[$0] }
        var segments = original
        for index in segments.indices {
            if indices.contains(index) { segments[index].coord += distance }
            else if segments[index].axis != axis,
                    moved.contains(where: { segments[index].coord >= $0.lo - tol && segments[index].coord <= $0.hi + tol }) {
                if abs(segments[index].lo - coordinate) <= tol { segments[index].lo += distance }
                if abs(segments[index].hi - coordinate) <= tol { segments[index].hi += distance }
            }
        }
        return segments
    }

    /// Re-solve a reframed child's interior against known floors, retaining every opaque binding.
    /// A nil result means the shared interval is empty; the caller retains explicit infeasibility.
    static func fittingOwnerMinimums(_ bag: JSONValue, canvas: Frame, frameCanvas: Frame,
                                     gap: Double) -> JSONValue? {
        let topology = localTopology(canvas: canvas, displayID: 0, gap: gap), T = Project.normTopology(topology)
        var result = bag, seen = Set<String>()
        while seen.insert(result.canonical()).inserted {
            var changed = false
            let original = parseSegs(result.at(path: "segments"))
            for selected in original.indices {
                let segments = parseSegs(result.at(path: "segments"))
                guard segments.indices.contains(selected) else { return nil }
                let axis = segments[selected].axis, coordinate = segments[selected].coord
                var indices = [selected], lo = segments[selected].lo, hi = segments[selected].hi
                var expanded = true
                while expanded {
                    expanded = false
                    for index in segments.indices where !indices.contains(index) && segments[index].axis == axis
                        && abs(segments[index].coord - coordinate) <= tol
                        && segments[index].lo <= hi + tol && segments[index].hi >= lo - tol {
                        indices.append(index); lo = min(lo, segments[index].lo); hi = max(hi, segments[index].hi); expanded = true
                    }
                }
                let cells = cellsMd(segments, T), bindings = result.at(path: "bindings")?.objectValue ?? [:]
                let vertical = axis == "v"
                let lows = cells.filter { abs((vertical ? $0.frame.maxX : $0.frame.maxY) - coordinate) <= tol
                    && min(vertical ? $0.frame.maxY : $0.frame.maxX, hi) - max(vertical ? $0.frame.y : $0.frame.x, lo) > tol }
                let highs = cells.filter { abs((vertical ? $0.frame.x : $0.frame.y) - coordinate) <= tol
                    && min(vertical ? $0.frame.maxY : $0.frame.maxX, hi) - max(vertical ? $0.frame.y : $0.frame.x, lo) > tol }
                var lower = -Double.infinity, upper = Double.infinity
                for low in lows {
                    let minimum = allocationMinimum(bindings[anchorKey(low)] ?? .object([:]), frame: low.frame, gap: gap)
                    let start = vertical ? low.frame.x : low.frame.y
                    let outer = vertical ? frameCanvas.x : frameCanvas.y
                    lower = max(lower, start + (abs(start - outer) <= tol ? 0 : gap / 2) + gap / 2 + (vertical ? minimum.w : minimum.h))
                }
                for high in highs {
                    let minimum = allocationMinimum(bindings[anchorKey(high)] ?? .object([:]), frame: high.frame, gap: gap)
                    let end = vertical ? high.frame.maxX : high.frame.maxY
                    let outer = vertical ? frameCanvas.maxX : frameCanvas.maxY
                    upper = min(upper, end - (abs(end - outer) <= tol ? 0 : gap / 2) - gap / 2 - (vertical ? minimum.w : minimum.h))
                }
                guard lower <= upper else { return nil }
                let cut = min(max(coordinate, lower), upper)
                if abs(cut - coordinate) <= 0.000_001 { continue }
                let translated = translatedSegments(segments, indices: indices, distance: cut - coordinate)
                guard validMd(translated, T).at(path: "ok")?.boolValue == true else { return nil }
                let newCells = cellsMd(translated, T)
                guard cells.count == newCells.count else { return nil }
                var rebound: JSONObject = [:]
                for (index, cell) in cells.enumerated() { if let binding = bindings[anchorKey(cell)] { rebound[anchorKey(newCells[index])] = binding } }
                var object = result.objectValue ?? [:]; object["segments"] = .array(translated.map(\.json)); object["bindings"] = .object(rebound)
                result = .object(object); changed = true
            }
            if !changed { return result }
        }
        return nil
    }

    /// Returns a containing parcel without changing or flattening its bindings.
    public static func ownerBag(_ store: JSONValue, path: [String]) -> JSONValue? {
        var result = store
        for anchor in path {
            guard let nested = result.at(path: "bindings")?.objectValue?[anchor]?.at(path: "nested") else { return nil }
            result = nested
        }
        return result
    }

    public static func ownerCanvas(_ store: JSONValue, topo: JSONValue, displayID: Int64, path: [String]) -> Frame? {
        let normalized = Project.normTopology(topo)
        guard var canvas = bags(parseSegs(store.at(path: "segments")), normalized).first(where: { $0.displayId == displayID })?.rect else { return nil }
        var bag = store
        for (index, anchor) in path.enumerated() {
            let local = localTopology(canvas: canvas, displayID: index == 0 ? displayID : 0, gap: normalized.gap)
            guard let cell = cellsMd(parseSegs(bag.at(path: "segments")), Project.normTopology(local)).first(where: { anchorKey($0) == anchor }),
                  let nested = bag.at(path: "bindings")?.objectValue?[anchor]?.at(path: "nested") else { return nil }
            canvas = cell.frame; bag = nested
        }
        return canvas
    }

    public static func replacingOwnerBag(_ store: JSONValue, path: [String], bag: JSONValue) -> JSONValue? {
        guard let anchor = path.first else { return bag }
        guard var root = store.objectValue, var bindings = root["bindings"]?.objectValue,
              var binding = bindings[anchor]?.objectValue, let nested = binding["nested"],
              let replaced = replacingOwnerBag(nested, path: Array(path.dropFirst()), bag: bag) else { return nil }
        binding["nested"] = replaced; bindings[anchor] = .object(binding); root["bindings"] = .object(bindings)
        return .object(root)
    }

    /// The local author reuses the existing per-display partition implementation.
    public static func localTopology(canvas: Frame, displayID: Int64, gap: Double) -> JSONValue {
        .object(["displays": .array([.object(["id": .int(displayID), "frame": canvas.json,
            "usable": canvas.json])]), "gap": .double(gap), "outer_gap": .int(0)])
    }

    /// Reframe a child parcel through its sole downward interface: its allocation.
    static func transformedOwnerBag(_ bag: JSONValue, from old: Frame, to new: Frame) -> JSONValue {
        guard old.w > 0, old.h > 0 else { return bag }
        func x(_ value: Double) -> Double { new.x + (value - old.x) * new.w / old.w }
        func y(_ value: Double) -> Double { new.y + (value - old.y) * new.h / old.h }
        func frame(_ value: JSONValue?) -> JSONValue? {
            guard let f = Frame.from(value) else { return value }
            return Frame(x: x(f.x), y: y(f.y), w: f.w * new.w / old.w, h: f.h * new.h / old.h).json
        }
        var result = bag.objectValue ?? [:]
        result["segments"] = .array(parseSegs(result["segments"]).map { original in
            var segment = original
            segment.coord = segment.axis == "v" ? x(segment.coord) : y(segment.coord)
            segment.lo = segment.axis == "v" ? y(segment.lo) : x(segment.lo)
            segment.hi = segment.axis == "v" ? y(segment.hi) : x(segment.hi)
            return segment.json
        })
        result["bindings"] = .object((result["bindings"]?.objectValue ?? [:]).mapValues { value in
            var binding = value.objectValue ?? [:]
            if let f = frame(binding["frame"]) { binding["frame"] = f }
            if let f = frame(binding["allocated_frame"]) { binding["allocated_frame"] = f }
            if let nested = binding["nested"] { binding["nested"] = transformedOwnerBag(nested, from: old, to: new) }
            return .object(binding)
        })
        return .object(result)
    }

    /// @canonical known_minimum_cut_interval -- minimum floors constrain one common raw cut.
    /// The returned cut is the proposal projected once onto the shared feasible interval.
    /// Empty intervals return nil; unknown axes contribute zero, never a guessed floor.
    public static func feasibleCut(canvas: Frame, vertical: Bool, proposed: Double,
                                   lowMinimum: Double, highMinimum: Double,
                                   lowPerpendicularMinimum: Double, highPerpendicularMinimum: Double,
                                   gap: Double, ownerCanvas: Frame) -> Double? {
        guard proposed.isFinite, let interval = feasibleCutInterval(canvas: canvas, vertical: vertical,
            lowMinimum: lowMinimum, highMinimum: highMinimum,
            lowPerpendicularMinimum: lowPerpendicularMinimum, highPerpendicularMinimum: highPerpendicularMinimum,
            gap: gap, ownerCanvas: ownerCanvas) else { return nil }
        return min(max(proposed, interval.lower), interval.upper)
    }

    public struct CutInterval: Sendable {
        public let lower: Double
        public let upper: Double
    }

    public static func feasibleCutInterval(canvas: Frame, vertical: Bool,
                                          lowMinimum: Double, highMinimum: Double,
                                          lowPerpendicularMinimum: Double, highPerpendicularMinimum: Double,
                                          gap: Double, ownerCanvas: Frame) -> CutInterval? {
        guard [canvas.x, canvas.y, canvas.w, canvas.h, lowMinimum, highMinimum,
               lowPerpendicularMinimum, highPerpendicularMinimum, gap].allSatisfy({ $0.isFinite }),
              canvas.w > 0, canvas.h > 0, gap >= 0,
              min(lowMinimum, highMinimum, lowPerpendicularMinimum, highPerpendicularMinimum) >= 0 else { return nil }
        let origin = vertical ? canvas.x : canvas.y
        let end = vertical ? canvas.maxX : canvas.maxY
        let ownerOrigin = vertical ? ownerCanvas.x : ownerCanvas.y
        let ownerEnd = vertical ? ownerCanvas.maxX : ownerCanvas.maxY
        let lowInset = abs(origin - ownerOrigin) <= tol ? 0 : gap / 2
        let highInset = abs(end - ownerEnd) <= tol ? 0 : gap / 2
        let perpendicular = insetInterior(canvas, ownerCanvas, gap)
        let perpendicularSize = vertical ? perpendicular.h : perpendicular.w
        guard perpendicularSize + 0.5 >= max(lowPerpendicularMinimum, highPerpendicularMinimum) else { return nil }
        // Raw allocation coordinates preserve the existing half-point geometry.
        // The native bridge uses these same exact coordinates for target insets.
        let lower = origin + lowInset + gap / 2 + lowMinimum
        let upper = end - highInset - gap / 2 - highMinimum
        let boundedLower = max(lower, origin + tol + 1), boundedUpper = min(upper, end - tol - 1)
        guard boundedLower <= boundedUpper else { return nil }
        return CutInterval(lower: boundedLower, upper: boundedUpper)
    }

    /// Select an exact overload member; changing the top never discards sibling members.
    public static func selectingMember(store: JSONValue, windowID: Int64, topo: JSONValue) -> JSONValue? {
        guard let cell = allocatedCells(store, topo: topo).first(where: { $0.memberIDs.contains(windowID) }),
              var owner = ownerBag(store, path: cell.ownerPath)?.objectValue,
              var bindings = owner["bindings"]?.objectValue, var binding = bindings[cell.anchor]?.objectValue else { return nil }
        var contents = binding["contents"]?.arrayValue ?? [.object(binding)]
        guard let index = contents.firstIndex(where: { $0.at(path: "window_id")?.intValue == windowID }) else { return nil }
        let chosen = contents.remove(at: index); contents.insert(chosen, at: 0)
        binding["window_id"] = .int(windowID); binding["top_window_id"] = .int(windowID)
        binding["min_size"] = chosen.at(path: "min_size") ?? .object([:])
        let minimum = allocationMinimum(chosen, frame: cell.frame, gap: Project.normTopology(topo).gap)
        if minimum.w <= cell.frame.w && minimum.h <= cell.frame.h {
            binding.removeValue(forKey: "minimum_fit")
            if binding["overload_reason"]?.stringValue == "known_minimum_exceeds_display_canvas" {
                binding["overload_reason"] = .string("known_minimum_partition_infeasible")
            }
        }
        binding["contents"] = .array(contents); bindings[cell.anchor] = .object(binding); owner["bindings"] = .object(bindings)
        guard let changed = replacingOwnerBag(store, path: cell.ownerPath, bag: .object(owner)) else { return nil }
        return resolvingAutomaticOverload(store: bridgeArrangementNative(store: changed, topo: topo), topo: topo, focused: windowID)
    }

    /// @canonical allocated_window_reclaim -- reuse the native prune geometry with opaque parcel bindings.
    /// Returns the authored arrangement and exact absorbing navigable member, or nil on unsafe shape.
    public static func pruneAllocatedWindow(store: JSONValue, windowID: Int64, topo: JSONValue,
                                            focused: Int64?, policy: String = "even") -> JSONValue? {
        guard let cell = allocatedCells(store, topo: topo).first(where: { $0.memberIDs.contains(windowID) }),
              var owner = ownerBag(store, path: cell.ownerPath)?.objectValue,
              var bindings = owner["bindings"]?.objectValue else { return nil }
        let local = cell.ownerPath.isEmpty ? topo : localTopology(canvas: cell.canvas, displayID: 0,
            gap: Project.normTopology(topo).gap)
        var absorber: JSONValue = .null
        if cell.memberIDs.count > 1 {
            var binding = cell.binding.objectValue ?? [:]
            let members = (binding["contents"]?.arrayValue ?? []).filter { $0.at(path: "window_id")?.intValue != windowID }
            guard let top = members.first?.at(path: "window_id")?.intValue else { return nil }
            binding["window_id"] = .int(top); binding["top_window_id"] = .int(top)
            binding["min_size"] = members.first?.at(path: "min_size") ?? .object([:])
            binding["contents"] = .array(members); bindings[cell.anchor] = .object(binding)
            if let saved = binding["overload_restore"], let canvas = Frame.from(binding["overload_restore_canvas"]),
               let retired = pruneAllocatedWindow(store: saved, windowID: windowID,
                    topo: localTopology(canvas: canvas, displayID: cell.ownerPath.isEmpty ? cell.displayID : 0,
                        gap: Project.normTopology(topo).gap), focused: nil), let restored = retired.at(path: "arr") {
                binding["overload_restore"] = restored; bindings[cell.anchor] = .object(binding)
            }
            owner["bindings"] = .object(bindings); absorber = .int(top)
        } else {
            let rawCells = cellsMd(parseSegs(owner["segments"]), Project.normTopology(local))
            let localDisplay = cell.ownerPath.isEmpty ? cell.displayID : 0
            let sameDisplay = bindings.keys.filter { $0.hasPrefix("\(localDisplay):") }
            if sameDisplay.count == 1 {
                bindings.removeValue(forKey: cell.anchor); owner["bindings"] = .object(bindings)
            } else {
                var opaque: [Int64: JSONValue] = [:]
                var surrogate: JSONObject = [:]
                for (index, entry) in bindings.enumerated() {
                    let id = entry.value.at(path: "window_id")?.intValue ?? (-1_000_000 - Int64(index))
                    guard let raw = rawCells.first(where: { anchorKey($0) == entry.key }) else { return nil }
                    opaque[id] = entry.value
                    surrogate[entry.key] = .object(["window_id": .int(id), "frame": raw.frame.json])
                }
                var authored = owner; authored["bindings"] = .object(surrogate)
                let pruned = bridgeArrangementNativePrune(store: .object(authored), goners: [windowID],
                    focused: focused.map(JSONValue.int) ?? .null, topo: local, policy: policy)
                guard var result = pruned.at(path: "arr")?.objectValue,
                      let rebound = result["bindings"]?.objectValue else { return nil }
                var restored: JSONObject = [:]
                for (anchor, value) in rebound {
                    guard let id = value.at(path: "window_id")?.intValue, let original = opaque[id] else { return nil }
                    restored[anchor] = original
                }
                result["bindings"] = .object(restored); owner = result
                absorber = pruned.at(path: "absorber") ?? .null
                if (absorber.intValue ?? 0) < 0 { absorber = .null }
            }
        }
        guard let replaced = replacingOwnerBag(store, path: cell.ownerPath, bag: .object(owner)) else { return nil }
        let result = bridgeArrangementNative(store: replaced, topo: topo)
        let expected = Set(allocatedWindowIDs(store, topo: topo)).subtracting([windowID])
        let actual = allocatedWindowIDs(result, topo: topo)
        guard actual.count == expected.count, Set(actual) == expected else { return nil }
        return .object(["arr": result, "absorber": absorber])
    }

    /// @canonical automatic_overload_resolution -- discovered floors never eject managed members.
    /// Collapse only an infeasible containing parcel, retaining its complete prior structure for
    /// automatic restoration when the known floors fit again. A floor larger than the entire
    /// display remains explicit as unavoidable; no invented smaller app minimum is published.
    public static func resolvingAutomaticOverload(store: JSONValue, topo: JSONValue, focused: Int64?) -> JSONValue? {
        var result = store
        let normalized = Project.normTopology(topo)
        let expected = Set(allocatedWindowIDs(store, topo: topo))
        guard expected.count == allocatedWindowIDs(store, topo: topo).count else { return nil }
        func overflowing(_ arrangement: JSONValue, _ cell: AllocatedCell) -> Bool {
            guard let id = cell.topWindowID,
                  let frame = Frame.from(arrangementTargetsRec(bridge: arrangement, topo: topo).at(path: "\(id).frame")) else { return true }
            return frame.x < cell.frame.x - 0.5 || frame.y < cell.frame.y - 0.5
                || frame.maxX > cell.frame.maxX + 0.5 || frame.maxY > cell.frame.maxY + 0.5
        }
        func replaceParcel(_ arrangement: JSONValue, path: [String], display: Int64, bag: JSONValue) -> JSONValue? {
            if !path.isEmpty { return replacingOwnerBag(arrangement, path: path, bag: bag) }
            var root = arrangement.objectValue ?? [:]
            let other = bags(parseSegs(root["segments"]), normalized).filter { $0.displayId != display }.flatMap(\.segments)
            root["segments"] = .array(other.map(\.json) + (bag.at(path: "segments")?.arrayValue ?? []))
            var bindings = JSONObject((root["bindings"]?.objectValue ?? [:]).filter { !$0.key.hasPrefix("\(display):") }.map { ($0.key, $0.value) })
            for (key, value) in bag.at(path: "bindings")?.objectValue ?? [:] { bindings[key] = value }
            root["bindings"] = .object(bindings)
            return .object(root)
        }
        // Saved structure is data, never a second author: restamp it with current member floors.
        var restoredAny = true
        while restoredAny {
            restoredAny = false
            for cell in allocatedCells(result, topo: topo) {
                guard let saved = cell.binding.at(path: "overload_restore"), let oldCanvas = Frame.from(cell.binding.at(path: "overload_restore_canvas")) else { continue }
                let currentMembers = cell.binding.at(path: "contents")?.arrayValue ?? [cell.binding]
                let floors = Dictionary(uniqueKeysWithValues: currentMembers.compactMap { member -> (Int64, JSONValue)? in
                    guard let id = member.at(path: "window_id")?.intValue else { return nil }
                    return (id, member.at(path: "min_size") ?? .object([:]))
                })
                func stamp(_ value: JSONValue) -> JSONValue {
                    var bag = value.objectValue ?? [:]
                    bag["bindings"] = .object((bag["bindings"]?.objectValue ?? [:]).mapValues { value in
                        var binding = value.objectValue ?? [:]
                        if let nested = binding["nested"] { binding["nested"] = stamp(nested) }
                        if let id = binding["window_id"]?.intValue, let floor = floors[id] { binding["min_size"] = floor }
                        if let members = binding["contents"]?.arrayValue {
                            binding["contents"] = .array(members.map { value in
                                var member = value.objectValue ?? [:]
                                if let id = member["window_id"]?.intValue, let floor = floors[id] { member["min_size"] = floor }
                                return .object(member)
                            })
                        }
                        return .object(binding)
                    }); return .object(bag)
                }
                let restored = stamp(transformedOwnerBag(saved, from: oldCanvas, to: cell.frame))
                guard let replaced = replaceParcel(result, path: cell.ownerPath, display: cell.displayID, bag: restored) else { continue }
                let candidate = bridgeArrangementNative(store: replaced, topo: topo)
                let inventory = allocatedCells(candidate, topo: topo)
            if inventory.flatMap(\.memberIDs).count == expected.count, Set(inventory.flatMap(\.memberIDs)) == expected,
                   inventory.filter({ $0.displayID == cell.displayID && $0.ownerPath.starts(with: cell.ownerPath) }).allSatisfy({ !overflowing(candidate, $0) }) {
                    if result != candidate { restoredAny = true; result = candidate }
                }
            }
        }
        while let cell = allocatedCells(result, topo: topo).first(where: {
            $0.binding.at(path: "minimum_fit")?.stringValue != "unavoidable" && overflowing(result, $0)
        }) {
            var path = cell.ownerPath
            while true {
                guard let canvas = ownerCanvas(result, topo: topo, displayID: cell.displayID, path: path),
                      var owner = ownerBag(result, path: path)?.objectValue else { return nil }
                let descendants = allocatedCells(result, topo: topo).filter { $0.displayID == cell.displayID && $0.ownerPath.starts(with: path) }
                let members = descendants.flatMap { $0.binding.at(path: "contents")?.arrayValue ?? [$0.binding] }
                guard !members.isEmpty else { return nil }
                let top = focused.flatMap { focus in members.first(where: { $0.at(path: "window_id")?.intValue == focus }) } ?? members[0]
                let topID = top.at(path: "window_id")!
                let ordered = [top] + members.filter { $0.at(path: "window_id") != topID }
                let localDisplay: Int64 = path.isEmpty ? cell.displayID : 0
                var saved = owner
                if path.isEmpty {
                    saved["segments"] = .array(bags(parseSegs(owner["segments"]), normalized)
                        .first(where: { $0.displayId == cell.displayID })?.segments.map(\.json) ?? [])
                    saved["bindings"] = .object(JSONObject((owner["bindings"]?.objectValue ?? [:]).filter { $0.key.hasPrefix("\(localDisplay):") }.map { ($0.key, $0.value) }))
                }
                var binding: JSONObject = ["window_id": topID, "top_window_id": topID,
                    "contents": .array(ordered), "min_size": top.at(path: "min_size") ?? .object([:]),
                    "stack_source": .string("overload"), "overload_reason": .string("known_minimum_partition_infeasible"),
                    "overload_restore": .object(saved), "overload_restore_canvas": canvas.json]
                let topMinimum = allocationMinimum(.object(binding), frame: canvas, gap: normalized.gap)
                if path.isEmpty && (topMinimum.w > canvas.w || topMinimum.h > canvas.h) {
                    binding["overload_reason"] = .string("known_minimum_exceeds_display_canvas")
                    binding["minimum_fit"] = .string("unavoidable")
                }
                owner["segments"] = .array([]); owner["bindings"] = .object(["\(localDisplay):0:0": .object(binding)])
                guard let replaced = replaceParcel(result, path: path, display: cell.displayID, bag: .object(owner)) else { return nil }
                result = bridgeArrangementNative(store: replaced, topo: topo)
                let inventory = allocatedCells(result, topo: topo)
                guard inventory.flatMap(\.memberIDs).count == expected.count, Set(inventory.flatMap(\.memberIDs)) == expected else { return nil }
                guard let affected = inventory.first(where: { $0.memberIDs.contains(topID.intValue!) }) else { return nil }
                if !overflowing(result, affected) || path.isEmpty { break }
                path.removeLast()
            }
        }
        return result
    }
}
