// The immutable border projection consumed by the resident renderer.
//
// A projection is a function from a published revision to what should be on
// screen. Keeping that function here — dependency-free, no AppKit, no world
// access — is what makes the renderer testable without a window server, and
// what makes "the renderer never computes, it renders" enforceable rather
// than aspirational: the AppKit half may only consume a BorderPlan.
//
import Foundation

/// The active border colour roles, configured through `colors.<role>`.
public enum BorderRole: String, Sendable, CaseIterable {
    case focus
    case resizing
    case stacked
    case moved
    case moveTo = "move_to"
    case dropEdge = "drop_edge"
}

public enum BorderStroke: String, Sendable { case solid, dashed }

public struct BorderRing: Equatable, Sendable {
    public let windowId: Int64
    public let frame: Frame
    public let role: BorderRole
    public let stroke: BorderStroke

    public init(windowId: Int64, frame: Frame, role: BorderRole, stroke: BorderStroke = .solid) {
        self.windowId = windowId
        self.frame = frame
        self.role = role
        self.stroke = stroke
    }

    /// Exact outside-stroke footprint; the inner edge touches the window.
    public func envelope(thickness: Double) -> Frame {
        Frame(x: frame.x - thickness, y: frame.y - thickness,
              w: frame.w + 2 * thickness, h: frame.h + 2 * thickness)
    }
}

/// The staged boundary is read verbatim from the canonical selection. Its
/// extent represents one edge, the selected run, or its enclosing parent.
public struct BorderSelectionLine: Equatable, Sendable {
    public let axis: String
    public let coordinate: Double
    public let lower: Double
    public let upper: Double
    public init(axis: String, coordinate: Double, lower: Double, upper: Double) {
        self.axis = axis; self.coordinate = coordinate; self.lower = lower; self.upper = upper
    }
}

public struct BorderPlan: Equatable, Sendable {
    public let rings: [BorderRing]
    public let selectionLines: [BorderSelectionLine]
    public let previewCandidateID: String?
    public init(rings: [BorderRing], previewCandidateID: String? = nil,
                selectionLines: [BorderSelectionLine] = []) {
        self.rings = rings; self.previewCandidateID = previewCandidateID; self.selectionLines = selectionLines
    }
    public static let empty = BorderPlan(rings: [])
}

