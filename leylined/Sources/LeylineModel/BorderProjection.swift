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

/// The moved window's exact insertion destination and selected side. Decoration
/// consumes the candidate; it never guesses placement from the observed cursor.
public struct BorderInsertionPreview: Equatable, Sendable {
    public let windowId: Int64
    public let frame: Frame
    public let side: NavDirection
    public let isAvailable: Bool

    public init(windowId: Int64, frame: Frame, side: NavDirection, isAvailable: Bool = true) {
        self.windowId = windowId; self.frame = frame; self.side = side
        self.isAvailable = isAvailable
    }

    public var arrow: String {
        switch side {
        case .west: return "←"
        case .east: return "→"
        case .north: return "↑"
        case .south: return "↓"
        }
    }

    public var sideLabel: String {
        switch side {
        case .west: return "LEFT"
        case .east: return "RIGHT"
        case .north: return "ABOVE"
        case .south: return "BELOW"
        }
    }

    public var label: String { isAvailable ? "\(arrow) INSERT \(sideLabel)" : "\(arrow) \(sideLabel) WON'T FIT" }
}

public struct BorderPlan: Equatable, Sendable {
    public let rings: [BorderRing]
    public let selectionLines: [BorderSelectionLine]
    public let previewCandidateID: String?
    public let insertionPreview: BorderInsertionPreview?
    public init(rings: [BorderRing], previewCandidateID: String? = nil,
                selectionLines: [BorderSelectionLine] = [], insertionPreview: BorderInsertionPreview? = nil) {
        self.rings = rings; self.previewCandidateID = previewCandidateID; self.selectionLines = selectionLines
        self.insertionPreview = insertionPreview
    }
    public static let empty = BorderPlan(rings: [])
}

public enum BorderProjection {
    /// Derive a decoration only from positively identified managed membership
    /// in an enabled visible display-local Space. Missing authority clears it.
    /// Each phase either extends the plan or returns what was authored before
    /// it: the fallbacks are positional, and the projection suite pins them.
    public static func plan(world: JSONValue) -> BorderPlan {
        guard let focus = admittedFocus(world: world) else { return .empty }
        var rings = [BorderRing(windowId: focus.windowID, frame: focus.frame, role: focus.role)]
        guard let move = moveInteraction(world: world, focus: focus) else { return BorderPlan(rings: rings) }
        if move.interaction.at(path: "candidate") == nil,
           move.interaction.at(path: "candidate_unavailable_reason") == .string("move_partition_or_min_fit_refused") {
            return unavailableInsertionPlan(world: world, focus: focus, move: move, rings: rings) ?? BorderPlan(rings: rings)
        }
        guard let candidate = currentCandidate(world: world, focus: focus, move: move),
              let ghosts = ghostRings(affected: candidate.affected, targets: candidate.targets, world: world) else {
            return BorderPlan(rings: rings)
        }
        if move.cursor != focus.windowID {
            guard let cursor = cursorRing(cursor: move.cursor, world: world) else { return BorderPlan(rings: rings) }
            rings.append(cursor)
        }
        var lines: [BorderSelectionLine] = []
        var insertion: BorderInsertionPreview?
        if candidate.value.at(path: "operation")?.stringValue == "insert" {
            guard let cue = insertionCue(candidate: candidate.value, targets: candidate.targets, source: focus.windowID) else {
                return BorderPlan(rings: rings)
            }
            lines = [cue.line]; insertion = cue.preview
        }
        return BorderPlan(rings: rings + ghosts, previewCandidateID: candidate.id, selectionLines: lines,
                          insertionPreview: insertion)
    }

    private struct AdmittedFocus {
        let window: JSONObject
        let windowID: Int64
        let spaceKey: String
        let frame: Frame
        let role: BorderRole
        /// The held mode names this window in this Space.
        let modeOwnsFocus: Bool
    }

    /// The decorated window: the bound move source when a later focus change
    /// would otherwise retarget it, else the observed focus; every fact positive.
    private static func admittedFocus(world: JSONValue) -> AdmittedFocus? {
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
        else { return nil }

        let modeOwnsFocus = world.at(path: "mode_context_window_id")?.intValue == wid
            && world.at(path: "mode_context_space_key")?.stringValue == spaceKey
        let role: BorderRole
        switch modeOwnsFocus ? world.at(path: "mode")?.stringValue : nil {
        case "resize": role = .resizing
        case "move": role = .moved
        default: role = .focus
        }
        return AdmittedFocus(window: focus, windowID: wid, spaceKey: spaceKey, frame: frame, role: role,
                             modeOwnsFocus: modeOwnsFocus)
    }

    private struct MoveInteraction {
        let state: JSONValue
        let interaction: JSONValue
        let cursor: Int64
    }

