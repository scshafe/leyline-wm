// Largest-first native insertion: newcomers split the largest feasible allocated
// cell, with full-set membership conservation and minimum-size feasibility.
import Foundation

extension Arrangement {
    // ── bridge_arrangement_native_adopt (S-P4) ───────────────────────────
    /// Insert arrivals with one canonical native author; unsafe batches return null atomically.
    /// Largest-first uses raw area/top/left/key order and a known-minimum feasible cut along the
    /// split axis; a floor wider than the anchor's other side is left to the bridge's re-cut or
    /// overlap. A newcomer with no feasible cut joins the anchor cell as a managed overload member.
    public static func bridgeArrangementNativeAdopt(store: JSONValue, newcomers: [Int64],
                                                    ndid: Int64, focused: JSONValue, topo: JSONValue,
                                                    newcomerMinimums: [Int64: JSONValue] = [:]) -> JSONValue {
        adoptLargestFirst(store: store, newcomers: newcomers, displayID: ndid, topo: topo,
            newcomerMinimums: newcomerMinimums, focused: focused)
    }

    // @canonical largest_first_insertion_target -- raw allocated cells, never AX frames.
    static func largestFirstInsertionRank(frame: Frame, key: String) -> JSONValue {
        .array([.double(-(frame.w * frame.h)), .double(frame.y), .double(frame.x), .string(key)])
    }