public enum BorderProjection {
    /// Derive a decoration only from positively identified managed membership
    /// in an enabled visible display-local Space. Missing authority clears it.
    public static func plan(world: JSONValue) -> BorderPlan {
        let decorationFocus = originFocus(world: world) ?? world.at(path: "focus")
        guard world.at(path: "management_enabled")?.boolValue != false,
              world.at(path: "resident_running")?.boolValue != false,
              world.at(path: "persistence_available")?.boolValue != false,
              world.at(path: "geometry_available")?.boolValue != false,
              world.at(path: "observation.world_complete")?.boolValue != false,
              let focus = decorationFocus?.objectValue,
              focus["managed"]?.boolValue == true,
              focus["eligible"]?.boolValue == true,
              focus["space_enabled"]?.boolValue == true,
              focus["space_visible"]?.boolValue == true,
              focus["minimized"]?.boolValue != true,
              focus["destroyed"]?.boolValue != true,
              focus["framework"]?.boolValue != true,
              focus["tiled"]?.boolValue != false,
              let spaceKey = focus["space_key"]?.stringValue,
              !spaceKey.isEmpty, !spaceKey.contains("runtime:"),
              let display = focus["display_id"]?.stringValue, !display.isEmpty,
              let generation = focus["observer_generation"]?.intValue,
              generation == world.at(path: "observer_generation")?.intValue,
              let wid = focus["window_id"]?.intValue, wid > 0,
              let frame = Frame.from(focus["frame"]),
              frame.x.isFinite, frame.y.isFinite,
              frame.w.isFinite, frame.h.isFinite, frame.w > 0, frame.h > 0
        else { return .empty }

        let modeOwnsFocus = world.at(path: "mode_context_window_id")?.intValue == wid
            && world.at(path: "mode_context_space_key")?.stringValue == spaceKey
        let role: BorderRole
        switch modeOwnsFocus ? world.at(path: "mode")?.stringValue : nil {
        case "resize": role = .resizing
        case "move": role = .moved
        default: role = focus["stacked"]?.boolValue == true ? .stacked : .focus
        }
        var rings = [BorderRing(windowId: wid, frame: frame, role: role)]
        guard modeOwnsFocus, world.at(path: "mode")?.stringValue == "move",
              let state = world.at(path: "model_state"),
              let interaction = state.at(path: "interaction"),
              interaction.at(path: "mode")?.stringValue == "move",
              interaction.at(path: "source_window_id")?.intValue == wid,
              interaction.at(path: "active_space_key")?.stringValue == spaceKey,
              let cursor = interaction.at(path: "cursor_window_id")?.intValue,
              let candidate = interaction.at(path: "candidate"),
              let candidateID = candidate.at(path: "candidate_id")?.stringValue, !candidateID.isEmpty,
              (candidate.at(path: "operation")?.stringValue != "swap"
                || candidate.at(path: "target_window_id")?.intValue == cursor) else { return BorderPlan(rings: rings) }
        // The controller's normalized active context names this same raw Space.
        // This read lens supplies that name to the shared provenance guard only.
        var context = world.objectValue ?? [:]
        context["active_space_key"] = world.at(path: "active_space_key") ?? .string(spaceKey)
        guard MoveCandidate.isCurrent(candidate: candidate, state: state, world: .object(context)),
              let affected = candidate.at(path: "affected_frames")?.objectValue,
              let targets = candidate.at(path: "targets")?.objectValue else { return BorderPlan(rings: rings) }
        let observed = world.at(path: "windows")?.arrayValue ?? []
        var ghosts: [BorderRing] = []
        for id in affected.keys.sorted(by: { (Int64($0) ?? 0) < (Int64($1) ?? 0) }) {
            guard let target = affected[id], target == targets[id], let windowID = Int64(id), windowID > 0,
                  target.at(path: "window_id")?.intValue == windowID,
                  let live = observed.first(where: { $0.at(path: "window_id")?.intValue == windowID }),
                  live.at(path: "eligible")?.boolValue == true,
                  live.at(path: "managed")?.boolValue != false,
                  live.at(path: "space_visible")?.boolValue == true,
                  live.at(path: "space_enabled")?.boolValue == true,
                  live.at(path: "space_identity_available")?.boolValue != false,
                  live.at(path: "minimized")?.boolValue != true,
                  live.at(path: "destroyed")?.boolValue != true,
                  let liveSpace = live.at(path: "space_key")?.stringValue, !liveSpace.isEmpty,
                  !liveSpace.contains("runtime:"),
                  world.at(path: "space_activation")?.objectValue?[liveSpace]?.boolValue != false,
                  let liveDisplay = live.at(path: "display_id")?.stringValue, !liveDisplay.isEmpty else {
                return BorderPlan(rings: rings)
            }
            // Hidden members have a separately authored physical stack placement.
            // Both visible and hidden effects are previewed verbatim; null means
            // the canonical author requested no physical frame for this record.
            let physicalFrame = target.at(path: "effect_frame") ?? target.at(path: "frame")
            if target.at(path: "presented")?.boolValue == false, physicalFrame == nil || physicalFrame == .null { continue }
            guard let ghost = strictFrame(physicalFrame) else { return BorderPlan(rings: rings) }
            ghosts.append(BorderRing(windowId: windowID, frame: ghost, role: .dropEdge, stroke: .dashed))
        }
        if cursor != wid {
            guard let live = observed.first(where: { $0.at(path: "window_id")?.intValue == cursor }),
                  live.at(path: "eligible")?.boolValue == true,
                  live.at(path: "space_enabled")?.boolValue == true,
                  live.at(path: "space_visible")?.boolValue == true,
                  live.at(path: "minimized")?.boolValue != true,
                  let cursorFrame = strictFrame(live.at(path: "frame")) else { return BorderPlan(rings: rings) }
            rings.append(BorderRing(windowId: cursor, frame: cursorFrame, role: .moveTo))
        }
        var lines: [BorderSelectionLine] = []
        if candidate.at(path: "operation")?.stringValue == "insert" {
            guard let boundary = candidate.at(path: "selection.boundary"),
                  let axis = boundary.at(path: "axis")?.stringValue, ["h", "v"].contains(axis),
                  let coordinate = boundary.at(path: "coord")?.numberValue,
                  let lower = boundary.at(path: "lo")?.numberValue,
                  let upper = boundary.at(path: "hi")?.numberValue,
                  [coordinate, lower, upper].allSatisfy({ $0.isFinite }), upper > lower else { return BorderPlan(rings: rings) }
            lines = [BorderSelectionLine(axis: axis, coordinate: coordinate, lower: lower, upper: upper)]
        }
        return BorderPlan(rings: rings + ghosts, previewCandidateID: candidateID, selectionLines: lines)
    }

