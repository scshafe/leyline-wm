import Foundation
import LeylineModel

/// Reply envelopes shared by the socket layer, the controller, runtime services and the CLI.
enum ResidentReply {
    /// A request refused before any effect: completed, not ok, with its reason.
    static func refused(requestID: JSONValue, reason: String) -> JSONValue {
        .object(["ok": .bool(false), "status": .string(WmStatus.refused.rawValue), "phase": .string("completed"),
                 "request_id": requestID, "reason": .string(reason)])
    }

    /// The envelope every native CLI entry prints: data, error and the caller's meta.
    static func cliEnvelope(data: JSONValue?, error: JSONValue?, meta: JSONObject) -> JSONValue {
        .object(["data": data ?? .null, "error": error ?? .null, "meta": .object(meta)])
    }
}

/// The sysexits-style codes the native CLI entries share with the shell wrappers.
enum ResidentExitCode {
    /// Arguments were malformed.
    static let usage: Int32 = 64
    /// The resident or installer refused the request.
    static let refused: Int32 = 65
    /// No resident, client or resource was available to serve it.
    static let unavailable: Int32 = 69
}
