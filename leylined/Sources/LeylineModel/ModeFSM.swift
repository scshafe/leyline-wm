// Move/resize mode manifest and exit predicate evaluator. A stale referenced
// window universally exits the mode before its ordinary return-code predicate.
import Foundation

public enum ModeManifestError: Error, Sendable {
    case malformed
    case wrongSchema(String)
    case unknownPredicate(mode: String, key: String, predicate: String)
}

public enum ExitPredicate: String, CaseIterable, Sendable {
    case exitOnRc0 = "exit_on_rc0"
    case exitUnlessRcIn1Or3 = "exit_unless_rc_in_1_3"
    case exitOnAnyNonzero = "exit_on_any_nonzero"
    case unconditionalExit = "unconditional_exit"
    case noExit = "no_exit"

    /// The evaluator, semantics verbatim from parcel/mode-fsm-tests.sh
    /// `evaluate` (predicate × rc → exit?).
    public func exits(rc: Int) -> Bool {
        switch self {
        case .exitOnRc0: return rc == 0
        case .exitUnlessRcIn1Or3: return !(rc == 1 || rc == 3)
        case .exitOnAnyNonzero: return rc != 0
        case .unconditionalExit: return true
        case .noExit: return false
        }
    }
}

public struct ModeBinding: Sendable {
    public let key: String
    public let actionId: String
    public let onDone: ExitPredicate
}

public struct Mode: Sendable {
    public let id: String
    public let enterChord: String
    public let enterActionId: String
    public let enterOnDone: ExitPredicate
    public let exitKeys: [String]
    public let bindings: [ModeBinding]
}

public struct ModeFSM: Sendable {
    public let modes: [String: Mode]

    /// The universal staleness rc (mode-fsm-spec §6/§9.8): a verb that found a
    /// referenced window gone returns 4 and the FSM force-exits to default
    /// BEFORE the binding's ordinary predicate — even a `no_exit` binding exits.
    public static let staleRc = 4

    /// Fail-closed loader: wrong schema or an unknown predicate name throws —
    /// a planted manifest can never bind a chord to undefined exit behavior.
    public init(manifestData: Data) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any] else {
            throw ModeManifestError.malformed
        }
        let schema = obj["_schema"] as? String ?? "<missing>"
        guard schema == "modes/v1" else { throw ModeManifestError.wrongSchema(schema) }
        guard let rawModes = obj["modes"] as? [[String: Any]] else { throw ModeManifestError.malformed }

        var parsed: [String: Mode] = [:]
        for raw in rawModes {
            guard let id = raw["id"] as? String,
                  let enter = raw["enter"] as? [String: Any],
                  let enterChord = enter["chord"] as? String,
                  let enterActionId = enter["action_id"] as? String,
                  let enterOnDoneRaw = enter["on_done"] as? String else {
                throw ModeManifestError.malformed
            }
            guard let enterOnDone = ExitPredicate(rawValue: enterOnDoneRaw) else {
                throw ModeManifestError.unknownPredicate(mode: id, key: enterChord, predicate: enterOnDoneRaw)
            }
            let exitKeys = raw["exit_keys"] as? [String] ?? []
            var bindings: [ModeBinding] = []
            for b in raw["bindings"] as? [[String: Any]] ?? [] {
                guard let key = b["key"] as? String,
                      let actionId = b["action_id"] as? String,
                      let onDoneRaw = b["on_done"] as? String else {
                    throw ModeManifestError.malformed
                }
                guard let onDone = ExitPredicate(rawValue: onDoneRaw) else {
                    throw ModeManifestError.unknownPredicate(mode: id, key: key, predicate: onDoneRaw)
                }
                bindings.append(ModeBinding(key: key, actionId: actionId, onDone: onDone))
            }
            parsed[id] = Mode(
                id: id,
                enterChord: enterChord,
                enterActionId: enterActionId,
                enterOnDone: enterOnDone,
                exitKeys: exitKeys,
                bindings: bindings
            )
        }
        self.modes = parsed
    }

    /// One in-mode FSM step for a binding already resolved to its predicate:
    /// rc4 force-exits to default before the ordinary predicate runs.
    public static func step(mode: String, predicate: ExitPredicate, rc: Int) -> (nextMode: String, exit: Bool) {
        if rc == staleRc { return ("default", true) }
        let exits = predicate.exits(rc: rc)
        return (exits ? "default" : mode, exits)
    }

    #if LEYLINE_BUILD_TESTS
    /// The frozen-oracle row set for one mode, keyed exactly as
    /// mode-fsm-tests.sh `frozen_predicate` keys it: (chord, is_enter) →
    /// "predicate:<name>" | "transition:default".
    public func frozenRows(mode id: String) -> [String: String]? {
        guard let mode = modes[id] else { return nil }
        var rows: [String: String] = [:]
        func key(_ chord: String, _ isEnter: Bool) -> String {
            "\(chord)\u{1F}\(isEnter ? "1" : "0")"
        }
        rows[key(mode.enterChord, true)] = "predicate:\(mode.enterOnDone.rawValue)"
        for b in mode.bindings {
            rows[key(b.key, false)] = "predicate:\(b.onDone.rawValue)"
        }
        for k in mode.exitKeys {
            rows[key(k, false)] = "transition:default"
        }
        return rows
    }
    #endif
}
