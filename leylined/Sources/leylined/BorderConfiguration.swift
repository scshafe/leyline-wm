import Foundation
import LeylineModel

/// @canonical border_configuration -- optional user overrides for the resident border palette.
/// Missing files select canonical defaults. Invalid files fail the runtime geometry readiness gate.
enum BorderConfiguration {
    static func readStore() -> JSONValue? {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["LEYLINE_CONFIG_DIR"]
            ?? ((environment["LEYLINE_ROOT"] ?? (NSHomeDirectory() + "/.config/leyline")) + "/config")
        guard let data = FileManager.default.contents(atPath: directory + "/borders.json") else { return nil }
        return try? JSONValue.parse(data)
    }
}
