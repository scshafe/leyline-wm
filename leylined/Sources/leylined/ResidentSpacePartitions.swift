import Foundation
import LeylineModel

/// @canonical resident_space_partition_cache -- dormant actual OS Spaces remain in the model checkpoint.
/// This is a routing/cache lens over Arrangement; ResidentPlanner remains the sole geometry author.
/// Missing identities, duplicate membership and unsupported shapes return explicit refusals.
enum ResidentSpacePartitions {
    struct Failure: Error { let reason: String }
    struct Context {
        let displayID: Int64
        let uuid: String
        let spaceKey: String
        let enabled: Bool
        var partitionKey: String { "\(displayID):\(uuid)" }
        var visibleValue: JSONValue {
            .object(["partition_key": .string(partitionKey), "space_enabled": .bool(enabled)])
        }
    }
    struct Prepared {
        let contexts: [Context]
        let topology: JSONValue
        let epoch: String
        let observed: [JSONValue]
        let arrangement: JSONValue
        let partitions: JSONObject
        let priorVisible: JSONValue?
        var visible: JSONValue {
            .object(JSONObject(unordered: Dictionary(uniqueKeysWithValues: contexts.map {
                (String($0.displayID), $0.visibleValue)
            })))
        }
        var contextChanged: Bool { priorVisible != visible }

        /// Cache each authored visible partition, including both sides of a keyboard move.
        /// OFF and inactive entries are copied verbatim and receive no fresh membership inference.
        func checkpoint(arrangement: JSONValue) -> JSONValue? {
            guard ResidentSpacePartitions.conserved(arrangement, observed: observed) else { return nil }
            var entries = partitions
            let identityByID = Dictionary(uniqueKeysWithValues: observed.compactMap { window -> (String, JSONValue)? in
                guard let id = window.at(path: "window_id")?.intValue,
                      let fingerprint = ResidentSpacePartitions.fingerprint(window) else { return nil }
                return (String(id), fingerprint)
            })
            for context in contexts where context.enabled {
                guard let part = ResidentSpacePartitions.extract(arrangement, displayID: context.displayID, topology: topology) else { return nil }
                let ids = ResidentSpacePartitions.windowIDs(part)
                var identities: JSONObject = [:]
                for id in ids {
                    guard let fingerprint = identityByID[String(id)] else { return nil }
                    identities[String(id)] = fingerprint
                }
                entries[context.partitionKey] = .object([
                    "display_id": .int(context.displayID), "space_uuid": .string(context.uuid),
                    "space_key": .string(context.spaceKey), "observer_epoch": .string(epoch),
                    "display_geometry": ResidentSpacePartitions.displayGeometry(topology, context.displayID),
                    "arrangement": part, "window_identities": .object(identities),
                ])
            }
            return .object(["schema": .string("leyline/resident-space-partitions/v1"),
                "visible": visible, "partitions": .object(entries)])
        }
    }

    struct ObservedContexts {
        let epoch: String
        let contexts: [Context]
        let windowsByDisplay: [Int64: [JSONValue]]
    }

