// Headless CLI surfaces over the canonical border projection.
// Headless by design: these verbs never mount a panel, so the palette and the
// plan derivation stay inspectable from a test arm with no window server.
import Foundation
import LeylineModel

func runProjection(_ args: [String]) -> Int32 {
    switch args.first {
    case "--dump-palette":
        // Border-spacing checks pin defaults against the current registry.
        var out: JSONObject = [:]
        out["width"] = .int(Int64(BorderPalette.defaultThickness))
        out["border_radius"] = .int(Int64(BorderPalette.defaultRadius))
        var colors: JSONObject = [:]
        for role in BorderRole.allCases {
            colors[role.rawValue] = .string(BorderPalette.color(role, store: nil))
        }
        out["colors"] = .object(colors)
        print(JSONValue.object(out).canonical())
        return 0

    case "--dump-plan":
        guard let i = args.firstIndex(of: "--fixture"), i + 1 < args.count,
              let data = FileManager.default.contents(atPath: args[i + 1]),
              let world = try? JSONValue.parse(data) else {
            FileHandle.standardError.write(Data(
                "usage: leylined projection --dump-plan --fixture <world.json> [--with-store]\n".utf8))
            return 64
        }
        let store = args.contains("--with-store") ? BorderConfiguration.readStore() : nil
        let plan = BorderProjection.plan(world: world)
        var rings: [JSONValue] = []
        for r in plan.rings {
            var o: JSONObject = [:]
            o["window_id"] = .int(r.windowId)
            o["frame"] = r.frame.json
            o["role"] = .string(r.role.rawValue)
            o["color"] = .string(BorderPalette.color(r.role, store: store))
            rings.append(.object(o))
        }
        print(JSONValue.object(["rings": .array(rings)]).canonical())
        return 0

    default:
        FileHandle.standardError.write(Data(
            "usage: leylined projection (--dump-palette | --dump-plan --fixture <world.json>)\n".utf8))
        return 64
    }
}