    /// The held move must be this window's, in this Space, with a cursor.
    private static func moveInteraction(world: JSONValue, focus: AdmittedFocus) -> MoveInteraction? {
        guard focus.modeOwnsFocus, world.at(path: "mode")?.stringValue == "move",
              let state = world.at(path: "model_state"),
              let interaction = state.at(path: "interaction"),
              interaction.at(path: "mode")?.stringValue == "move",
              interaction.at(path: "source_window_id")?.intValue == focus.windowID,
              interaction.at(path: "active_space_key")?.stringValue == focus.spaceKey,
              let cursor = interaction.at(path: "cursor_window_id")?.intValue else { return nil }
        return MoveInteraction(state: state, interaction: interaction, cursor: cursor)
    }

    /// An admitted edge with no placement promise: the destination is outlined
    /// as unavailable only while the refusal still names the live cursor.
    private static func unavailableInsertionPlan(world: JSONValue, focus: AdmittedFocus, move: MoveInteraction,
                                                 rings: [BorderRing]) -> BorderPlan? {
        let interaction = move.interaction
        guard interaction.at(path: "observer_epoch") == world.at(path: "observer_epoch"),
              interaction.at(path: "observer_generation") == world.at(path: "observer_generation"),
              interaction.at(path: "topology_revision") == world.at(path: "topology_revision"),
              identityMatches(interaction.at(path: "source_identity"), window: .object(focus.window)),
              let selection = interaction.at(path: "selection"),
              selection.at(path: "cursor_window_id")?.intValue == move.cursor,
              let boundary = insertionBoundary(selection),
              interaction.at(path: "staged_edge")?.stringValue == boundary.side.rawValue else { return nil }
        let matches = (world.at(path: "windows")?.arrayValue ?? []).filter { $0.at(path: "window_id")?.intValue == move.cursor }
        guard matches.count == 1, let target = matches.first,
              identityMatches(interaction.at(path: "preview_refusal_cursor_identity"), window: target),
              target.at(path: "managed")?.boolValue != false, target.at(path: "eligible")?.boolValue == true,
              target.at(path: "space_visible")?.boolValue == true, target.at(path: "space_enabled")?.boolValue == true,
              target.at(path: "space_identity_available")?.boolValue != false,
              target.at(path: "minimized")?.boolValue != true, target.at(path: "destroyed")?.boolValue != true,
              let targetSpace = target.at(path: "space_key")?.stringValue, !targetSpace.isEmpty, !targetSpace.contains("runtime:"),
              world.at(path: "space_activation")?.objectValue?[targetSpace]?.boolValue != false,
              let targetFrame = strictFrame(target.at(path: "frame")) else { return nil }
        var rings = rings
        if move.cursor != focus.windowID { rings.append(BorderRing(windowId: move.cursor, frame: targetFrame, role: .moveTo)) }
        return BorderPlan(rings: rings, selectionLines: [boundary.line], insertionPreview:
            BorderInsertionPreview(windowId: focus.windowID, frame: targetFrame, side: boundary.side, isAvailable: false))
    }

    private struct CurrentCandidate {
        let value: JSONValue
        let id: String
        let affected: JSONObject
        let targets: JSONObject
    }

    /// The bound candidate, still current against this world and naming this cursor.
    private static func currentCandidate(world: JSONValue, focus: AdmittedFocus, move: MoveInteraction) -> CurrentCandidate? {
        guard let candidate = move.interaction.at(path: "candidate"),
              let candidateID = candidate.at(path: "candidate_id")?.stringValue, !candidateID.isEmpty,
              (candidate.at(path: "operation")?.stringValue != "swap"
                || candidate.at(path: "target_window_id")?.intValue == move.cursor) else { return nil }
        // The controller's normalized active context names this same raw Space.
        // This read lens supplies that name to the shared provenance guard only.
        var context = world.objectValue ?? [:]
        context["active_space_key"] = world.at(path: "active_space_key") ?? .string(focus.spaceKey)
        guard MoveCandidate.isCurrent(candidate: candidate, state: move.state, world: .object(context)),
              let affected = candidate.at(path: "affected_frames")?.objectValue,
              let targets = candidate.at(path: "targets")?.objectValue else { return nil }
        return CurrentCandidate(value: candidate, id: candidateID, affected: affected, targets: targets)
    }

