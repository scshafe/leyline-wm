// Pure scope and binding checks of the action controller: which committed
// snapshot a request, a focus candidate or a move intent still applies to.
// Moved verbatim from ResidentActionController.swift.
import Foundation
import LeylineModel

extension ResidentActionController {
    /// Only an actual fresh targeted focus/app read creates a history record.
    /// Mode/settings/result publications cannot reuse an old focus timestamp.
    static func confirmedFocus(_ snapshot: CoreCommittedSnapshot) -> ConfirmedFocusCandidate? {
        let world = snapshot.world, event = world.worldEvent
        guard WorldEvent.focusProof.contains(event),
              world.at(path: "observation.reason")?.stringValue == event,
              world.at(path: "observation.ready")?.boolValue == true,
              world.worldComplete == true,
              let focus = world.at(path: "focus"), focus.at(path: "eligible")?.boolValue == true,
              focus.at(path: "managed")?.boolValue != false,
              focus.at(path: "space_enabled")?.boolValue == true, focus.at(path: "space_visible")?.boolValue == true,
              let id = focus.at(path: "window_id")?.intValue, id > 0,
              let pid = focus.at(path: "pid")?.intValue, pid > 0,
              let lifetime = focus.at(path: "window_generation")?.intValue, lifetime > 0,
              let space = focus.at(path: "space_key")?.stringValue, !space.isEmpty, !space.contains("runtime:"),
              let display = focus.at(path: "display_id")?.stringValue, !display.isEmpty,
              let epoch = world.at(path: "observer_epoch")?.stringValue, !epoch.isEmpty,
              let generation = world.at(path: "observer_generation")?.intValue, generation >= 0,
              let stamp = focus.at(path: "observed_uptime_ns")?.intValue, stamp > 0,
              let started = world.at(path: "observation.read_started_uptime_ns")?.intValue, started > 0, started <= stamp,
              let completed = world.at(path: "observation.read_completed_uptime_ns")?.intValue, completed >= stamp,
              UInt64(completed) <= DispatchTime.now().uptimeNanoseconds else { return nil }
        if event == "ax_focus_changed" {
            guard world.at(path: "observation.target_read_performed")?.boolValue == true,
                  world.at(path: "observation.target_window_id")?.intValue == id,
                  world.at(path: "observation.target_kind")?.stringValue == event else { return nil }
        }
        return ConfirmedFocusCandidate(windowID: id, pid: pid, windowGeneration: UInt64(lifetime),
            spaceKey: space, displayID: display, observerEpoch: epoch, observerGeneration: UInt64(generation), observedNanos: UInt64(stamp))
    }

    static func frameScopeMatches(_ request: ResidentEffectRequest, snapshot: CoreCommittedSnapshot,
                                          available: Bool) -> Bool {
        request.effectKind == .frame && effectScopeMatches(request, snapshot: snapshot, available: available)
    }

    static func effectScopeMatches(_ request: ResidentEffectRequest, snapshot: CoreCommittedSnapshot,
                                          available: Bool) -> Bool {
        let context = Self.context(snapshot, persistenceAvailable: available)
        guard context.complete, context.trusted, context.spaceEnabled,
              context.topologyRevision == request.topologyRevision,
              let epoch = request.observerEpoch, !epoch.isEmpty,
              snapshot.world.at(path: "observer_epoch")?.stringValue == epoch,
              !request.windowGenerations.isEmpty,
              Set(request.windowGenerations.keys) == Set(request.windowSpaceKeys.keys),
              Set(request.windowGenerations.keys) == Set(request.windowPids.keys),
              Set(request.windowGenerations.keys) == Set(request.windowDisplayIDs.keys) else { return false }
        let spaces = Set(request.windowSpaceKeys.values)
        let windows = (snapshot.world.at(path: "windows")?.arrayValue ?? []).filter {
            $0.isLiveEnabledWindow && $0.at(path: "space_key")?.stringValue.map(spaces.contains) == true
        }
        guard windows.count == request.windowGenerations.count else { return false }
        return windows.allSatisfy { window in
            guard let id = window.at(path: "window_id")?.intValue,
                  let generation = window.at(path: "window_generation")?.intValue, generation > 0,
                  let pid = window.at(path: "pid")?.intValue else { return false }
            let key = String(id)
            return request.windowGenerations[key] == UInt64(generation) && request.windowPids[key] == pid
                && request.windowSpaceKeys[key] == window.at(path: "space_key")?.stringValue
                && request.windowDisplayIDs[key] == window.at(path: "display_id")?.stringValue
                && window.at(path: "space_identity_available")?.boolValue == true
                && window.at(path: "minimized")?.boolValue != true && window.at(path: "destroyed")?.boolValue != true
        }
    }

