import Foundation
import LeylineModel

/// Recorded candidate/commit targets remain an independent read-only oracle.
/// Geometry authoring is exercised by the resident command suite, never here.
func runMovePreviewProjectionScenarios(check: (String, Bool) -> Void) {
    func replacing(_ value: JSONValue, path: String, with replacement: JSONValue) -> JSONValue {
        func descend(_ value: JSONValue, _ keys: ArraySlice<String>) -> JSONValue {
            guard let key = keys.first else { return replacement }
            var object = value.objectValue ?? [:]
            object[key] = descend(object[key] ?? .null, keys.dropFirst())
            return .object(object)
        }
        return descend(value, ArraySlice(path.split(separator: ".").map(String.init)))
    }
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/projection/move-candidates.json")
    do {
        let fixture = try JSONValue.parse(Data(contentsOf: path))
        for row in fixture.at(path: "cases")?.arrayValue ?? [] {
            let name = row.at(path: "name")!.stringValue!
            let world = row.at(path: "world")!
            let plan = BorderProjection.plan(world: world)
            let ghosts = plan.rings.filter { $0.stroke == .dashed }
            let expected = row.at(path: "commit_targets")!.objectValue!
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
                    plan.selectionLines == [BorderSelectionLine(axis: boundary.at(path: "axis")!.stringValue!,
                        coordinate: boundary.at(path: "coord")!.numberValue!, lower: boundary.at(path: "lo")!.numberValue!,
                        upper: boundary.at(path: "hi")!.numberValue!)])
                for mutation in fixture.at(path: "mutations")?.arrayValue ?? [] {
                    var changed = world
                    let path = mutation.at(path: "path")!.stringValue!
                    let value = mutation.at(path: "value")!
                    if let id = mutation.at(path: "window_id")?.intValue {
                        let windows = (changed.at(path: "windows")?.arrayValue ?? []).map { window -> JSONValue in
                            window.at(path: "window_id")?.intValue == id ? replacing(window, path: path, with: value) : window
                        }
                        changed = replacing(changed, path: "windows", with: .array(windows))
                    } else { changed = replacing(changed, path: path, with: value) }
                    let invalid = BorderProjection.plan(world: changed)
                    check("preview/\(mutation.at(path: "name")!.stringValue!)-clears-entire-candidate",
                        invalid.previewCandidateID == nil && invalid.rings.allSatisfy { $0.stroke == .solid && $0.role != .moveTo })
                }
            }
        }
    } catch { check("preview/fixture-error-\(error)", false) }
}
