// Canonical 4-byte-big-endian framed JSON socket transport. CoreServer,
// ServeClient, and the resident command client all use this byte boundary.
import Darwin
import Foundation
import LeylineModel

/// @canonical framed_json_socket -- do not reimplement this framing or Unix
/// socket address construction elsewhere in the leylined executable target.
enum FramedJSONSocket {
    static let maximumPayloadBytes = 4 * 1024 * 1024

    static func connect(path: String, timeoutSeconds: Int? = nil) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return nil }

        if let timeoutSeconds {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            let length = socklen_t(MemoryLayout<timeval>.size)
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length) == 0 else { close(fd); return nil }
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let fits = withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { source in
                    guard strlen(source) < capacity else { return false }
                    strcpy(destination, source)
                    return true
                }
            }
        }
        guard fits else {
            close(fd)
            return nil
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func encode(_ value: JSONValue) -> Data {
        let payload = Data(value.canonical().utf8)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    static func readFrame(_ fd: Int32, maximumBytes: Int = maximumPayloadBytes,
                          timeoutMilliseconds: Int? = nil) -> Data? {
        let deadline = timeoutMilliseconds.map { DispatchTime.now().uptimeNanoseconds + UInt64(max(1, $0)) * 1_000_000 }
        guard let lengthData = readExactly(fd, count: MemoryLayout<UInt32>.size, deadline: deadline) else {
            return nil
        }
        var bigEndianLength: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &bigEndianLength) { destination in
            lengthData.copyBytes(to: destination)
        }
        let length = Int(UInt32(bigEndian: bigEndianLength))
        guard length > 0, length <= maximumBytes else { return nil }
        return readExactly(fd, count: length, deadline: deadline)
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        // A client closing between admission and reply is ordinary transport
        // failure. It must never send SIGPIPE to the sole resident owner.
        var suppressSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
        var written = 0
        data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(
                    fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                written += count
            }
        }
        return written == data.count
    }

    private static func readExactly(_ fd: Int32, count: Int, deadline: UInt64?) -> Data? {
        var data = Data(count: count)
        var readCount = 0
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            while readCount < count {
                if let deadline {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { return false }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let wait = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
                    let ready = poll(&descriptor, 1, wait)
                    if ready < 0 && errno == EINTR { continue }
                    guard ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { return false }
                }
                let amount = read(
                    fd, raw.baseAddress!.advanced(by: readCount), count - readCount)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { return false }
                readCount += amount
            }
            return true
        }
        return complete ? data : nil
    }
}
