import Foundation
import CryptoKit
import LeylineModel

/// @canonical responsiveness_inventory_validation -- source discovery and frozen path coverage fail closed.
func validateResponsivenessInventory(_ inventory: JSONValue, root: String) -> [String] {
    var errors: [String] = []
    let rows = inventory.at(path: "rows")?.arrayValue ?? []
    let scenes = inventory.at(path: "scenes")?.arrayValue ?? []
    if rows.isEmpty || scenes.isEmpty { errors.append("zero_scenarios") }
    let requiredScenes: Set<String> = ["warm_six_windows", "stress_twenty_windows", "repeat_burst_final_intent",
        "menu_tracking", "sleep_wake", "no_focus_empty_space", "hostile_ax_reads"]
    let sceneIDs = Set(scenes.compactMap { $0.at(path: "id")?.stringValue })
    if sceneIDs != requiredScenes { errors.append("scene_inventory_mismatch") }
    for path in inventory.at(path: "source_paths")?.arrayValue ?? [] {
        guard let source = path.stringValue, !source.contains(".."),
              FileManager.default.fileExists(atPath: root + "/" + source) else {
            errors.append("missing_source_path"); continue
        }
    }
    if (inventory.at(path: "source_paths")?.arrayValue ?? []).count < 7 { errors.append("source_inventory_missing") }
    // Permanent discovery uses actual compiled native action owners. Retired
    // manifests cannot be mandatory inputs after their domains are removed.
    let nativeIDs = ResidentInput.retainedActionIds.union(ResidentActionController.actionIDs)
    let nativeRows = rows.filter { $0.at(path: "id")?.stringValue?.hasPrefix("native-action:") == true }
    let listedNativeIDs = Set(nativeRows.compactMap { $0.at(path: "source_id")?.stringValue })
    if nativeIDs.isEmpty || listedNativeIDs != nativeIDs || nativeRows.count != nativeIDs.count {
        errors.append("source_inventory_mismatch_native_actions")
    }
    if inventory.at(path: "source_inventory_counts.native_actions")?.intValue != Int64(nativeIDs.count) {
        errors.append("source_count_mismatch_native_actions")
    }
    let requiredCapabilities: Set<String> = ["windows_selection", "status_icon", "fixed_border_spacing",
        "exact_move_preview", "move_confirmation_identity", "settled_clamp_learning", "native_performance_trace"]
    let capabilityRows = rows.filter { $0.at(path: "id")?.stringValue?.hasPrefix("capability:") == true }
    let capabilityIDs = Set(capabilityRows.compactMap { $0.at(path: "id")?.stringValue }.map { String($0.dropFirst(11)) })
    if capabilityIDs != requiredCapabilities || capabilityRows.count != requiredCapabilities.count {
        errors.append("completion_capability_inventory_mismatch")
    }
    let budgetIDs = Set((inventory.at(path: "budgets")?.arrayValue ?? []).compactMap { $0.at(path: "id")?.stringValue })
    for row in capabilityRows {
        let cases = row.at(path: "correctness_cases")?.arrayValue ?? []
        let refs = Set((row.at(path: "budget_refs")?.arrayValue ?? []).compactMap(\.stringValue))
        guard let source = row.at(path: "source")?.stringValue,
              let symbol = row.at(path: "source_symbol")?.stringValue, !symbol.isEmpty,
              let contents = try? String(contentsOfFile: root + "/" + source, encoding: .utf8),
              contents.contains(symbol), !cases.isEmpty, !refs.isEmpty, refs.isSubset(of: budgetIDs) else {
            errors.append("completion_capability_source_or_oracle_missing"); continue
        }
    }
    let requiredPaths: Set<String> = ["border_focus", "border_frame", "border_clear", "mode_origin",
        "adopt_largest_first", "reclaim", "cross_display_relocation", "space_activation", "configuration",
        "menu_space_toggle", "menu_open", "recovery", "input_intent", "fault_release", "crash_recovery", "cache_integrity", "minimum_learning", "startup_readiness"]
    let paths = Set(rows.compactMap { $0.at(path: "id")?.stringValue }.filter { $0.hasPrefix("path:") }
        .map { String($0.dropFirst(5)) })
    if paths != requiredPaths { errors.append("retained_path_inventory_mismatch") }
    let dispositions: Set<String> = ["keep"]
    for row in rows {
        let id = row.at(path: "id")?.stringValue ?? "missing"
        for field in ["id", "source", "disposition", "event_source", "owner", "generation_rule", "failure"] {
            if (row.at(path: field)?.stringValue ?? "").isEmpty { errors.append("missing_" + field + "_" + id) }
        }
        if !dispositions.contains(row.at(path: "disposition")?.stringValue ?? "") { errors.append("unknown_disposition_" + id) }
        guard let source = row.at(path: "source")?.stringValue,
              FileManager.default.fileExists(atPath: root + "/" + source) else { errors.append("missing_path_" + id); continue }
        let scenarios = Set((row.at(path: "scenarios")?.arrayValue ?? []).compactMap(\.stringValue))
        if scenarios.isEmpty { errors.append("zero_path_scenarios_" + id) }
        if row.at(path: "disposition")?.stringValue == "keep", scenarios.isDisjoint(with: requiredScenes) {
            errors.append("retained_path_without_scene_" + id)
        }
    }
    if inventory.at(path: "queue.maximum_ordered_pending")?.intValue != Int64(ResponsivenessEvidence.maximumOrderedQueueDepth)
        || inventory.at(path: "queue.maximum_pending_desired_per_lane")?.intValue != 1 { errors.append("unbounded_or_changed_queue") }
    let timerIDs = (inventory.at(path: "timers")?.arrayValue ?? []).compactMap { $0.at(path: "id")?.stringValue }
    if Set(timerIDs) != ["tap_liveness", "targeted_evidence_deadline", "cache_integrity_audit", "core_authority_heartbeat",
                        "ax_message_deadline", "ax_targeted_total_read_deadline", "subscriber_send_deadline", "core_trust_audit",
                        "resident_client_completion_deadline", "exclusive_maintenance_deadline", "ax_transient_recovery", "ax_settled_handle_repair", "resident_control_completion_deadline", "input_fault_notice_dismissal", "socket_frame_read_deadline"]
        || timerIDs.count != 15 { errors.append("unlisted_or_missing_timer") }
    for timer in inventory.at(path: "timers")?.arrayValue ?? [] {
        if timer.at(path: "interaction_poll")?.boolValue != false
            || (timer.at(path: "deadline_ms")?.numberValue ?? 0) <= 0
            || (timer.at(path: "cost")?.stringValue ?? "").isEmpty { errors.append("invalid_timer_boundary") }
        if let source = timer.at(path: "source")?.stringValue,
           !FileManager.default.fileExists(atPath: root + "/" + source) { errors.append("missing_timer_source") }
        if timer.at(path: "id")?.stringValue == "resident_client_completion_deadline"
            && (timer.at(path: "recurring")?.boolValue != false
                || timer.at(path: "idle_cost")?.intValue != 0
                || timer.at(path: "deadline_ms")?.intValue != 10000
                || timer.at(path: "minimum_deadline_ms")?.intValue != 1000
                || timer.at(path: "maximum_deadline_ms")?.intValue != 60000) {
            errors.append("invalid_client_deadline_boundary")
        }
        if timer.at(path: "id")?.stringValue == "ax_transient_recovery"
            && (timer.at(path: "recurring")?.boolValue != false
                || timer.at(path: "idle_cost")?.intValue != 0
                || timer.at(path: "deadline_ms")?.intValue != 100) {
            errors.append("invalid_ax_recovery_boundary")
        }
    }
    let budgets = inventory.at(path: "budgets")?.arrayValue ?? []
    if budgets.count != 16 { errors.append("missing_budget_inventory") }
    for (id, end, p95) in [("border_submission", "render_submitted", 16.0), ("border_visible", "physically_visible", 125.0)] {
        guard let budget = budgets.first(where: { $0.at(path: "id")?.stringValue == id }),
              budget.at(path: "start")?.stringValue == "receipt",
              budget.at(path: "end")?.stringValue == end,
              budget.at(path: "p95_ms")?.numberValue == p95 else { errors.append("changed_border_endpoint_or_budget_" + id); continue }
    }
    // Frozen structural contracts are independent of the supplied fixture. Deleting/changing a
    // core ceiling or timer cost must not make the same validator green by editing its input.
    // v1 adds a 2-second bounded socket frame read to the 14 existing purposes.
    // Hash the model's insertion-ordered canonical wire bytes, including string escapes.
    let frozenHashes = ["budgets": "53e97a6a45449ccbd633227e0941f0218a69a6a6195c640520f4685f1da8cf2e",
        "timers": "4d6b198c7a567c0842c1165f10f10a8e720f49014a7b72311f94d098ba16cd9c",
        "scenes": "4c4278947a177e813cede66e0275133d6f32dc62a95f7c6969a852cac84b21fd"]
    for (key, expected) in frozenHashes {
        let canonical = (inventory.at(path: key) ?? .null).canonical()
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        if hash != expected { errors.append("frozen_" + key + "_changed") }
    }
    return errors
}

