// One-shot client for the resident's Unix socket: 4-byte big-endian
// length-prefixed JSON frames. The CLI sends only registered resident
// actions through the CoreServer mutation surface.
import Foundation
import LeylineModel

enum ServeClient {
    static func request(socketPath: String, body: JSONObject, timeoutSeconds: Double = 3) -> JSONValue? {
        guard let fd = FramedJSONSocket.connect(
            path: socketPath, timeoutSeconds: max(1, Int(timeoutSeconds))) else {
            return nil
        }
        defer { close(fd) }
        guard FramedJSONSocket.writeAll(
            fd, FramedJSONSocket.encode(.object(body))),
              let response = FramedJSONSocket.readFrame(fd) else { return nil }
        return try? JSONValue.parse(response)
    }
}
