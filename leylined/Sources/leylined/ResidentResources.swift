import Foundation

/// @canonical resident_resource_home -- immutable package resources are independent of user state.
/// Development and install wrappers may set LEYLINE_HOME; bundled builds use Resources/leyline.
enum ResidentResources {
    static func home() -> String {
        if let explicit = ProcessInfo.processInfo.environment["LEYLINE_HOME"], !explicit.isEmpty { return explicit }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/leyline").path
    }
}

/// The user-data layout as pure path functions of a root (or of the resolved
/// config/runtime directories). The installer creates exactly these locations
/// and `ResidentPaths` resolves them for the running resident; neither spells
/// a path the other does not.
enum ResidentLayout {
    static func config(root: String) -> String { root + "/config" }
    static func runtime(root: String) -> String { root + "/runtime" }
    static func sockets(root: String) -> String { runtime(root: root) + "/sockets" }
    static func state(root: String) -> String { root + "/state/leylined" }
    static func settings(config: String) -> String { config + "/leylined-settings.json" }
    static func borders(config: String) -> String { config + "/borders.json" }
    static func socket(runtime: String) -> String { runtime + "/sockets/leylined.sock" }
    static func journal(root: String) -> String { state(root: root) + "/journal.jsonl" }
    static func stdoutLog(root: String) -> String { runtime(root: root) + "/leylined.stdout.log" }
    static func stderrLog(root: String) -> String { runtime(root: root) + "/leylined.stderr.log" }
    /// The shipped keymap resources, beside `VERSION` under the resource home.
    static let keymapFiles = ["decode-us", "global", "modes"]
    static func keymap(_ name: String, home: String) -> String { home + "/keymap/" + name + ".json" }
}

/// @canonical resident_user_paths -- the user-data root and its derived locations;
/// LEYLINE_ROOT, LEYLINE_RUNTIME_DIR and LEYLINE_CONFIG_DIR override them.
enum ResidentPaths {
    static func root(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["LEYLINE_ROOT"] ?? (NSHomeDirectory() + "/.config/leyline")
    }
    static func runtime(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["LEYLINE_RUNTIME_DIR"] ?? ResidentLayout.runtime(root: root(environment))
    }
    static func socket(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ResidentLayout.socket(runtime: runtime(environment))
    }
    static func config(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["LEYLINE_CONFIG_DIR"] ?? ResidentLayout.config(root: root(environment))
    }
}