    static func focusTargetMatches(_ request: ResidentEffectRequest, snapshot: CoreCommittedSnapshot,
                                          available: Bool) -> Bool {
        guard request.effectKind == .focus, effectScopeMatches(request, snapshot: snapshot, available: available),
              let focus = snapshot.world.at(path: "focus"),
              focus.at(path: "window_id")?.intValue.map(String.init) == request.windowID,
              let generation = focus.at(path: "window_generation")?.intValue, generation > 0,
              request.windowGenerations[request.windowID] == UInt64(generation),
              focus.at(path: "pid")?.intValue == request.windowPids[request.windowID],
              focus.at(path: "space_key")?.stringValue == request.windowSpaceKeys[request.windowID],
              focus.at(path: "display_id")?.stringValue == request.windowDisplayIDs[request.windowID],
              focus.at(path: "eligible")?.boolValue == true, focus.at(path: "space_enabled")?.boolValue == true,
              focus.at(path: "space_visible")?.boolValue == true, focus.at(path: "space_identity_available")?.boolValue == true,
              snapshot.world.at(path: "frontmost_pid")?.intValue == request.windowPids[request.windowID] else { return false }
        return true
    }

    static func observedFocusStamp(_ snapshot: CoreCommittedSnapshot, issued: UInt64) -> UInt64? {
        guard let stamp = snapshot.world.at(path: "focus.observed_uptime_ns")?.intValue, stamp >= 0,
              UInt64(stamp) >= issued else { return nil }
        return UInt64(stamp)
    }

    static func freshFocusedTargetStamp(_ request: ResidentEffectRequest, snapshot: CoreCommittedSnapshot,
                                               available: Bool, issued: UInt64) -> UInt64? {
        guard focusTargetMatches(request, snapshot: snapshot, available: available),
              let stamp = observedFocusStamp(snapshot, issued: issued),
              snapshot.world.at(path: "observation.ready")?.boolValue == true,
              let started = snapshot.world.at(path: "observation.read_started_uptime_ns")?.intValue, started >= 0,
              let completed = snapshot.world.at(path: "observation.read_completed_uptime_ns")?.intValue,
              UInt64(started) >= issued, UInt64(started) <= stamp, completed >= 0, UInt64(completed) >= stamp else { return nil }
        let event = snapshot.world.at(path: "event")?.stringValue
        guard event == "app_activated" || event == "ax_focus_changed",
              snapshot.world.at(path: "observation.reason")?.stringValue == event else { return nil }
        if event == "ax_focus_changed" {
            guard snapshot.world.at(path: "observation.target_read_performed")?.boolValue == true,
                  snapshot.world.at(path: "observation.target_window_id")?.intValue.map(String.init) == request.windowID,
                  snapshot.world.at(path: "observation.target_kind")?.stringValue == "ax_focus_changed" else { return nil }
        }
        return stamp
    }

    /// Immutable membership/topology proof; unrelated focus and frame receipts
    /// do not change partition admission. Ignored tooltip rows are excluded.
    static func reconciliationScope(_ world: JSONValue) -> JSONValue {
        let keys = ["window_id", "pid", "window_generation", "space_key", "display_id", "display_uuid",
            "eligible", "managed", "space_visible", "space_enabled", "role", "subrole", "resizable", "movable", "minimized", "destroyed"]
        let windows = (world.at(path: "windows")?.arrayValue ?? []).filter {
            $0.at(path: "eligible")?.boolValue == true && $0.at(path: "space_visible")?.boolValue == true
        }.sorted { ($0.at(path: "window_id")?.intValue ?? -1) < ($1.at(path: "window_id")?.intValue ?? -1) }.map { window in
            var record: JSONObject = [:]; for key in keys { record[key] = window.at(path: key) ?? .null }; return JSONValue.object(record)
        }
        return .object(["observer_epoch": world.at(path: "observer_epoch") ?? .null,
            "topology_revision": world.at(path: "topology_revision") ?? .null, "topology": world.at(path: "topology") ?? .null,
            "space_contexts": world.at(path: "space_contexts") ?? .null, "space_activation": world.at(path: "space_activation") ?? .null,
            "windows": .array(windows)])
    }

    static func modelProjection(state: JSONValue, event: String) -> JSONObject {
        ["event": .string(event), "model_state": state,
         "mode": state.at(path: "interaction.mode") ?? .string("default"),
         "mode_context_window_id": state.at(path: "interaction.source_window_id") ?? .null,
         "mode_context_space_key": state.at(path: "interaction.active_space_key") ?? .null]
    }

