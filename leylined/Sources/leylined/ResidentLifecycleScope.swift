import Foundation
import LeylineModel

/// @canonical resident_lifecycle_interaction_scope -- server mode exit and
/// controller effect cancellation use the same positive ignored-target proof.
/// Only complete, fresh lifecycle observations of ignored windows with an
/// unchanged managed cohort preserve an interaction. Unknown evidence invalidates.
func residentLifecycleInvalidatesInteraction(event: String, before: JSONValue, after: JSONValue) -> Bool {
    guard ["ax_window_created", "ax_window_destroyed", "ax_window_minimized", "ax_window_restored"].contains(event),
          before.at(path: "observation.ready")?.boolValue == true,
          after.at(path: "observation.ready")?.boolValue == true,
          before.at(path: "observation.world_complete")?.boolValue == true,
          after.at(path: "observation.world_complete")?.boolValue == true,
          let epoch = before.at(path: "observer_epoch")?.stringValue, !epoch.isEmpty,
          after.at(path: "observer_epoch")?.stringValue == epoch,
          after.at(path: "observation.reason")?.stringValue == event,
          let receipt = after.at(path: "observation.source_receipt_uptime_ns")?.intValue, receipt > 0,
          receipt != before.at(path: "observation.source_receipt_uptime_ns")?.intValue,
          let completed = after.at(path: "observation.read_completed_uptime_ns")?.intValue, completed >= receipt,
          let old = residentManagedLifecycleCohort(before), !old.isEmpty,
          let current = residentManagedLifecycleCohort(after), old == current else { return true }

    // Folded old target fields cannot prove what an unobserved event affected.
    var targets: [Int64] = []
    for value in [after.at(path: "observation.target_window_id"), after.at(path: "notification_window_id")] {
        guard let value, value != .null else { continue }
        guard let id = value.intValue, id > 0, id <= Int64(UInt32.max) else { return true }
        targets.append(id)
    }
    guard let target = targets.first, targets.allSatisfy({ $0 == target }) else { return true }
    let proof = (event == "ax_window_destroyed" || event == "ax_window_minimized") ? before : after
    guard let records = proof.at(path: "windows")?.arrayValue,
          let record = records.first(where: { $0.at(path: "window_id")?.intValue == target }),
          record.at(path: "eligible")?.boolValue == false,
          record.at(path: "managed")?.boolValue != true,
          let pid = record.at(path: "pid")?.intValue, pid > 0,
          let lifetime = record.at(path: "window_generation")?.intValue, lifetime > 0 else { return true }
    if let observedPID = after.at(path: "observation.target_pid")?.intValue, observedPID != pid { return true }
    return false
}

/// Frames are deliberately excluded: an ignored popup may arrive while valid
/// effects are landing. Identity/membership changes still invalidate the group.
private func residentManagedLifecycleCohort(_ world: JSONValue) -> [Int64: JSONValue]? {
    guard let windows = world.at(path: "windows")?.arrayValue else { return nil }
    var seen: Set<Int64> = []
    var cohort: [Int64: JSONValue] = [:]
    for window in windows {
        guard let id = window.at(path: "window_id")?.intValue, id > 0, id <= Int64(UInt32.max),
              seen.insert(id).inserted, let eligible = window.at(path: "eligible")?.boolValue else { return nil }
        if !eligible { continue }
        guard window.at(path: "managed")?.boolValue != false,
              let pid = window.at(path: "pid")?.intValue, pid > 0,
              let lifetime = window.at(path: "window_generation")?.intValue, lifetime > 0,
              let space = window.at(path: "space_key")?.stringValue, !space.isEmpty,
              space != "space:unknown", !space.hasPrefix("space:runtime:"),
              window.at(path: "space_identity_available")?.boolValue == true,
              let visible = window.at(path: "space_visible")?.boolValue,
              let enabled = window.at(path: "space_enabled")?.boolValue,
              let display = window.at(path: "display_id") else { return nil }
        switch display {
        case .string(let identity): guard !identity.isEmpty, identity != "display:unknown" else { return nil }
        case .int(let identity): guard identity > 0 else { return nil }
        default: return nil
        }
        cohort[id] = .object(["window_id": .int(id), "pid": .int(pid), "window_generation": .int(lifetime),
            "space_key": .string(space), "display_id": display, "space_visible": .bool(visible), "space_enabled": .bool(enabled)])
    }
    return cohort
}