func runResponsivenessSelfTest(_ args: [String]) -> Int32 {
    guard args.isEmpty || args == ["--list-scenarios"] else { return 64 }
    let root = SelfTestFixtures.repositoryRoot()
    var tests = SelfTest()
    guard let data = FileManager.default.contents(atPath: SelfTestFixtures.path("responsiveness/inventory.json", root: root)),
          let inventory = try? JSONValue.parse(data) else {
        tests.check(false, "responsiveness/inventory-missing"); return tests.finish("responsiveness")
    }
    if args == ["--list-scenarios"] {
        print(inventory.canonical())
        return validateResponsivenessInventory(inventory, root: root).isEmpty ? 0 : 1
    }
    let valid = validateResponsivenessInventory(inventory, root: root)
    tests.check(valid.isEmpty, "responsiveness/source-bound-full-inventory")
    for error in valid { print("    " + error) }
    var object = inventory.objectValue!
    var rows = inventory.at(path: "rows")!.arrayValue!
    rows.removeFirst(); object["rows"] = .array(rows)
    tests.check(!validateResponsivenessInventory(.object(object), root: root).isEmpty,
                "responsiveness/mutation-missing-retained-source-path-rejected")
    object = inventory.objectValue!; object["rows"] = .array([])
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("zero_scenarios"),
                "responsiveness/mutation-zero-scenarios-rejected")
    object = inventory.objectValue!; object["queue"] = .object(["maximum_ordered_pending": .int(-1)])
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("unbounded_or_changed_queue"),
                "responsiveness/mutation-unbounded-queue-rejected")
    object = inventory.objectValue!; object["timers"] = .array((inventory.at(path: "timers")!.arrayValue!) + [.object(["id": .string("normal_state_poll")])])
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("unlisted_or_missing_timer"),
                "responsiveness/mutation-unlisted-timer-rejected")
    object = inventory.objectValue!
    object["timers"] = .array(inventory.at(path: "timers")!.arrayValue!.map { timer in
        guard timer.at(path: "id")?.stringValue == "socket_frame_read_deadline" else { return timer }
        var changed = timer.objectValue!; changed["deadline_ms"] = .int(2_001)
        return .object(changed)
    })
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("frozen_timers_changed"),
        "responsiveness/mutation-weakened-socket-frame-deadline-rejected")
    object = inventory.objectValue!
    object["timers"] = .array(inventory.at(path: "timers")!.arrayValue!.filter {
        $0.at(path: "id")?.stringValue != "resident_client_completion_deadline"
    })
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("unlisted_or_missing_timer"),
        "responsiveness/mutation-missing-on-demand-client-deadline-rejected")
    object = inventory.objectValue!
    object["timers"] = .array(inventory.at(path: "timers")!.arrayValue!.map { timer in
        guard timer.at(path: "id")?.stringValue == "resident_client_completion_deadline" else { return timer }
        var changed = timer.objectValue!; changed["idle_cost"] = .int(1); changed["recurring"] = .bool(true)
        return .object(changed)
    })
    tests.check(validateResponsivenessInventory(.object(object), root: root).contains("invalid_client_deadline_boundary")
        && validateResponsivenessInventory(.object(object), root: root).contains("frozen_timers_changed"),
        "responsiveness/mutation-on-demand-client-timer-cannot-become-idle-poller-or-relax-frozen-inventory")

    let receipt = ResponsivenessStamp(endpoint: .receipt, nanos: 100, provenance: "event_callback")
    let submission = ResponsivenessStamp(endpoint: .renderSubmitted, nanos: 1_000_100, provenance: "appkit_submission")
    let visible = ResponsivenessStamp(endpoint: .physicallyVisible, nanos: 2_000_100, provenance: "independent_visible_observer")
    func sample(_ stamps: [String: ResponsivenessStamp], synthetic: Bool = true) -> ResponsivenessSample {
        .init(scenarioID: "border_focus", revision: 4, generation: 8, refreshHz: 60, windowCount: 6,
              load: "warm", synthetic: synthetic, stamps: stamps)
    }
    let good = sample(["receipt": receipt, "render_submitted": submission, "physically_visible": visible])
    tests.check(good.validate(expectedRevision: 4, expectedGeneration: 8,
        endpoints: [.receipt, .renderSubmitted, .physicallyVisible], liveRequired: false).isEmpty,
        "responsiveness/receipt-submission-visible-distinct")
    for swapped in [sample(["receipt": submission, "render_submitted": receipt, "physically_visible": visible]),
                    sample(["receipt": receipt, "render_submitted": visible, "physically_visible": submission])] {
        tests.check(!swapped.validate(expectedRevision: 4, expectedGeneration: 8,
            endpoints: [.receipt, .renderSubmitted, .physicallyVisible], liveRequired: false).isEmpty,
            "responsiveness/mutation-swapped-receipt-submission-visible-rejected")
    }
    tests.check(!sample(["receipt": receipt, "render_submitted": submission]).validate(
        expectedRevision: 4, expectedGeneration: 8, endpoints: [.physicallyVisible], liveRequired: false).isEmpty,
        "responsiveness/missing-visible-evidence-cannot-certify")
    tests.check(!good.validate(expectedRevision: 4, expectedGeneration: 8,
        endpoints: [.physicallyVisible], liveRequired: true).isEmpty,
        "responsiveness/hermetic-success-cannot-certify-live")
    let fakeVisible = ResponsivenessStamp(endpoint: .physicallyVisible, nanos: 2_000_100, provenance: "ax_setter_ack")
    tests.check(!sample(["receipt": receipt, "physically_visible": fakeVisible]).validate(
        expectedRevision: 4, expectedGeneration: 8, endpoints: [.physicallyVisible], liveRequired: false).isEmpty,
        "responsiveness/setter-ack-never-counts-as-visible")
    let slow = sample(["receipt": receipt, "render_submitted": .init(endpoint: .renderSubmitted,
        nanos: 17_000_100, provenance: "appkit_submission")])
    tests.check(ResponsivenessEvidence.gate(samples: [slow], scenarioID: "border_focus", from: .receipt,
        to: .renderSubmitted, p95CeilingMs: 16, minimumSamples: 1, expectedRevision: 4,
        expectedGeneration: 8, liveRequired: false).contains("absolute_ceiling_missed"),
        "responsiveness/absolute-border-ceiling-no-relative-waiver")
    tests.check(!ResponsivenessEvidence.gate(samples: [], scenarioID: "border_focus", from: .receipt,
        to: .renderSubmitted, p95CeilingMs: 16, minimumSamples: 1, expectedRevision: 4,
        expectedGeneration: 8, liveRequired: false).isEmpty, "responsiveness/empty-measurement-gate-rejected")
    return tests.finish("responsiveness")
}
