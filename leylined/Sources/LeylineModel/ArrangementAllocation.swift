import Foundation

public extension Array where Element == Arrangement.AllocatedCell {
    /// The leaf whose presented (top) member is `id`.
    func topped(by id: Int64) -> Element? { first { $0.topWindowID == id } }
    /// The leaf whose stack contains `id`, presented or hidden.
    func containing(_ id: Int64) -> Element? { first { $0.memberIDs.contains(id) } }
}

public extension Array where Element == JSONValue {
    /// The window record with this id; the first match wins.
    func window(_ id: Int64) -> JSONValue? { first { $0.at(path: "window_id")?.intValue == id } }
    /// Every record's window id, in order, skipping records without one.
    var windowIDs: [Int64] { compactMap { $0.at(path: "window_id")?.intValue } }
}

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
            return contents.windowIDs
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
        for bag in bags(parseSegs(store.at(path: "segments")), T) {
            guard let canvas = bag.rect, let display = bag.displayId else { continue }
            var root = store.objectValue ?? [:]
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
        return check(store, topology: topo)
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

    /// Rekey each leaf after `indices` of `segments` moved by `distance`: a cell edge lying on the
    /// moved run shifts with it and every other edge stays, so each leaf keeps its own cell however
    /// far the line moves, even when the move reorders cells (cellsMd sorts by y, then x).
    public static func reboundAfterTranslation(_ bindings: JSONObject, segments: [Seg], indices: [Int], distance: Double,
                                               from oldCells: [Comp], to newCells: [Comp]) -> JSONObject? {
        guard oldCells.count == newCells.count, let first = indices.first else { return nil }
        let vertical = segments[first].axis == "v", coordinate = segments[first].coord
        let lo = indices.map { segments[$0].lo }.min()!, hi = indices.map { segments[$0].hi }.max()!
        func shifted(_ edge: Double, _ from: Double, _ to: Double) -> Double {
            abs(edge - coordinate) <= tol && from >= lo - tol && to <= hi + tol ? edge + distance : edge
        }
        var rebound: JSONObject = [:], claimed = Set<Int>()
        for cell in oldCells {
            guard let binding = bindings[anchorKey(cell)] else { continue }
            let f = cell.frame
            let expected: Frame
            if vertical {
                let x0 = shifted(f.x, f.y, f.maxY), x1 = shifted(f.maxX, f.y, f.maxY)
                expected = Frame(x: x0, y: f.y, w: x1 - x0, h: f.h)
            } else {
                let y0 = shifted(f.y, f.x, f.maxX), y1 = shifted(f.maxY, f.x, f.maxX)
                expected = Frame(x: f.x, y: y0, w: f.w, h: y1 - y0)
            }
            guard let index = newCells.indices.first(where: { Geometry.frameEq(newCells[$0].frame, expected, tol: tol) }),
                  claimed.insert(index).inserted else { return nil }
            rebound[anchorKey(newCells[index])] = binding
        }
        return rebound
    }

    /// The nearest a cut may come to `edge` while leaving `minimum` plus the half-gap
    /// inset beside it; the inset is waived when the edge lies on the owner canvas.
    /// Evaluated left to right exactly as the callers once spelled it, so the raw
    /// half-point coordinates the native bridge rounds are unchanged.
    static func cutBound(edge: Double, ownerEdge: Double, minimum: Double, gap: Double, low: Bool) -> Double {
        let inset = abs(edge - ownerEdge) <= tol ? 0 : gap / 2
        return low ? edge + inset + gap / 2 + minimum : edge - inset - gap / 2 - minimum
    }

    /// Slide a span inside [low, high] without changing its length; the two
    /// corrections apply in order, so a span longer than the bounds ends flush with `high`.
    static func slid(_ span: (lo: Double, hi: Double), into low: Double, _ high: Double) -> (lo: Double, hi: Double) {
        var (lo, hi) = span
        if lo < low { hi += low - lo; lo = low }
        if hi > high { lo -= hi - high; hi = high }
        return (lo, hi)
    }

    /// @canonical known_minimum_recut -- re-solve a parcel's lines against known floors, retaining
    /// every opaque binding. Each line moves the least distance into the interval its adjoining
    /// cells' floors allow: alone when the partition stays rectangular, otherwise with its collinear
    /// run. A line whose interval is still empty waits for its neighbours to move. A nil result
    /// means some line stays infeasible; `partial` instead keeps every move that fits and leaves
    /// infeasible lines where they are, so overlap covers only what no cut can.
    static func fittingOwnerMinimums(_ bag: JSONValue, canvas: Frame, frameCanvas: Frame,
                                     gap: Double, displayID: Int64 = 0, partial: Bool = false) -> JSONValue? {
        let topology = localTopology(canvas: canvas, displayID: displayID, gap: gap), T = Project.normTopology(topology)
        /// The cut interval of `indices` spanning [lo, hi], or nil when its floors leave none.
        func interval(_ cells: [Comp], _ bindings: JSONObject, axis: String, coordinate: Double,
                      lo: Double, hi: Double) -> (lower: Double, upper: Double)? {
            let vertical = axis == "v"
            let lows = cells.filter { abs((vertical ? $0.frame.maxX : $0.frame.maxY) - coordinate) <= tol
                && min(vertical ? $0.frame.maxY : $0.frame.maxX, hi) - max(vertical ? $0.frame.y : $0.frame.x, lo) > tol }
            let highs = cells.filter { abs((vertical ? $0.frame.x : $0.frame.y) - coordinate) <= tol
                && min(vertical ? $0.frame.maxY : $0.frame.maxX, hi) - max(vertical ? $0.frame.y : $0.frame.x, lo) > tol }
            var lower = -Double.infinity, upper = Double.infinity
            for low in lows {
                let minimum = allocationMinimum(bindings[anchorKey(low)] ?? .object([:]), frame: low.frame, gap: gap)
                lower = max(lower, cutBound(edge: vertical ? low.frame.x : low.frame.y,
                                            ownerEdge: vertical ? frameCanvas.x : frameCanvas.y,
                                            minimum: vertical ? minimum.w : minimum.h, gap: gap, low: true))
            }
            for high in highs {
                let minimum = allocationMinimum(bindings[anchorKey(high)] ?? .object([:]), frame: high.frame, gap: gap)
                upper = min(upper, cutBound(edge: vertical ? high.frame.maxX : high.frame.maxY,
                                            ownerEdge: vertical ? frameCanvas.maxX : frameCanvas.maxY,
                                            minimum: vertical ? minimum.w : minimum.h, gap: gap, low: false))
            }
            return lower <= upper ? (lower, upper) : nil
        }
        /// The partition with `indices` translated, or nil when it is no longer rectangular.
        func translated(_ result: JSONValue, _ segments: [Seg], _ cells: [Comp], indices: [Int], distance: Double) -> JSONValue? {
            let moved = translatedSegments(segments, indices: indices, distance: distance)
            guard validMd(moved, T).at(path: "ok")?.boolValue == true,
                  let rebound = reboundAfterTranslation(result.at(path: "bindings")?.objectValue ?? [:], segments: segments,
                      indices: indices, distance: distance, from: cells, to: cellsMd(moved, T)) else { return nil }
            var object = result.objectValue ?? [:]; object["segments"] = .array(moved.map(\.json)); object["bindings"] = .object(rebound)
            return .object(object)
        }
        var result = bag, seen = Set<String>()
        while seen.insert(result.canonical()).inserted {
            var changed = false, blocked = false
            // Inner splits first: a same-axis line inside a parcel is no longer than the lines
            // bounding it, so a parent line moves only when the inner ones cannot make room.
            let order = parseSegs(result.at(path: "segments")).enumerated()
                .sorted { ($0.element.hi - $0.element.lo, $0.offset) < ($1.element.hi - $1.element.lo, $1.offset) }.map(\.offset)
            for selected in order {
                let segments = parseSegs(result.at(path: "segments"))
                guard segments.indices.contains(selected) else { return nil }
                let cells = cellsMd(segments, T), bindings = result.at(path: "bindings")?.objectValue ?? [:]
                let axis = segments[selected].axis, coordinate = segments[selected].coord
                if let own = interval(cells, bindings, axis: axis, coordinate: coordinate,
                                      lo: segments[selected].lo, hi: segments[selected].hi) {
                    let cut = min(max(coordinate, own.lower), own.upper)
                    if abs(cut - coordinate) <= cutEpsilon { continue }
                    if let moved = translated(result, segments, cells, indices: [selected], distance: cut - coordinate) {
                        result = moved; changed = true; continue
                    }
                }
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
                guard let run = interval(cells, bindings, axis: axis, coordinate: coordinate, lo: lo, hi: hi) else {
                    blocked = true; continue
                }
                let cut = min(max(coordinate, run.lower), run.upper)
                if abs(cut - coordinate) <= cutEpsilon { continue }
                guard let moved = translated(result, segments, cells, indices: indices, distance: cut - coordinate) else { return nil }
                result = moved; changed = true
            }
            if !changed { return blocked && !partial ? nil : result }
        }
        return partial ? result : nil
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
            guard let cell = bagCells(bag, topology: local).first(where: { anchorKey($0) == anchor }),
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

    /// @canonical parcel_tree_rewrite -- the one descent over a parcel's bindings, its
    /// nested parcels and every stack member. `parcel` sees each bag (the root and every
    /// nested one), `binding` each binding after its nested parcel was rewritten, and
    /// `member` each `contents` record. A value that is not an object is left as it is.
    public static func mapBindingTree(_ bag: JSONValue, parcel: (inout JSONObject) -> Void = { _ in },
                                      binding: (inout JSONObject) -> Void,
                                      member: (inout JSONObject) -> Void = { _ in }) -> JSONValue {
        guard var object = bag.objectValue else { return bag }
        parcel(&object)
        object["bindings"] = .object((object["bindings"]?.objectValue ?? [:]).mapValues { value in
            guard var entry = value.objectValue else { return value }
            if let nested = entry["nested"] {
                entry["nested"] = mapBindingTree(nested, parcel: parcel, binding: binding, member: member)
            }
            binding(&entry)
            if let members = entry["contents"]?.arrayValue {
                entry["contents"] = .array(members.map { value in
                    guard var record = value.objectValue else { return value }
                    member(&record)
                    return .object(record)
                })
            }
            return .object(entry)
        })
        return .object(object)
    }

    /// Reframe a child parcel through its sole downward interface: its allocation.
    public static func transformedOwnerBag(_ bag: JSONValue, from old: Frame, to new: Frame) -> JSONValue {
        guard old.w > 0, old.h > 0 else { return bag }
        func x(_ value: Double) -> Double { new.x + (value - old.x) * new.w / old.w }
        func y(_ value: Double) -> Double { new.y + (value - old.y) * new.h / old.h }
        func frame(_ value: JSONValue?) -> JSONValue? {
            guard let f = Frame.from(value) else { return value }
            return Frame(x: x(f.x), y: y(f.y), w: f.w * new.w / old.w, h: f.h * new.h / old.h).json
        }
        return mapBindingTree(bag, parcel: { result in
            result["segments"] = .array(parseSegs(result["segments"]).map { original in
                var segment = original
                segment.coord = segment.axis == "v" ? x(segment.coord) : y(segment.coord)
                segment.lo = segment.axis == "v" ? y(segment.lo) : x(segment.lo)
                segment.hi = segment.axis == "v" ? y(segment.hi) : x(segment.hi)
                return segment.json
            })
        }, binding: { binding in
            if let f = frame(binding["frame"]) { binding["frame"] = f }
            if let f = frame(binding["allocated_frame"]) { binding["allocated_frame"] = f }
        })
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
        let perpendicular = insetInterior(canvas, ownerCanvas, gap)
        let perpendicularSize = vertical ? perpendicular.h : perpendicular.w
        guard fits(max(lowPerpendicularMinimum, highPerpendicularMinimum), in: perpendicularSize) else { return nil }
        // Raw allocation coordinates preserve the existing half-point geometry.
        // The native bridge uses these same exact coordinates for target insets.
        let lower = cutBound(edge: origin, ownerEdge: ownerOrigin, minimum: lowMinimum, gap: gap, low: true)
        let upper = cutBound(edge: end, ownerEdge: ownerEnd, minimum: highMinimum, gap: gap, low: false)
        let boundedLower = max(lower, origin + tol + 1), boundedUpper = min(upper, end - tol - 1)
        guard boundedLower <= boundedUpper else { return nil }
        return CutInterval(lower: boundedLower, upper: boundedUpper)
    }

    /// Select an exact overload member; changing the top never discards sibling members.
    public static func selectingMember(store: JSONValue, windowID: Int64, topo: JSONValue) -> JSONValue? {
        guard let cell = allocatedCells(store, topo: topo).containing(windowID),
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
    public static func pruneAllocatedWindow(store: JSONValue, windowID: Int64, topo: JSONValue) -> JSONValue? {
        guard let cell = allocatedCells(store, topo: topo).containing(windowID),
              var owner = ownerBag(store, path: cell.ownerPath)?.objectValue,
              var bindings = owner["bindings"]?.objectValue else { return nil }
        let gap = Project.normTopology(topo).gap
        let local = cell.ownerPath.isEmpty ? topo : localTopology(canvas: cell.canvas, displayID: 0, gap: gap)
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
                    topo: localTopology(canvas: canvas, displayID: cell.ownerPath.isEmpty ? cell.displayID : 0, gap: gap)),
               let restored = retired.at(path: "arr") {
                binding["overload_restore"] = restored; bindings[cell.anchor] = .object(binding)
            }
            owner["bindings"] = .object(bindings); absorber = .int(top)
        } else {
            let rawCells = bagCells(.object(owner), topology: local)
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
                let pruned = bridgeArrangementNativePrune(store: .object(authored), goners: [windowID], topo: local)
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

    /// @canonical minimum_overlap_growth -- a window whose known minimum exceeds its tile keeps
    /// the partition. It grows only across cuts that split its own band, anchored at the edges
    /// it does not share, so it overlaps only the windows those cuts separate. Nil when the
    /// minimum cannot fit that region or no edge is shared; displaced growth then applies.
    static func minimumGrowth(allocation: Frame, frame: Frame, canvas: Frame, frameCanvas: Frame,
                              segments: [Seg], minimum: (w: Double, h: Double), gap: Double) -> Frame? {
        /// The collinear run of cuts on `axis` at `coord` that touches the band [lo, hi].
        func run(_ axis: String, _ coord: Double, _ lo: Double, _ hi: Double) -> (lo: Double, hi: Double)? {
            let pieces = segments.filter { $0.axis == axis && abs($0.coord - coord) <= tol }
            var span: (lo: Double, hi: Double)?
            var grew = true
            while grew {
                grew = false
                for piece in pieces {
                    let low = span?.lo ?? lo, high = span?.hi ?? hi
                    let touches = span == nil ? piece.lo < high - tol && piece.hi > low + tol
                                              : piece.lo <= high + tol && piece.hi >= low - tol
                    guard touches, span.map({ piece.lo < $0.lo - tol || piece.hi > $0.hi + tol }) ?? true else { continue }
                    span = (min(span?.lo ?? piece.lo, piece.lo), max(span?.hi ?? piece.hi, piece.hi)); grew = true
                }
            }
            return span
        }
        func axisRange(horizontal: Bool) -> (lo: Double, hi: Double)? {
            let axis = horizontal ? "v" : "h"
            let a0 = horizontal ? allocation.x : allocation.y, a1 = horizontal ? allocation.maxX : allocation.maxY
            let b0 = horizontal ? allocation.y : allocation.x, b1 = horizontal ? allocation.maxY : allocation.maxX
            let c0 = horizontal ? canvas.x : canvas.y, c1 = horizontal ? canvas.maxX : canvas.maxY
            let f0 = horizontal ? frame.x : frame.y, f1 = horizontal ? frame.maxX : frame.maxY
            let need = horizontal ? minimum.w : minimum.h
            if fits(need, in: f1 - f0) { return (f0, f1) }
            // A cut no longer than this band splits only it; a longer line bounds a larger parcel.
            func shared(_ coord: Double) -> Bool {
                guard abs(coord - c0) > tol, abs(coord - c1) > tol, let line = run(axis, coord, b0, b1) else { return false }
                return line.lo >= b0 - tol && line.hi <= b1 + tol
            }
            func bound(beyond coord: Double, lower: Bool) -> Double {
                let lines = Set(segments.filter { $0.axis == axis && (lower ? $0.coord < coord - tol : $0.coord > coord + tol) }.map(\.coord))
                    .filter { c in run(axis, c, b0, b1).map { $0.lo <= b0 + tol && $0.hi >= b1 - tol
                        && ($0.lo < b0 - tol || $0.hi > b1 + tol) } ?? false }
                return lower ? (lines.max() ?? c0) : (lines.min() ?? c1)
            }
            let lowShared = shared(a0), highShared = shared(a1)
            guard lowShared || highShared else { return nil }
            let r0 = lowShared ? bound(beyond: a0, lower: true) : a0
            let r1 = highShared ? bound(beyond: a1, lower: false) : a1
            let region = insetInterior(horizontal ? Frame(x: r0, y: allocation.y, w: r1 - r0, h: allocation.h)
                                                  : Frame(x: allocation.x, y: r0, w: allocation.w, h: r1 - r0), frameCanvas, gap)
            let i0 = horizontal ? region.x : region.y, i1 = horizontal ? region.maxX : region.maxY
            guard fits(need, in: i1 - i0) else { return nil }
            if lowShared && highShared {
                let extra = need - (f1 - f0)
                return slid((f0 - extra / 2, f1 + extra / 2), into: i0, i1)
            }
            return lowShared ? (f1 - need, f1) : (f0, f0 + need)
        }
        guard let x = axisRange(horizontal: true), let y = axisRange(horizontal: false) else { return nil }
        return Frame(x: x.lo, y: y.lo, w: x.hi - x.lo, h: y.hi - y.lo)
    }

    /// @canonical minimum_displaced_growth -- the last resort before stacking: no cut fits every
    /// floor and the window's own split cannot hold it, so it grows from the display edges it
    /// touches (both ways when it touches neither), staying on the display and overlapping its
    /// neighbours. Nil when the minimum exceeds the display; overload resolution then applies.
    static func displacedGrowth(frame: Frame, frameCanvas: Frame, minimum: (w: Double, h: Double)) -> Frame? {
        func axis(_ f0: Double, _ f1: Double, _ c0: Double, _ c1: Double, _ need: Double) -> (lo: Double, hi: Double)? {
            if fits(need, in: f1 - f0) { return (f0, f1) }
            guard fits(need, in: c1 - c0) else { return nil }
            let low = abs(f0 - c0) <= tol, high = abs(f1 - c1) <= tol
            var lo = low || !high ? f0 : f1 - need, hi = lo + need
            if !low && !high { lo = f0 - (need - (f1 - f0)) / 2; hi = lo + need }
            return slid((lo, hi), into: c0, c1)
        }
        guard let x = axis(frame.x, frame.maxX, frameCanvas.x, frameCanvas.maxX, minimum.w),
              let y = axis(frame.y, frame.maxY, frameCanvas.y, frameCanvas.maxY, minimum.h) else { return nil }
        return Frame(x: x.lo, y: y.lo, w: x.hi - x.lo, h: y.hi - y.lo)
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
            return frame.x < cell.frame.x - fitSlack || frame.y < cell.frame.y - fitSlack
                || frame.maxX > cell.frame.maxX + fitSlack || frame.maxY > cell.frame.maxY + fitSlack
        }
        func replaceParcel(_ arrangement: JSONValue, path: [String], display: Int64, bag: JSONValue) -> JSONValue? {
            if !path.isEmpty { return replacingOwnerBag(arrangement, path: path, bag: bag) }
            var root = arrangement.objectValue ?? [:]
            let other = bags(parseSegs(root["segments"]), normalized).filter { $0.displayId != display }.flatMap(\.segments)
            root["segments"] = .array(other.map(\.json) + (bag.at(path: "segments")?.arrayValue ?? []))
            var bindings = (root["bindings"]?.objectValue ?? [:]).filter { !$0.key.hasPrefix("\(display):") }
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
                // A current member's floor (or {} when it has none) replaces whatever the saved structure recorded.
                let stampFloor: (inout JSONObject) -> Void = { record in
                    if let id = record["window_id"]?.intValue, let floor = floors[id] { record["min_size"] = floor }
                }
                let restored = mapBindingTree(transformedOwnerBag(saved, from: oldCanvas, to: cell.frame),
                                              binding: stampFloor, member: stampFloor)
                guard let replaced = replaceParcel(result, path: cell.ownerPath, display: cell.displayID, bag: restored) else { continue }
                let candidate = bridgeArrangementNative(store: replaced, topo: topo)
                let inventory = allocatedCells(candidate, topo: topo)
            if inventory.flatMap(\.memberIDs).count == expected.count, Set(inventory.flatMap(\.memberIDs)) == expected,
                   inventory.filter({ $0.displayID == cell.displayID && $0.ownerPath.starts(with: cell.ownerPath) }).allSatisfy({
                       $0.binding.at(path: "minimum_fit")?.stringValue == "overlap" || !overflowing(candidate, $0) }) {
                    if result != candidate { restoredAny = true; result = candidate }
                }
            }
        }
        while let cell = allocatedCells(result, topo: topo).first(where: {
            !["unavoidable", "overlap"].contains($0.binding.at(path: "minimum_fit")?.stringValue ?? "") && overflowing(result, $0)
        }) {
            var path = cell.ownerPath
            while true {
                guard let canvas = ownerCanvas(result, topo: topo, displayID: cell.displayID, path: path),
                      var owner = ownerBag(result, path: path)?.objectValue else { return nil }
                let descendants = allocatedCells(result, topo: topo).filter { $0.displayID == cell.displayID && $0.ownerPath.starts(with: path) }
                let members = descendants.flatMap { $0.binding.at(path: "contents")?.arrayValue ?? [$0.binding] }
                guard !members.isEmpty else { return nil }
                let top = focused.flatMap { focus in members.window(focus) } ?? members[0]
                let topID = top.at(path: "window_id")!
                let ordered = [top] + members.filter { $0.at(path: "window_id") != topID }
                let localDisplay: Int64 = path.isEmpty ? cell.displayID : 0
                var saved = owner
                if path.isEmpty {
                    saved["segments"] = .array(bags(parseSegs(owner["segments"]), normalized)
                        .first(where: { $0.displayId == cell.displayID })?.segments.map(\.json) ?? [])
                    saved["bindings"] = .object((owner["bindings"]?.objectValue ?? [:]).filter { $0.key.hasPrefix("\(localDisplay):") })
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
                guard let affected = inventory.containing(topID.intValue!) else { return nil }
                if !overflowing(result, affected) || path.isEmpty { break }
                path.removeLast()
            }
        }
        return result
    }
}