    private static func strictFrame(_ value: JSONValue?) -> Frame? {
        guard let object = value?.objectValue,
              let x = object["x"]?.numberValue, let y = object["y"]?.numberValue,
              let w = object["w"]?.numberValue, let h = object["h"]?.numberValue,
              [x, y, w, h].allSatisfy({ $0.isFinite }), w > 0, h > 0 else { return nil }
        return Frame(x: x, y: y, w: w, h: h)
    }

    /// A later desktop focus change cannot retarget an already bound source.
    /// The read uses only the current observed source record, never cached geometry.
    private static func originFocus(world: JSONValue) -> JSONValue? {
        guard world.at(path: "mode")?.stringValue == "move",
              let interaction = world.at(path: "model_state.interaction"),
              interaction.at(path: "mode")?.stringValue == "move",
              let source = interaction.at(path: "source_window_id")?.intValue,
              source != world.at(path: "focus.window_id")?.intValue,
              world.at(path: "mode_context_window_id")?.intValue == source,
              interaction.at(path: "active_space_key") == world.at(path: "mode_context_space_key"),
              interaction.at(path: "observer_generation") == world.at(path: "observer_generation") else { return nil }
        let matches = (world.at(path: "windows")?.arrayValue ?? []).filter { $0.at(path: "window_id")?.intValue == source }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Typed border roles resolve user-store-over-default; registry tests pin every default.
public enum BorderPalette {
    public static let defaults: [BorderRole: String] = [
        .focus: "0xff39ff14",
        .resizing: "0xffff8c00",
        .stacked: "0xff00d7d7",
        .moved: "0xff2962ff",
        .moveTo: "0xffff5fa2",
        .dropEdge: "0xffffd400",
    ]

    public static let defaultThickness = 1
    public static let defaultRadius = 12

    /// `store` is the parsed user config (`~/.config/leyline/config/borders.json`),
    /// nested as `{"colors": {"<role>": "0xAARRGGBB"}}`. A malformed override
    /// is IGNORED in favour of the default — a bad colour must not blank the
    /// ring.
    public static func color(_ role: BorderRole, store: JSONValue?) -> String {
        if let override = store?.at(path: "colors")?.objectValue?[role.rawValue]?.stringValue,
           isWellFormedColor(override) {
            return override
        }
        return defaults[role]!
    }

    public static func isWellFormedColor(_ s: String) -> Bool {
        guard s.count == 10, s.hasPrefix("0x") else { return false }
        return s.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    public static func thickness(store: JSONValue?) -> Int {
        store?.at(path: "width")?.intValue.map(Int.init) ?? defaultThickness
    }

    public static func radius(store: JSONValue?) -> Int {
        store?.at(path: "border_radius")?.intValue.map(Int.init) ?? defaultRadius
    }
}
