import Foundation

/// @canonical move_candidate_provenance -- immutable preview and commit share this guard.
public enum MoveCandidate {
    public static func isCurrent(candidate: JSONValue, state: JSONValue, world: JSONValue) -> Bool {
        guard candidate.at(path: "schema")?.stringValue == "leyline/move-candidate/v1",
              let base = candidate.at(path: "base"),
              base.at(path: "observer_generation")?.intValue != nil,
              base.at(path: "topology_revision")?.intValue != nil,
              base.at(path: "active_space_key")?.stringValue?.isEmpty == false,
              let selected = candidate.at(path: "selection"), selected.objectValue != nil,
              let cursor = selected.at(path: "cursor_window_id")?.intValue, cursor > 0,
              selected.at(path: "scope")?.stringValue.map({ ["edge", "run", "parent"].contains($0) }) == true,
              cursor == state.at(path: "interaction.cursor_window_id")?.intValue,
              candidate.at(path: "source_window_id")?.intValue.map({ $0 > 0 }) == true,
              candidate.at(path: "operation")?.stringValue.map({ ["swap", "insert"].contains($0) }) == true,
              candidate.at(path: "desired_arrangement")?.objectValue != nil,
              candidate.at(path: "targets")?.objectValue != nil,
              base.at(path: "arrangement") == state.at(path: "arrangement"),
              candidate.at(path: "source_window_id") == state.at(path: "interaction.source_window_id"),
              candidate.at(path: "selection") == state.at(path: "interaction.selection") else { return false }
        if candidate.at(path: "operation")?.stringValue == "swap",
           candidate.at(path: "target_window_id")?.intValue != cursor { return false }
        if let minimums = base.at(path: "minimum_sizes"), minimums != (state.at(path: "minimum_sizes") ?? .object([:])) { return false }
        for field in ["observer_epoch", "observer_generation", "topology_revision", "active_space_key"] {
            if let recorded = base.at(path: field), recorded != .null {
                let source = candidate.at(path: "source_window_id")?.intValue
                let sourceSpace = (world.at(path: "windows")?.arrayValue ?? []).first(where: { $0.at(path: "window_id")?.intValue == source })?.at(path: "space_key")
                let current = field == "active_space_key" ? sourceSpace ?? world.at(path: field) : world.at(path: field)
                guard current == recorded else { return false }
            }
        }
        if let revision = base.at(path: "state_revision"), revision != .null,
           let current = state.at(path: "model_state_revision") ?? world.at(path: "model_state_revision") {
            guard revision == current else { return false }
        }
        let observed = world.at(path: "windows")?.arrayValue ?? []
        guard let identities = base.at(path: "window_identities")?.objectValue, !identities.isEmpty else { return false }
        let observedIDs = observed.compactMap { $0.at(path: "window_id")?.intValue }
        guard observedIDs.count == observed.count, Set(observedIDs).count == observedIDs.count else { return false }
        for (id, identity) in identities {
            guard Int64(id).map({ $0 > 0 && String($0) == id }) == true, identity.objectValue != nil,
                  let window = observed.first(where: { $0.at(path: "window_id")?.intValue.map(String.init) == id }) else { return false }
            for (field, expected) in identity.objectValue ?? [:] where expected != .null {
                let current = field == "display_id" && expected.stringValue != nil && window.at(path: field)?.intValue != nil
                    ? window.at(path: "display_uuid") : window.at(path: field)
                guard current == expected else { return false }
            }
        }
        return true
    }
}
