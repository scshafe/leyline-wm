import Foundation
import Darwin
import LeylineModel

enum ResidentEffectorJournalError: Error {
    case unavailable(operation: String, path: String, errno: Int32)
    case corrupt(path: String, line: Int)
}

/// @canonical resident_effector_journal -- newline records are fsync-durable before AX issue.
/// Recovery refuses truncated/corrupt evidence and never replays old mutations automatically.
final class ResidentEffectorFileJournal: ResidentEffectorJournal, @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    init(path: String) { self.path = path }

    func append(_ record: JSONValue) throws {
        lock.lock(); defer { lock.unlock() }
        let parent = try privateParent(create: false)
        defer { close(parent) }
        let fd = openat(parent, (path as NSString).lastPathComponent,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw ResidentEffectorJournalError.unavailable(operation: "open", path: path, errno: errno) }
        defer { close(fd) }
        try ResidentPrivateFiles.validateRegular(fd, path: path)
        let data = Data((record.canonical() + "\n").utf8)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ResidentEffectorJournalError.unavailable(operation: "write", path: path, errno: errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ResidentEffectorJournalError.unavailable(operation: "fsync", path: path, errno: errno) }
    }

    /// Caller owns an exclusive maintenance epoch and has received all writer
    /// ACKs. Preserve the complete prior journal; no old IO may append afterward.
    func quarantineAndReset(check: @Sendable () throws -> Void) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try check()
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let directory = try privateParent(create: true)
        defer { close(directory) }
        let old = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        let exists = old >= 0
        if exists {
            defer { close(old) }
            try ResidentPrivateFiles.validateRegular(old, path: path)
        } else if errno != ENOENT {
            throw ResidentEffectorJournalError.unavailable(operation: "quarantine_open", path: path, errno: errno)
        }
        let backupName = exists ? name + ".quarantined-" + UUID().uuidString : nil
        let backup = backupName.map { parentPath + "/" + $0 }
        try check()
        if let backupName {
            guard renameat(directory, name, directory, backupName) == 0 else {
                throw ResidentEffectorJournalError.unavailable(operation: "quarantine_rename", path: path, errno: errno)
            }
        }
        try check()
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ResidentEffectorJournalError.unavailable(operation: "reset_create", path: path, errno: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ResidentEffectorJournalError.unavailable(operation: "reset_fsync", path: path, errno: errno) }
        guard fsync(directory) == 0 else { throw ResidentEffectorJournalError.unavailable(operation: "reset_directory_fsync", path: parentPath, errno: errno) }
        return backup
    }

    func recover() throws -> (highWaterRevision: UInt64, records: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        let parent = try privateParent(create: false)
        defer { close(parent) }
        let descriptor = openat(parent, (path as NSString).lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return (0, []) }
        guard descriptor >= 0 else { throw ResidentEffectorJournalError.unavailable(operation: "read_open", path: path, errno: errno) }
        defer { close(descriptor) }
        try ResidentPrivateFiles.validateRegular(descriptor, path: path)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ResidentEffectorJournalError.unavailable(operation: "read", path: path, errno: errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.isEmpty || data.last == 10 else { throw ResidentEffectorJournalError.corrupt(path: path, line: 0) }
        var records: [JSONValue] = []
        var highWater: UInt64 = 0
        var intentions: [String: JSONValue] = [:]
        for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
            guard let value = try? JSONValue.parse(Data(line.utf8)),
                  let kind = value.at(path: "type")?.stringValue,
                  ["effect_intent", "effect_commit", "effect_abort", "model_state_intent", "model_state_commit", "model_state_abort"].contains(kind),
                  let revision = value.at(path: "revision")?.intValue, revision >= 0,
                  !((value.at(path: "request_id")?.stringValue ?? "").isEmpty),
                  kind != "effect_intent" || Frame.from(value.at(path: "frame")) != nil else {
                throw ResidentEffectorJournalError.corrupt(path: path, line: index + 1)
            }
            let requestID = value.at(path: "request_id")!.stringValue!
            if kind.hasSuffix("_intent") {
                intentions[requestID] = value
            } else {
                guard let intent = intentions[requestID], intent.at(path: "revision") == value.at(path: "revision") else {
                    throw ResidentEffectorJournalError.corrupt(path: path, line: index + 1)
                }
                if kind.hasSuffix("_commit"), intent.at(path: "state") != value.at(path: "state") {
                    // Old effect-only intentions carry no checkpoint; nil/null both mean absent.
                    let expected = intent.at(path: "state") ?? .null
                    let committed = value.at(path: "state") ?? .null
                    guard expected == committed else { throw ResidentEffectorJournalError.corrupt(path: path, line: index + 1) }
                }
                intentions.removeValue(forKey: requestID)
            }
            highWater = max(highWater, UInt64(revision)); records.append(value)
        }
        return (highWater, records)
    }

    private func privateParent(create: Bool) throws -> Int32 {
        try ResidentPrivateFiles.openDirectory(at: (path as NSString).deletingLastPathComponent, create: create)
    }

    /// Restores the last complete desired-state checkpoint, never reissues recorded effects.
    /// A journal with intents but no persisted state explicitly has no recoverable state authority.
    func recoverCheckpoint() throws -> (highWaterRevision: UInt64, state: JSONValue?, records: [JSONValue]) {
        let recovered = try recover()
        // Cancelled IO can finish a prior marker after a later state-only
        // transaction. Authority revision, rather than append order, wins.
        let committed = recovered.records.filter {
            $0.at(path: "type")?.stringValue?.hasSuffix("_commit") == true
                && $0.at(path: "state")?.objectValue != nil
        }.max { ($0.at(path: "revision")?.intValue ?? 0) < ($1.at(path: "revision")?.intValue ?? 0) }
        let state = committed?.at(path: "state")
        return (recovered.highWaterRevision, state, recovered.records)
    }
}