    /// Validate current OS Space membership and positive lifetime identities without
    /// requiring saved layout geometry. Focus-only navigation and prepare share this gate.
    static func observedContexts(world: JSONValue, topology: JSONValue,
                                 observed: [JSONValue]) -> Result<ObservedContexts, Failure> {
        func refused(_ reason: String) -> Result<ObservedContexts, Failure> { .failure(Failure(reason: reason)) }
        guard let epoch = world.at(path: "observer_epoch")?.stringValue, !epoch.isEmpty else {
            return refused("observer_epoch_unavailable")
        }
        guard let rawContexts = world.at(path: "space_contexts")?.arrayValue, !rawContexts.isEmpty else {
            return refused("space_contexts_unavailable")
        }
        let liveDisplays = Set(Project.normTopology(topology).displays.compactMap(\.id))
        var contexts: [Context] = []
        for raw in rawContexts where raw.at(path: "space_visible")?.boolValue == true {
            guard raw.at(path: "space_identity_available")?.boolValue == true,
                  let display = raw.at(path: "display_id")?.intValue, liveDisplays.contains(display),
                  let uuid = raw.at(path: "space_uuid")?.stringValue, !uuid.isEmpty,
                  uuid != "space:unknown", !uuid.hasPrefix("space:runtime:"),
                  let key = raw.at(path: "space_key")?.stringValue, !key.isEmpty,
                  let enabled = raw.at(path: "space_enabled")?.boolValue else {
                return refused("space_identity_unavailable")
            }
            contexts.append(Context(displayID: display, uuid: uuid, spaceKey: key, enabled: enabled))
        }
        guard !contexts.isEmpty, Set(contexts.map(\.displayID)).count == contexts.count,
              Set(contexts.map(\.displayID)) == liveDisplays else { return refused("space_contexts_ambiguous_or_incomplete") }
        contexts.sort { $0.displayID < $1.displayID }
        var observedByDisplay: [Int64: [JSONValue]] = [:]
        var seen: Set<Int64> = []
        for window in observed {
            guard let id = window.at(path: "window_id")?.intValue, id > 0, seen.insert(id).inserted,
                  fingerprint(window) != nil,
                  let display = window.at(path: "display")?.intValue ?? window.at(path: "display_id")?.intValue,
                  let context = contexts.first(where: { $0.displayID == display && $0.enabled }),
                  window.at(path: "space_identity_available")?.boolValue == true,
                  window.at(path: "space_visible")?.boolValue == true,
                  window.at(path: "space_key")?.stringValue == context.spaceKey,
                  window.at(path: "space_uuid")?.stringValue == context.uuid else {
                return refused("window_space_membership_or_identity_invalid")
            }
            observedByDisplay[display, default: []].append(window)
        }
        return .success(ObservedContexts(epoch: epoch, contexts: contexts, windowsByDisplay: observedByDisplay))
    }

