import Darwin
import Foundation
import LeylineModel

/// Real socket availability and filesystem boundary checks, without runtime grants.
func runSocketBoundaryScenarios(check: (String, Bool) -> Void) {
    let home = "/tmp/ley-socket-" + String(UUID().uuidString.prefix(12))
    do {
        let parent = try ResidentPrivateFiles.openDirectory(at: home, create: true)
        close(parent)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let collisionPath = home + "/existing-file"
        let sentinel = Data("preserve".utf8)
        try sentinel.write(to: URL(fileURLWithPath: collisionPath))
        let collision = CoreServer(socketPath: collisionPath)
        let refused = !collision.start()
        collision.stop()
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: collisionPath))
        check("socket non-socket collision refuses without unlinking user data", refused && unchanged == sentinel)
        let publicHome = home + "/public"
        guard mkdir(publicHome, mode_t(0o755)) == 0, chmod(publicHome, mode_t(0o755)) == 0 else {
            check("socket public directory fixture", false); return
        }
        let unsafe = CoreServer(socketPath: publicHome + "/core.sock")
        check("socket refuses a non-private owner directory", !unsafe.start())
        unsafe.stop()
        let ownerPath = home + "/owned.sock"
        let owner = CoreServer(socketPath: ownerPath)
        guard owner.start() else { check("socket collision owner starts", false); return }
        let duplicate = CoreServer(socketPath: ownerPath)
        check("second server refuses to replace a live socket", !duplicate.start())
        duplicate.stop(); owner.stop()
        let path = home + "/bounded.sock"
        let server = CoreServer(socketPath: path, maximumConnections: 2)
        guard server.start() else { check("socket boundary server starts", false); return }
        defer { server.stop() }
        var directoryFacts = stat()
        check("socket-created state directory is owner-only", stat(home, &directoryFacts) == 0 && directoryFacts.st_mode & 0o777 == 0o700)
        // Existing connection readiness is established through actual replies, never sleep.
        guard let first = FramedJSONSocket.connect(path: path, timeoutSeconds: 3),
              let second = FramedJSONSocket.connect(path: path, timeoutSeconds: 3) else {
            check("socket cap fixtures connect", false); return
        }
        func hello(_ descriptor: Int32) -> Bool {
            guard FramedJSONSocket.writeAll(descriptor, FramedJSONSocket.encode(.object(["op": .string("hello")]))),
                  let bytes = FramedJSONSocket.readFrame(descriptor), let value = try? JSONValue.parse(bytes) else { return false }
            return value.at(path: "ok") == .bool(true)
        }
        let firstAlive = hello(first), secondAlive = hello(second)
        if let third = FramedJSONSocket.connect(path: path, timeoutSeconds: 3) {
            check("total connection cap rejects extra clients while retaining admitted clients",
                firstAlive && secondAlive && !hello(third) && hello(first))
            close(third)
        } else { check("socket cap refusal connection", false) }
        close(first); close(second)
        // Wait only for the exact lifecycle edge needed to obtain a free connection slot.
        var probe: Int32?
        let limit = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while probe == nil, DispatchTime.now().uptimeNanoseconds < limit {
            if let candidate = FramedJSONSocket.connect(path: path, timeoutSeconds: 1) {
                if hello(candidate) { probe = candidate } else { close(candidate) }
            }
        }
        guard let probe else { check("socket cap releases completed connection slots", false); return }
        var oversized = UInt32(65_537).bigEndian
        _ = withUnsafeBytes(of: &oversized) { FramedJSONSocket.writeAll(probe, Data($0)) }
        check("socket rejects request lengths above64KiB before allocating payload", FramedJSONSocket.readFrame(probe) == nil)
        close(probe)
        guard let stalled = FramedJSONSocket.connect(path: path, timeoutSeconds: 3), hello(stalled) else {
            check("socket deadline fixture connects", false); return
        }
        defer { close(stalled) }
        _ = FramedJSONSocket.writeAll(stalled, Data([0]))
        let started = DispatchTime.now().uptimeNanoseconds
        let closed = FramedJSONSocket.readFrame(stalled) == nil
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        check("socket partial request prefix closes at a bounded whole-frame deadline",
            closed && elapsed >= 1_000_000_000 && elapsed < 2_800_000_000)
    } catch { check("socket boundary fixture failed: \(error)", false) }
}