    /// Bind authored geometry to the immutable publication that will expose it.
    /// Geometry and selection remain Planner-owned; only provenance is stamped.
    static func bindCandidate(_ state: JSONValue, snapshot: CoreCommittedSnapshot) -> JSONValue? {
        guard var model = state.objectValue, var interaction = model["interaction"]?.objectValue else { return state }
        guard let epoch = snapshot.world.at(path: "observer_epoch")?.stringValue, !epoch.isEmpty,
              let sourceID = interaction["source_window_id"]?.intValue,
              let cursorID = interaction["cursor_window_id"]?.intValue,
              let generation = snapshot.world.at(path: "observer_generation")?.intValue, generation >= 0,
              let topology = snapshot.world.at(path: "topology_revision")?.intValue, topology >= 0 else { return nil }
        let windows = snapshot.world.at(path: "windows")?.arrayValue ?? []
        let sources = windows.filter { $0.at(path: "window_id")?.intValue == sourceID }
        guard sources.count == 1, let source = sources.first,
              let pid = source.at(path: "pid")?.intValue, pid > 0,
              let lifetime = source.at(path: "window_generation")?.intValue, lifetime > 0,
              let sourceSpace = source.at(path: "space_key")?.stringValue, !sourceSpace.isEmpty,
              let sourceDisplay = source.at(path: "display_id")?.stringValue, !sourceDisplay.isEmpty,
              source.at(path: "eligible")?.boolValue == true, source.at(path: "space_enabled")?.boolValue == true,
              source.at(path: "space_visible")?.boolValue == true else { return nil }
        let sourceIdentity: JSONValue = .object(["window_id": .int(sourceID), "pid": .int(pid),
            "window_generation": .int(lifetime), "space_key": .string(sourceSpace), "display_id": .string(sourceDisplay)])
        if let prior = interaction["source_identity"], prior != sourceIdentity { return nil }
        if let priorEpoch = interaction["observer_epoch"], priorEpoch != .string(epoch) { return nil }
        interaction["source_identity"] = sourceIdentity; interaction["observer_epoch"] = .string(epoch)
        if interaction["candidate_unavailable_reason"] == .string("move_partition_or_min_fit_refused") {
            let cursors = windows.filter { $0.at(path: "window_id")?.intValue == cursorID }
            guard cursors.count == 1, let cursor = cursors.first,
                  let cursorPID = cursor.at(path: "pid")?.intValue, cursorPID > 0,
                  let cursorLifetime = cursor.at(path: "window_generation")?.intValue, cursorLifetime > 0,
                  let cursorSpace = cursor.at(path: "space_key")?.stringValue, !cursorSpace.isEmpty,
                  let cursorDisplay = cursor.at(path: "display_id")?.stringValue, !cursorDisplay.isEmpty,
                  cursor.at(path: "eligible")?.boolValue == true,
                  cursor.at(path: "space_enabled")?.boolValue == true,
                  cursor.at(path: "space_visible")?.boolValue == true else { return nil }
            interaction["preview_refusal_cursor_identity"] = .object(["window_id": .int(cursorID),
                "pid": .int(cursorPID), "window_generation": .int(cursorLifetime),
                "space_key": .string(cursorSpace), "display_id": .string(cursorDisplay)])
        }
        if interaction["interaction_id"] == nil {
            interaction["interaction_id"] = .string("\(epoch):\(sourceID):\(lifetime):\(snapshot.revision + 1)")
        }
        guard var candidate = interaction["candidate"]?.objectValue else {
            model["interaction"] = .object(interaction); return .object(model)
        }
        guard var base = candidate["base"]?.objectValue else { return nil }
        let referenced = Set((base["window_identities"]?.objectValue ?? [:]).keys)
            .union([String(sourceID), String(cursorID)])
        var identities: JSONObject = [:]
        for id in referenced {
            let matches = windows.filter { $0.at(path: "window_id")?.intValue.map(String.init) == id }
            guard matches.count == 1, let window = matches.first,
                  let pid = window.at(path: "pid")?.intValue, pid > 0,
                  let lifetime = window.at(path: "window_generation")?.intValue, lifetime > 0,
                  let space = window.at(path: "space_key")?.stringValue, !space.isEmpty, !space.contains("runtime:"),
                  let display = window.at(path: "display_id")?.stringValue, !display.isEmpty,
                  window.at(path: "eligible")?.boolValue == true,
                  window.at(path: "space_visible")?.boolValue == true,
                  window.at(path: "space_enabled")?.boolValue == true,
                  window.at(path: "minimized")?.boolValue != true,
                  window.at(path: "destroyed")?.boolValue != true else { return nil }
            identities[id] = .object(["pid": .int(pid), "window_generation": .int(lifetime),
                "space_key": .string(space), "display_id": .string(display),
                "eligible": .bool(true), "space_visible": .bool(true), "space_enabled": .bool(true)])
        }
        guard let candidateSourceSpace = identities[String(sourceID)]?.at(path: "space_key") else { return nil }
        base["observer_epoch"] = .string(epoch); base["observer_generation"] = .int(generation)
        base["topology_revision"] = .int(topology); base["active_space_key"] = candidateSourceSpace
        base["interaction_id"] = interaction["interaction_id"]
        base["state_revision"] = .int(Int64(clamping: snapshot.revision + 1))
        base["window_identities"] = .object(identities)
        candidate["base"] = .object(base)
        candidate["candidate_id"] = .string((candidate["candidate_id"]?.stringValue ?? "candidate").components(separatedBy: ":revision:").first!
            + ":revision:\(snapshot.revision + 1)")
        interaction["candidate"] = .object(candidate)
        interaction["observer_generation"] = .int(generation); interaction["topology_revision"] = .int(topology)
        interaction["active_space_key"] = candidateSourceSpace
        model["interaction"] = .object(interaction)
        return .object(model)
    }

