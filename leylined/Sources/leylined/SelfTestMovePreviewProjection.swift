import Foundation
import LeylineModel

/// Recorded candidate/commit targets remain an independent read-only oracle.
/// Geometry authoring is exercised by the resident command suite, never here.
func runMovePreviewProjectionScenarios(sampleDirectory: String? = nil, check: (String, Bool) -> Void) {
    func replacing(_ value: JSONValue, path: String, with replacement: JSONValue) -> JSONValue {
        func descend(_ value: JSONValue, _ keys: ArraySlice<String>) -> JSONValue {
            guard let key = keys.first else { return replacement }
            var object = value.objectValue ?? [:]
            object[key] = descend(object[key] ?? .null, keys.dropFirst())
            return .object(object)
        }
        return descend(value, ArraySlice(path.split(separator: ".").map(String.init)))
    }
    let path = SelfTestFixtures.url("projection/move-candidates.json")
    do {
        let fixture = try JSONValue.parse(Data(contentsOf: path))
        for row in fixture.at(path: "cases")?.arrayValue ?? [] {
            let name = row.requiredString("name")
            let world = row.at(path: "world")!
            let plan = BorderProjection.plan(world: world)
            let ghosts = plan.rings.filter { $0.stroke == .dashed }
            let expected = row.at(path: "commit_targets")!.objectValue!
            if name == "swap" {
                check("preview/swap-has-no-insertion-direction-cue", plan.insertionPreview == nil)
            }
            check("preview/\(name)-every-affected-frame-equals-commit-verbatim",
                ghosts.count == expected.count && ghosts.allSatisfy {
                    $0.frame.json == expected[String($0.windowId)]?.at(path: "frame")
                })
            check("preview/\(name)-source-and-cursor-roles-remain-at-observed-frames",
                plan.rings.first?.role == .moved && plan.rings.first?.stroke == .solid
                && plan.rings.first?.frame.json == world.at(path: "focus.frame")
                && plan.rings.first(where: { $0.role == .moveTo })?.frame.json
                    == world.at(path: "windows")?.arrayValue?.first(where: { $0.at(path: "window_id") == .int(2) })?.at(path: "frame")
                && plan.previewCandidateID == world.at(path: "model_state.interaction.candidate.candidate_id")?.stringValue)
            let laterFocus = replacing(world, path: "focus", with: world.at(path: "windows")!.arrayValue![2])
            let retained = BorderProjection.plan(world: laterFocus)
            check("preview/\(name)-later-focus-never-retargets-bound-origin-source",
                retained == plan && retained.rings.first?.windowId == 1)
            if name == "insert_with_reclaim" {
                let boundary = world.at(path: "model_state.interaction.selection.boundary")!
                check("preview/staged-span-boundary-is-projected-verbatim",
                    plan.selectionLines == [BorderSelectionLine(axis: boundary.requiredString("axis"),
                        coordinate: boundary.at(path: "coord")!.numberValue!, lower: boundary.at(path: "lo")!.numberValue!,
                        upper: boundary.at(path: "hi")!.numberValue!)])
                check("preview/insertion-cue-identifies-canonical-source-destination",
                    plan.insertionPreview?.windowId == 1
                    && plan.insertionPreview?.frame.json == expected["1"]?.at(path: "frame")
                    && plan.insertionPreview?.side == .north)
                var unchanged = world
                for key in ["targets", "desired_arrangement.bindings"] {
                    let target = key == "targets" ? "1" : "1:0:0"
                    unchanged = replacing(unchanged, path: "model_state.interaction.candidate.\(key).\(target).frame",
                        with: world.at(path: "focus.frame")!)
                }
                var affected = unchanged.at(path: "model_state.interaction.candidate.affected_frames")!.objectValue!
                affected.removeValue(forKey: "1")
                unchanged = replacing(unchanged, path: "model_state.interaction.candidate.affected_frames", with: .object(affected))
                check("preview/unchanged-source-destination-still-has-a-side-cue-without-an-affected-source-ghost",
                    BorderProjection.plan(world: unchanged).insertionPreview?.frame.json == world.at(path: "focus.frame"))
                let directions = try JSONValue.parse(Data(contentsOf: path.deletingLastPathComponent()
                    .appendingPathComponent("insertion-direction-cues.json")))
                for direction in directions.at(path: "directions")!.arrayValue! {
                    let side = direction.requiredString("side")
                    var selected = world.at(path: "model_state.interaction.selection")!
                    for key in ["scope", "level"] {
                        selected = replacing(selected, path: key, with: direction.at(path: key)!)
                    }
                    for key in ["side", "axis"] {
                        selected = replacing(selected, path: "boundary.\(key)", with: direction.at(path: key)!)
                    }
                    var changed = replacing(world, path: "model_state.interaction.selection", with: selected)
                    changed = replacing(changed, path: "model_state.interaction.candidate.selection", with: selected)
                    for key in ["targets", "affected_frames"] {
                        changed = replacing(changed, path: "model_state.interaction.candidate.\(key).1.frame",
                            with: direction.at(path: "frame")!)
                    }
                    let cue = BorderProjection.plan(world: changed).insertionPreview
                    check("preview/\(side)-uses-selected-direction-and-current-source-target-for-\(direction.requiredString("scope"))",
                        cue?.side.rawValue == side && cue?.label == direction.at(path: "label")?.stringValue
                        && cue?.frame.json == direction.at(path: "frame"))
                    if let cue {
                        let unavailable = BorderInsertionPreview(windowId: cue.windowId, frame: cue.frame,
                            side: cue.side, isAvailable: false)
                        check("preview/\(side)-unavailable-label-promises-no-insertion",
                            unavailable.label == direction.at(path: "unavailable_label")?.stringValue)
                        if let sampleDirectory {
                            let destination = URL(fileURLWithPath: sampleDirectory, isDirectory: true)
                            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                            try MainActor.assumeIsolated {
                                try renderInsertionPreviewSample(unavailable,
                                    output: destination.appendingPathComponent("unavailable-\(side).png"))
                            }
                        }
                    }
                    if let sampleDirectory, let cue {
                        let destination = URL(fileURLWithPath: sampleDirectory, isDirectory: true)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        try MainActor.assumeIsolated {
                            try renderInsertionPreviewSample(cue, output: destination.appendingPathComponent("insert-\(side).png"))
                        }
                    }
                }
                for direction in directions.at(path: "invalid_directions")!.arrayValue! {
                    var selected = world.at(path: "model_state.interaction.selection")!
                    for key in ["side", "axis"] {
                        selected = replacing(selected, path: "boundary.\(key)", with: direction.at(path: key)!)
                    }
                    var changed = replacing(world, path: "model_state.interaction.selection", with: selected)
                    changed = replacing(changed, path: "model_state.interaction.candidate.selection", with: selected)
                    let invalid = BorderProjection.plan(world: changed)
                    // The fallback is positional: the source and cursor rings were already
                    // authored when the boundary was refused, the ghosts were not yet kept.
                    check("preview/\(direction.requiredString("name"))-clears-insertion-cue-keeping-source-and-cursor-rings",
                        invalid.insertionPreview == nil && invalid.previewCandidateID == nil
                        && invalid.rings.map(\.role) == [.moved, .moveTo])
                }
                let cancelled = BorderProjection.plan(world: replacing(world, path: "mode", with: .string("default")))
                check("preview/cancellation-clears-direction-and-destination-cue", cancelled.insertionPreview == nil)
                for mutation in fixture.at(path: "mutations")?.arrayValue ?? [] {
                    var changed = world
                    let path = mutation.requiredString("path")
                    let value = mutation.at(path: "value")!
                    if let id = mutation.at(path: "window_id")?.intValue {
                        let windows = (changed.at(path: "windows")?.arrayValue ?? []).map { window -> JSONValue in
                            window.at(path: "window_id")?.intValue == id ? replacing(window, path: path, with: value) : window
                        }
                        changed = replacing(changed, path: "windows", with: .array(windows))
                    } else { changed = replacing(changed, path: path, with: value) }
                    let invalid = BorderProjection.plan(world: changed)
                    // `expected_roles` pins exactly which solid rings survive: the fallback is positional.
                    let survivors = mutation.at(path: "expected_roles")?.arrayValue?.compactMap { $0.stringValue.flatMap(BorderRole.init(rawValue:)) }
                    check("preview/\(mutation.requiredString("name"))-clears-entire-candidate",
                        invalid.previewCandidateID == nil && invalid.insertionPreview == nil
                        && invalid.rings.allSatisfy { $0.stroke == .solid && $0.role != .moveTo }
                        && survivors.map { invalid.rings.map(\.role) == $0 } != false)
                }
            }
        }
    } catch { check("preview/fixture-error-\(error)", false) }
}
