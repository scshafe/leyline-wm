import Foundation
import LeylineModel

/// @canonical resident_input_claim_inventory -- immutable projection of the actual input routes.
/// Loading this inventory never installs a tap, resolves AX windows, or starts a runtime owner.
struct ResidentInputClaims {
    private let configuration: ResidentInputConfiguration

    init(configuration: ResidentInputConfiguration) { self.configuration = configuration }

    /// Sorted chord tokens suppressed by the configured mode; unknown and retired modes are empty.
    func claims(for mode: String) -> [String] {
        actionRoutes(for: mode).keys.sorted()
    }

    /// Chord-to-action mapping from the canonical route table, including implicit modal exit keys.
    func actionRoutes(for mode: String) -> [String: String] {
        guard let index = configuration.modeNames.firstIndex(of: mode) else { return [:] }
        return configuration.routes[index].mapValues(\.actionId)
    }

    /// Optional structured inventory; plain stdout contains one sorted chord per line.
    func json(for mode: String) -> JSONValue {
        let routes = actionRoutes(for: mode)
        return .object([
            "schema": .string("leyline/resident-input-claims/v1"), "mode": .string(mode),
            "claims": .array(claims(for: mode).map(JSONValue.string)),
            "claim_count": .int(Int64(routes.count)),
            "action_routes": .object(JSONObject(unordered: routes.mapValues(JSONValue.string))),
            "retained_action_ids": .array(ResidentInput.retainedActionIds.sorted().map(JSONValue.string)),
            "unsupported_action_ids": .array(configuration.unsupportedActionIds.sorted().map(JSONValue.string)),
        ])
    }
}

/// Headless input-claim CLI. Args accept one mode, optional --json, and optional --home PATH.
/// Returns 0 for known/unknown empty modes, 2 for usage, and 1 for malformed or missing configuration.
func runResidentClaimsDump(_ arguments: [String]) -> Int32 {
    var mode: String?, home: String?, json = false, index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--json": json = true
        case "--home":
            index += 1
            guard index < arguments.count else { return residentClaimsUsage() }
            home = arguments[index]
        case let value where value.hasPrefix("--"):
            return residentClaimsUsage()
        case let value:
            guard mode == nil else { return residentClaimsUsage() }
            mode = value
        }
        index += 1
    }
    guard let mode else { return residentClaimsUsage() }
    do {
        let input = try ResidentInput.load(home: home ?? ResidentResources.home(),
            dispatchAction: { _, complete in complete(4) }, onModeChanged: { _, _, _ in true })
        let inventory = ResidentInputClaims(configuration: input.routing.configuration)
        let claims = inventory.claims(for: mode)
        guard mode != "default" || !claims.isEmpty else {
            residentClaimsError(code: "INPUT.CLAIMS_EMPTY_DEFAULT", message: "Default claim inventory is empty")
            return 1
        }
        if json { print(inventory.json(for: mode).canonical()) }
        else { for chord in claims { print(chord) } }
        return 0
    } catch {
        residentClaimsError(code: "INPUT.CLAIMS_CONFIGURATION_UNAVAILABLE", message: String(describing: error))
        return 1
    }
}

private func residentClaimsUsage() -> Int32 {
    FileHandle.standardError.write(Data("usage: leylined --dump-claims <mode> [--json] [--home PATH]\n".utf8))
    return 2
}

private func residentClaimsError(code: String, message: String) {
    let value: JSONValue = .object(["error": .object(["code": .string(code), "message": .string(message)])])
    FileHandle.standardError.write(Data((value.canonical() + "\n").utf8))
}