    /// @canonical largest_first_insertion_author -- the existing author handles nested and crowded cases.
    private static func adoptLargestFirst(store: JSONValue, newcomers: [Int64], displayID: Int64,
                                         topo: JSONValue, newcomerMinimums: [Int64: JSONValue],
                                         focused: JSONValue) -> JSONValue {
        let initial = allocatedWindowIDs(store, topo: topo), normalized = Project.normTopology(topo), gap = normalized.gap
        let focusedID = focused.intValue ?? focused.stringValue.flatMap { Int64($0.hasPrefix("w:") ? String($0.dropFirst(2)) : $0) }
        guard !newcomers.isEmpty, Set(newcomers).count == newcomers.count, newcomers.allSatisfy({ $0 > 0 }),
              Set(initial).count == initial.count, Set(initial).isDisjoint(with: newcomers),
              validMd(parseSegs(store.at(path: "segments")), normalized).at(path: "ok")?.boolValue == true,
              normalized.displays.contains(where: { $0.id == displayID }) else { return .null }
        var result = store
        for id in newcomers {
            let candidates = allocatedCells(result, topo: topo).filter { $0.displayID == displayID }
            guard let anchor = candidates.sortedStableBy({ largestFirstInsertionRank(frame: $0.frame,
                key: ($0.ownerPath + [$0.anchor]).joined(separator: "/")) }).first,
                  var owner = ownerBag(result, path: anchor.ownerPath)?.objectValue,
                  var bindings = owner["bindings"]?.objectValue else { return .null }
            let minimum = newcomerMinimums[id] ?? .object([:])
            guard Minsize.validStore(.object(["newcomer": minimum])) else { return .null }
            let oldMin = allocationMinimum(anchor.binding, frame: anchor.frame, gap: gap)
            let newMin = Project.leafFitMin(["min_size": minimum])
            let vertical = anchor.frame.w >= anchor.frame.h
            let displayCanvas = bags(parseSegs(result.at(path: "segments")), normalized)
                .first(where: { $0.displayId == displayID })?.rect ?? anchor.canvas
            let cut = feasibleCut(canvas: anchor.frame, vertical: vertical,
                proposed: vertical ? anchor.frame.x + anchor.frame.w / 2 : anchor.frame.y + anchor.frame.h / 2,
                lowMinimum: vertical ? oldMin.w : oldMin.h, highMinimum: vertical ? newMin.w : newMin.h,
                lowPerpendicularMinimum: 0, highPerpendicularMinimum: 0,
                gap: gap, ownerCanvas: displayCanvas)
            if let cut {
                let localDisplay: Int64 = anchor.ownerPath.isEmpty ? displayID : 0
                let local = anchor.ownerPath.isEmpty ? topo : localTopology(canvas: anchor.canvas, displayID: 0, gap: gap)
                let segments = parseSegs(owner["segments"]) + [Seg(axis: vertical ? "v" : "h", coord: cut,
                    lo: vertical ? anchor.frame.y : anchor.frame.x, hi: vertical ? anchor.frame.maxY : anchor.frame.maxX)]
                let cells = cellsMd(segments, Project.normTopology(local))
                var rebound: JSONObject = [:]
                for existing in allocatedCells(result, topo: topo) where existing.ownerPath == anchor.ownerPath {
                    guard let cell = cells.first(where: { $0.displayId == (anchor.ownerPath.isEmpty ? existing.displayID : localDisplay)
                        && $0.frame.x <= existing.frame.x + 1 && existing.frame.x + 1 < $0.frame.maxX
                        && $0.frame.y <= existing.frame.y + 1 && existing.frame.y + 1 < $0.frame.maxY }) else { return .null }
                    rebound[anchorKey(cell)] = existing.binding
                }
                // Nested siblings are opaque allocations, so rekey their complete binding by old origin.
                let oldCells = bagCells(.object(owner), topology: local)
                for (key, value) in bindings where value.at(path: "nested") != nil {
                    guard let oldCell = oldCells.first(where: { anchorKey($0) == key }),
                          let cell = cells.first(where: { $0.displayId == oldCell.displayId
                            && $0.frame.x <= oldCell.frame.x + 1 && oldCell.frame.x + 1 < $0.frame.maxX
                            && $0.frame.y <= oldCell.frame.y + 1 && oldCell.frame.y + 1 < $0.frame.maxY }) else { return .null }
                    rebound[anchorKey(cell)] = value
                }
                guard let high = cells.first(where: { $0.displayId == localDisplay
                    && abs((vertical ? $0.frame.x : $0.frame.y) - cut) <= tol
                    && (vertical ? abs($0.frame.y - anchor.frame.y) <= tol : abs($0.frame.x - anchor.frame.x) <= tol) }) else { return .null }
                var newcomer: JSONObject = ["window_id": .int(id)]
                if minimum.objectValue?.isEmpty == false { newcomer["min_size"] = minimum }
                rebound[anchorKey(high)] = .object(newcomer)
                owner["segments"] = .array(segments.map(\.json)); owner["bindings"] = .object(rebound)
            } else {
                var binding = anchor.binding.objectValue ?? [:]
                var members = binding["contents"]?.arrayValue ?? [anchor.binding]
                var newcomer: JSONObject = ["window_id": .int(id), "presented": .bool(false), "frame": .null]
                if minimum.objectValue?.isEmpty == false { newcomer["min_size"] = minimum }
                if focusedID == id {
                    members.insert(.object(newcomer), at: 0); binding["window_id"] = .int(id)
                    binding["min_size"] = minimum
                } else { members.append(.object(newcomer)) }
                binding["contents"] = .array(members); binding["top_window_id"] = binding["window_id"]
                binding["stack_source"] = .string("overload")
                binding["overload_reason"] = .string("minimum_interval_empty")
                bindings[anchor.anchor] = .object(binding); owner["bindings"] = .object(bindings)
            }
            guard let replaced = replacingOwnerBag(result, path: anchor.ownerPath, bag: .object(owner)) else { return .null }
            guard let resolved = resolvingAutomaticOverload(store: bridgeArrangementNative(store: replaced, topo: topo),
                                                            topo: topo, focused: focusedID) else { return .null }
            result = resolved
            let all = allocatedWindowIDs(result, topo: topo)
            guard Set(all).count == all.count, Set(all) == Set(initial + newcomers.prefix(through: newcomers.firstIndex(of: id)!)) else { return .null }
        }
        return result
    }
}