    /// Re-observing the same lifetime under a healthy focus generation permits
    /// intent refresh; a reused ID, changed Space/epoch/topology never does.
    static func moveIntentScopeMatches(_ state: JSONValue, snapshot: CoreCommittedSnapshot) -> Bool {
        guard let interaction = state.at(path: "interaction"), interaction.at(path: "mode") == .string("move"),
              interaction.at(path: "observer_epoch") == snapshot.world.at(path: "observer_epoch"),
              interaction.at(path: "topology_revision") == snapshot.world.at(path: "topology_revision"),
              let source = interaction.at(path: "source_identity"),
              let sourceID = source.at(path: "window_id")?.intValue else { return false }
        let windows = snapshot.world.at(path: "windows")?.arrayValue ?? []
        let sourceMatches = windows.filter { $0.at(path: "window_id")?.intValue == sourceID }
        guard sourceMatches.count == 1, let currentSource = sourceMatches.first else { return false }
        for (field, expected) in source.objectValue ?? [:] { if currentSource.at(path: field) != expected { return false } }
        let identities = interaction.at(path: "candidate.base.window_identities")?.objectValue
            ?? [String(sourceID): source]
        return identities.allSatisfy { id, identity in
            let matches = windows.filter { $0.at(path: "window_id")?.intValue.map(String.init) == id }
            guard matches.count == 1, let window = matches.first,
                  window.at(path: "eligible")?.boolValue == true, window.at(path: "space_enabled")?.boolValue == true,
                  window.at(path: "space_visible")?.boolValue == true,
                  window.at(path: "minimized")?.boolValue != true, window.at(path: "destroyed")?.boolValue != true else { return false }
            return (identity.objectValue ?? [:]).allSatisfy { window.at(path: $0.key) == $0.value }
        }
    }

    static func context(_ snapshot: CoreCommittedSnapshot, persistenceAvailable: Bool) -> ResidentEffectContext {
        let world = snapshot.world
        let focused = world.at(path: "focus")
        let fallback = (world.at(path: "windows")?.arrayValue ?? []).first {
            $0.at(path: "eligible")?.boolValue == true && $0.at(path: "space_visible")?.boolValue == true
                && $0.at(path: "space_enabled")?.boolValue == true
        }
        let anchor = focused?.at(path: "space_enabled")?.boolValue == true ? focused : fallback
        return ResidentEffectContext(revision: snapshot.revision,
            observerGeneration: UInt64(max(0, world.at(path: "observer_generation")?.intValue ?? 0)),
            activeSpaceKey: anchor?.at(path: "space_key")?.stringValue,
            topologyRevision: UInt64(max(0, world.at(path: "topology_revision")?.intValue ?? world.at(path: "observer_generation")?.intValue ?? 0)),
            trusted: world.at(path: "observation.failure_code")?.stringValue != "ax_untrusted",
            complete: persistenceAvailable && world.worldComplete == true,
            spaceEnabled: world.managementEnabled && anchor?.at(path: "space_enabled")?.boolValue == true)
    }
}