    /// Prepare a composite of enabled visible actual Spaces. Reconcile validates cached lifetimes
    /// before pruning/adopting; commands require an already reconciled, identical membership context.
    static func prepare(state: JSONValue, world: JSONValue, topology: JSONValue,
                        observed: [JSONValue], reconcile: Bool) -> Result<Prepared, Failure> {
        func refused(_ reason: String) -> Result<Prepared, Failure> { .failure(Failure(reason: reason)) }
        let live: ObservedContexts
        switch observedContexts(world: world, topology: topology, observed: observed) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): live = value
        }
        let epoch = live.epoch, contexts = live.contexts, observedByDisplay = live.windowsByDisplay
        let cache = state.at(path: "space_partitions")
        if let cache {
            guard cache.at(path: "schema")?.stringValue == "leyline/resident-space-partitions/v1",
                  cache.at(path: "partitions")?.objectValue != nil, cache.at(path: "visible")?.objectValue != nil else {
                return refused("space_partition_checkpoint_invalid")
            }
        }
        let partitions = cache?.at(path: "partitions")?.objectValue ?? [:]
        let priorVisible = cache?.at(path: "visible")
        var ready: [JSONValue] = []
        for context in contexts where context.enabled {
            let windows = observedByDisplay[context.displayID] ?? []
            let subset = subsetTopology(topology, displayID: context.displayID)
            let cached = partitions[context.partitionKey]
            if let cached {
                guard cached.at(path: "display_id")?.intValue == context.displayID,
                      cached.at(path: "space_uuid")?.stringValue == context.uuid,
                      cached.at(path: "arrangement")?.objectValue != nil,
                      cached.at(path: "window_identities")?.objectValue != nil else {
                    return refused("space_partition_checkpoint_invalid")
                }
            }
            var base = cached?.at(path: "arrangement") ?? ResidentPlanner.emptyArrangement
            let sameEpoch = cached?.at(path: "observer_epoch")?.stringValue == epoch
            let sameGeometry = cached?.at(path: "display_geometry") == displayGeometry(topology, context.displayID)
            // Validate cached structure in the geometry that authored it. A
            // Dock/usable-frame change can put valid old endpoints outside the
            // new canvas; that does not make the checkpoint corrupt.
            let validationTopology: JSONValue
            if let cached, !sameGeometry {
                guard let recorded = recordedTopology(cached.at(path: "display_geometry"),
                    displayID: context.displayID, current: subset) else { return refused("space_partition_geometry_invalid") }
                validationTopology = recorded
            } else { validationTopology = subset }
            guard Arrangement.allocationValid(base, topo: validationTopology) else { return refused("space_partition_shape_unsupported") }
            if !sameEpoch || !sameGeometry { base = ResidentPlanner.emptyArrangement }
            let identities = cached?.at(path: "window_identities")?.objectValue ?? [:]
            // A world re-observation renews every lifetime at once. Reconcile keeps
            // the tile of a window whose owner and ID are unchanged and whose frame
            // still covers that tile (a minimum may enlarge it); a displaced or
            // reowned renewal re-enters as a newcomer.
            let targets = reconcile && sameEpoch && sameGeometry
                ? Arrangement.arrangementTargetsRec(bridge: Arrangement.bridgeArrangementNative(store: base, topo: subset),
                                                    topo: subset).objectValue ?? [:] : [:]
            let survivors = windows.filter { window in
                guard sameEpoch, sameGeometry else { return false }
                guard let id = window.at(path: "window_id")?.intValue else { return false }
                if identities[String(id)] == fingerprint(window) { return true }
                guard let target = Frame.from(targets[String(id)]?.at(path: "effect_frame") ?? targets[String(id)]?.at(path: "frame")),
                      let frame = Frame.from(window.at(path: "frame")),
                      let pid = window.at(path: "pid")?.intValue,
                      identities[String(id)]?.at(path: "pid")?.intValue == pid else { return false }
                return frame.x <= target.x + renewedTileTolerance && frame.y <= target.y + renewedTileTolerance
                    && frame.maxX >= target.maxX - renewedTileTolerance && frame.maxY >= target.maxY - renewedTileTolerance
            }
            if reconcile {
                // First retire absent/reused identities; only then may replacements re-enter as newcomers.
                // No current lifetime may inherit an entirely retired partition. Its
                // validated old shape need not support successive vacancy reclamation.
                let retired = survivors.isEmpty ? ResidentPlanner.emptyArrangement : ResidentPlanner.settle(
                    arrangement: base, observed: survivors, topology: subset, focus: world.at(path: "focused_window_id")?.intValue)
                guard let retired,
                      let settled = ResidentPlanner.settle(arrangement: retired, observed: windows, topology: subset,
                                                          focus: world.at(path: "focused_window_id")?.intValue) else {
                    return refused("native_settle_shape_or_constraints_unsupported")
                }
                ready.append(settled)
            } else {
                guard cached != nil, sameEpoch, sameGeometry,
                      Set(survivors.windowIDs) == Set(windows.windowIDs),
                      conserved(base, observed: windows),
                      Arrangement.segmentsValid(Arrangement.parseSegs(base.at(path: "segments")), topology: subset) else {
                    return refused("space_partitions_require_reconcile")
                }
                ready.append(Arrangement.bridgeArrangementNative(store: base, topo: subset))
            }
        }
        guard let combined = compose(ready, topology: topology), conserved(combined, observed: observed) else {
            return refused("space_partition_conservation_failed")
        }
        let prepared = Prepared(contexts: contexts, topology: topology, epoch: epoch, observed: observed,
            arrangement: combined, partitions: partitions, priorVisible: priorVisible)
        if !reconcile && prepared.contextChanged { return refused("space_partitions_require_reconcile") }
        return .success(prepared)
    }

    /// Edge slack for a renewed window still covering its tile: integer landing
    /// and app size snapping, far below any displacement.
    static let renewedTileTolerance = 4.0

    private static func fingerprint(_ window: JSONValue) -> JSONValue? {
        guard let pid = window.at(path: "pid")?.intValue, pid > 0,
              let generation = window.at(path: "window_generation")?.intValue, generation > 0 else { return nil }
        return .object(["pid": .int(pid), "window_generation": .int(generation)])
    }
    private static func windowIDs(_ arrangement: JSONValue) -> [Int64] {
        Arrangement.memberWindows(arrangement).windowIDs
    }
    private static func uniqueIDs(_ arrangement: JSONValue) -> Bool {
        let ids = windowIDs(arrangement)
        func consistent(_ bag: JSONValue) -> Bool {
            (bag.at(path: "off_top")?.arrayValue ?? []).isEmpty && (bag.at(path: "bindings")?.objectValue ?? [:]).values.allSatisfy { binding in
                if let nested = binding.at(path: "nested") { return nested.objectValue != nil && consistent(nested) }
                let members = Arrangement.memberIDs(binding)
                return !members.isEmpty && members.allSatisfy({ $0 > 0 })
                    && binding.at(path: "window_id")?.intValue == members.first
            }
        }
        return Set(ids).count == ids.count && consistent(arrangement)
    }
    private static func conserved(_ arrangement: JSONValue, observed: [JSONValue]) -> Bool {
        uniqueIDs(arrangement) && Set(windowIDs(arrangement)) == Set(observed.windowIDs)
    }
    private static func displayGeometry(_ topology: JSONValue, _ displayID: Int64) -> JSONValue {
        guard let display = (topology.at(path: "displays")?.arrayValue ?? []).first(where: { $0.at(path: "id")?.intValue == displayID }) else { return .null }
        return .object(["frame": display.at(path: "frame") ?? .null, "usable": display.at(path: "usable") ?? display.at(path: "frame") ?? .null,
                        "outer_gap": .double(Project.normTopology(topology).outerGap)])
    }
    private static func subsetTopology(_ topology: JSONValue, displayID: Int64) -> JSONValue {
        var value = topology.objectValue ?? [:]
        value["displays"] = .array((topology.at(path: "displays")?.arrayValue ?? []).filter { $0.at(path: "id")?.intValue == displayID })
        return .object(value)
    }
    private static func recordedTopology(_ geometry: JSONValue?, displayID: Int64, current: JSONValue) -> JSONValue? {
        guard let frame = Frame.from(geometry?.at(path: "frame")),
              let usable = Frame.from(geometry?.at(path: "usable")),
              let outer = geometry?.at(path: "outer_gap")?.numberValue,
              [frame.x, frame.y, frame.w, frame.h, usable.x, usable.y, usable.w, usable.h, outer].allSatisfy(\.isFinite),
              frame.w > 0, frame.h > 0, usable.w > 0, usable.h > 0, outer >= 0,
              usable.x >= frame.x, usable.y >= frame.y,
              usable.maxX <= frame.maxX, usable.maxY <= frame.maxY else { return nil }
        var topology = current.objectValue ?? [:]
        topology["displays"] = .array([.object(["id": .int(displayID), "frame": frame.json, "usable": usable.json])])
        topology["outer_gap"] = .double(outer)
        return .object(topology)
    }
    private static func extract(_ arrangement: JSONValue, displayID: Int64, topology: JSONValue) -> JSONValue? {
        guard Arrangement.allocationValid(arrangement, topo: topology) else { return nil }
        let normalized = Project.normTopology(topology)
        let split = Arrangement.bagsWithRejected(Arrangement.parseSegs(arrangement.at(path: "segments")), normalized)
        guard split.rejected.isEmpty, let bag = split.bags.first(where: { $0.displayId == displayID }) else { return nil }
        var bindings: JSONObject = [:]
        for (anchor, binding) in arrangement.at(path: "bindings")?.objectValue ?? [:] where anchor.hasPrefix("\(displayID):") {
            bindings[anchor] = binding
        }
        return .object(["segments": .array(bag.segments.map { segment in
            var value = segment.json.objectValue ?? [:]; value["display_id"] = .int(displayID); return .object(value)
        }), "bindings": .object(bindings), "off_top": .array([])])
    }
    private static func compose(_ arrangements: [JSONValue], topology: JSONValue) -> JSONValue? {
        var segments: [JSONValue] = [], bindings: JSONObject = [:]
        for arrangement in arrangements {
            segments.append(contentsOf: arrangement.at(path: "segments")?.arrayValue ?? [])
            for (anchor, binding) in arrangement.at(path: "bindings")?.objectValue ?? [:] {
                guard bindings[anchor] == nil else { return nil }; bindings[anchor] = binding
            }
        }
        let value: JSONValue = .object(["segments": .array(segments), "bindings": .object(bindings),
            "off_top": .array([])])
        guard Arrangement.segmentsValid(Arrangement.parseSegs(.array(segments)), topology: topology),
              Arrangement.allocationValid(value, topo: topology) else { return nil }
        return Arrangement.bridgeArrangementNative(store: value, topo: topology)
    }
}
