import Foundation

/// @canonical resident_resource_home -- immutable package resources are independent of user state.
/// Development and install wrappers may set LEYLINE_HOME; bundled builds use Resources/leyline.
enum ResidentResources {
    static func home() -> String {
        if let explicit = ProcessInfo.processInfo.environment["LEYLINE_HOME"], !explicit.isEmpty { return explicit }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/leyline").path
    }
}
