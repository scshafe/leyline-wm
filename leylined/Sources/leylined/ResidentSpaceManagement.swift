import Foundation
import LeylineModel

/// @canonical resident_space_management -- menu and keyboard share one durable
/// Space preference mutation. No window geometry or other Space is authored here.
enum ResidentSpaceManagement {
    static func toggle(target: ResidentSpaceTarget, world: JSONValue, settingsPath: String,
                       desiredRunning: Bool, commit: (String, Bool) -> WmResult) throws -> Bool {
        guard target.isVisible(in: world) else {
            throw ResidentInputError(code: "space_identity_unavailable", message: "Cannot toggle an unidentified or inactive Space")
        }
        let current = ResidentSettingsStore.read(path: settingsPath)
        if let error = current.errorCode {
            throw ResidentInputError(code: error, message: "Cannot read Space preferences for toggle")
        }
        let next = !current.enabled(spaceKey: target.spaceKey)
        var spaces = current.spacesEnabled
        spaces[target.spaceKey] = next
        try ResidentSettingsStore.write(path: settingsPath, spacesEnabled: spaces,
            desiredRunning: desiredRunning, globalGutterWidth: current.globalGutterWidth)
        let result = commit(target.spaceKey, next)
        guard result.status == .accepted || result.status == .noop else {
            throw ResidentInputError(code: result.reason ?? "space_activation_commit_failed",
                message: "Space preference saved but activation was refused")
        }
        return next
    }
}
