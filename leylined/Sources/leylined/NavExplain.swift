// nav-explain — the headless scene runner backing the `core` backend of
// display_geometry/nav-tests.sh. Scene parsing mirrors leyline-menu-ui's
// NavExplainCLI exactly: the same key aliases, the same visibility defaults
// (is_visible true / is_minimized false), the same filter order — a hidden or
// minimized source is filtered before lookup and therefore reports noFocus.
import Foundation
import LeylineModel

private func intValue(_ raw: [String: Any], _ keys: String...) -> Int? {
    for k in keys {
        if let v = raw[k] as? Int { return v }
        if let v = raw[k] as? Double { return Int(v) }
        if let v = raw[k] as? String, let n = Int(v) { return n }
    }
    return nil
}

private func boolValue(_ raw: [String: Any], _ keys: String..., default def: Bool) -> Bool {
    for k in keys {
        if let v = raw[k] as? Bool { return v }
    }
    return def
}

private func doubleValue(_ raw: [String: Any], _ key: String) -> Double? {
    if let v = raw[key] as? Double { return v }
    if let v = raw[key] as? Int { return Double(v) }
    return nil
}

private func frameFromDict(_ raw: [String: Any]) -> NavRect? {
    guard let x = doubleValue(raw, "x"), let y = doubleValue(raw, "y"),
          let w = doubleValue(raw, "w"), let h = doubleValue(raw, "h") else { return nil }
    return NavRect(x: x, y: y, w: w, h: h)
}

private func parseScene(_ data: Data) -> (displays: [NavRect], windows: [NavWindow], sourceId: Int?)? {
    guard let scene = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

    let displays = (scene["displays"] as? [[String: Any]] ?? []).compactMap { raw -> NavRect? in
        guard intValue(raw, "index", "display", "display_id", "id") != nil,
              let frameDict = raw["frame"] as? [String: Any] else { return nil }
        return frameFromDict(frameDict)
    }

    let windows = (scene["windows"] as? [[String: Any]] ?? []).compactMap { raw -> NavWindow? in
        let visible = boolValue(raw, "is_visible", "is-visible", "visible", default: true)
        let minimized = boolValue(raw, "is_minimized", "is-minimized", "minimized", default: false)
        guard visible, !minimized,
              let id = intValue(raw, "id", "window_id"),
              let display = intValue(raw, "display", "display_id"),
              let frameDict = raw["frame"] as? [String: Any],
              let frame = frameFromDict(frameDict) else { return nil }
        return NavWindow(id: id, display: display, frame: frame)
    }

    let sourceId = (scene["source"] as? [String: Any]).flatMap { intValue($0, "window_id", "id") }
    return (displays, windows, sourceId)
}

func runNavExplain(_ args: [String]) -> Int32 {
    var scenePath: String?
    var directionArg: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--scene" where i + 1 < args.count:
            scenePath = args[i + 1]
            i += 2
        case "--direction" where i + 1 < args.count:
            directionArg = args[i + 1]
            i += 2
        default:
            FileHandle.standardError.write(Data("leylined nav-explain: unknown/incomplete arg '\(args[i])'\n".utf8))
            return 64
        }
    }

    guard let scenePath, let directionArg, let direction = NavDirection(rawValue: directionArg) else {
        FileHandle.standardError.write(Data("usage: leylined nav-explain --scene <file> --direction west|south|north|east\n".utf8))
        return 64
    }
    guard let data = FileManager.default.contents(atPath: scenePath) else {
        FileHandle.standardError.write(Data("leylined nav-explain: cannot read scene \(scenePath)\n".utf8))
        return 66
    }
    guard let (displays, windows, sourceId) = parseScene(data) else {
        FileHandle.standardError.write(Data("leylined nav-explain: malformed scene JSON \(scenePath)\n".utf8))
        return 65
    }

    let explanation: NavExplanation
    if let sourceId {
        let nav = SpatialNav(displayFrames: displays, windows: windows)
        explanation = nav.explain(sourceId: sourceId, direction: direction)
    } else {
        explanation = NavExplanation(direction: direction, outcome: .noFocus, winner: nil, ranked: [])
    }

    let out: [String: Any] = [
        "direction": explanation.direction.rawValue,
        "outcome": explanation.outcome.rawValue,
        "winner": explanation.winner as Any? ?? NSNull(),
        "ranked": explanation.ranked,
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else {
        return 70
    }
    print(String(decoding: json, as: UTF8.self))
    return 0
}