    /// One dashed ring per affected window at its previewed physical frame. An
    /// affected window that is not live and enabled in its Space voids them all.
    private static func ghostRings(affected: JSONObject, targets: JSONObject, world: JSONValue) -> [BorderRing]? {
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
                  let liveDisplay = live.at(path: "display_id")?.stringValue, !liveDisplay.isEmpty else { return nil }
            // Hidden members have a separately authored physical stack placement.
            // Both visible and hidden effects are previewed verbatim; null means
            // the canonical author requested no physical frame for this record.
            let physicalFrame = target.at(path: "effect_frame") ?? target.at(path: "frame")
            if target.at(path: "presented")?.boolValue == false, physicalFrame == nil || physicalFrame == .null { continue }
            guard let ghost = strictFrame(physicalFrame) else { return nil }
            ghosts.append(BorderRing(windowId: windowID, frame: ghost, role: .dropEdge, stroke: .dashed))
        }
        return ghosts
    }

    /// The cursor's own ring, at its observed frame, while it is live and enabled.
    private static func cursorRing(cursor: Int64, world: JSONValue) -> BorderRing? {
        guard let live = (world.at(path: "windows")?.arrayValue ?? []).first(where: { $0.at(path: "window_id")?.intValue == cursor }),
              live.at(path: "eligible")?.boolValue == true,
              live.at(path: "space_enabled")?.boolValue == true,
              live.at(path: "space_visible")?.boolValue == true,
              live.at(path: "minimized")?.boolValue != true,
              let cursorFrame = strictFrame(live.at(path: "frame")) else { return nil }
        return BorderRing(windowId: cursor, frame: cursorFrame, role: .moveTo)
    }

    /// The staged boundary and the source's previewed destination for an insert.
    private static func insertionCue(candidate: JSONValue, targets: JSONObject, source wid: Int64)
        -> (line: BorderSelectionLine, preview: BorderInsertionPreview)? {
        guard let boundary = insertionBoundary(candidate.at(path: "selection")),
              let sourceTarget = targets[String(wid)], sourceTarget.at(path: "window_id")?.intValue == wid,
              sourceTarget.at(path: "presented")?.boolValue != false,
              let sourceFrame = strictFrame(sourceTarget.at(path: "effect_frame") ?? sourceTarget.at(path: "frame"))
              else { return nil }
        return (boundary.line, BorderInsertionPreview(windowId: wid, frame: sourceFrame, side: boundary.side))
    }

    private static func insertionBoundary(_ selection: JSONValue?) -> (line: BorderSelectionLine, side: NavDirection)? {
        guard let boundary = selection?.at(path: "boundary"),
              let axis = boundary.at(path: "axis")?.stringValue, ["h", "v"].contains(axis),
              let coordinate = boundary.at(path: "coord")?.numberValue,
              let lower = boundary.at(path: "lo")?.numberValue, let upper = boundary.at(path: "hi")?.numberValue,
              [coordinate, lower, upper].allSatisfy({ $0.isFinite }), upper > lower,
              let rawSide = boundary.at(path: "side")?.stringValue, let side = NavDirection(rawValue: rawSide),
              (axis == "h" ? [NavDirection.north, .south] : [.west, .east]).contains(side) else { return nil }
        return (BorderSelectionLine(axis: axis, coordinate: coordinate, lower: lower, upper: upper), side)
    }

    private static func identityMatches(_ identity: JSONValue?, window: JSONValue) -> Bool {
        guard let identity else { return false }
        return ["window_id", "pid", "window_generation"].allSatisfy {
            guard let expected = identity.at(path: $0)?.intValue, expected > 0 else { return false }
            return window.at(path: $0)?.intValue == expected
        } && ["space_key", "display_id"].allSatisfy {
            guard let expected = identity.at(path: $0)?.stringValue, !expected.isEmpty else { return false }
            return window.at(path: $0)?.stringValue == expected
        }
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

/// Typed border roles resolve user-store-over-default. This is the only owner of
/// border defaults; installation seeds `configurationDefaults` for editing.
public enum BorderPalette {
    public static let defaults: [BorderRole: String] = [
        .focus: "0xff39ff14",
        .resizing: "0xffff8c00",
        .moved: "0xff2962ff",
        .moveTo: "0xffff5fa2",
        .dropEdge: "0xffffd400",
    ]

    public static let thickness = 1
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

    /// The nested shape `color(_:store:)` and `radius(store:)` read.
    public static var configurationDefaults: JSONObject {
        JSONObject([("border_radius", .int(Int64(defaultRadius))),
                    ("colors", .object(JSONObject(unordered: Dictionary(uniqueKeysWithValues:
                        defaults.map { ($0.key.rawValue, JSONValue.string($0.value)) }))))])
    }

    public static func isWellFormedColor(_ s: String) -> Bool {
        guard s.count == 10, s.hasPrefix("0x") else { return false }
        return s.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    public static func radius(store: JSONValue?) -> Int {
        store?.at(path: "border_radius")?.intValue.map(Int.init) ?? defaultRadius
    }
}
