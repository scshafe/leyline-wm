// Directory vnode events cover both first creation and atomic replacement.
// Reconnect always reads one baseline; no timer/poll is part of this source.
import Darwin
import Foundation
import LeylineModel

struct ResidentSettingsSnapshot: Equatable, Sendable {
    let spacesEnabled: [String: Bool]
    let desiredRunning: Bool
    let present: Bool
    let errorCode: String?
    let generation: UInt64
    let configuration: JSONValue?

    init(spacesEnabled: [String: Bool], desiredRunning: Bool, present: Bool,
         errorCode: String?, generation: UInt64, configuration: JSONValue? = nil) {
        self.spacesEnabled = spacesEnabled; self.desiredRunning = desiredRunning
        self.present = present; self.errorCode = errorCode; self.generation = generation
        self.configuration = configuration
    }

    func enabled(spaceKey: String) -> Bool { spacesEnabled[spaceKey] ?? true }
}

/// @canonical resident_settings_store -- durable global and Space management
/// preferences. Absent is an explicit default; invalid/unreadable is a failure.
enum ResidentSettingsStore {
    static let schema = "leyline/resident-settings/v1"

    static func defaultPath() -> String {
        ResidentLayout.settings(config: ResidentPaths.config())
    }

    /// The canonical settings document, newline-terminated, as the resident writes
    /// it and the installer seeds it.
    static func document(spacesEnabled: [String: Bool], desiredRunning: Bool) -> Data {
        let value: JSONObject = ["schema": .string(schema),
                                 "spaces_enabled": .object(JSONObject(unordered: spacesEnabled.mapValues(JSONValue.bool))),
                                 "desired_running": .bool(desiredRunning)]
        return Data((JSONValue.object(value).canonical() + "\n").utf8)
    }

    /// Read a private JSON object file. Absent is `(present: false, nil, nil)`; a stat
    /// failure other than ENOENT, an unreadable, oversized, unparsable or non-object
    /// file reports the matching code with no object.
    static func loadObject(path: String, maximumBytes: Int? = nil,
                           codes: (stat: String, read: String, invalid: String))
        -> (present: Bool, object: JSONObject?, errorCode: String?) {
        var entry = stat()
        guard path.withCString({ lstat($0, &entry) }) == 0 else {
            return (false, nil, errno == ENOENT ? nil : codes.stat)
        }
        guard let bytes = FileManager.default.contents(atPath: path) else { return (true, nil, codes.read) }
        if let maximumBytes, bytes.count > maximumBytes { return (true, nil, codes.invalid) }
        guard let object = (try? JSONValue.parse(bytes))?.objectValue else { return (true, nil, codes.invalid) }
        return (true, object, nil)
    }

    static func read(path: String, generation: UInt64 = 0) -> ResidentSettingsSnapshot {
        let loaded = loadObject(path: path, codes: ("SETTINGS.STAT_FAILED", "SETTINGS.READ_FAILED", "SETTINGS.INVALID"))
        guard let object = loaded.object else {
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                                            present: loaded.present, errorCode: loaded.errorCode, generation: generation)
        }
        guard object["schema"]?.stringValue == schema,
              let spaces = object["spaces_enabled"]?.objectValue,
              let running = object["desired_running"]?.boolValue,
              spaces.allSatisfy({ !$0.key.isEmpty && $0.value.boolValue != nil }) else {
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                                            present: true, errorCode: "SETTINGS.INVALID", generation: generation)
        }
        let enabled = Dictionary(uniqueKeysWithValues: spaces.map { ($0.key, $0.value.boolValue!) })
        return ResidentSettingsSnapshot(spacesEnabled: enabled, desiredRunning: running,
                                        present: true, errorCode: nil, generation: generation)
    }

    /// Atomically persist management preferences. Invalid existing settings
    /// refuse the update rather than being replaced by fabricated defaults.
    static func write(path: String, spacesEnabled: [String: Bool], desiredRunning: Bool) throws {
        let current = read(path: path)
        if let errorCode = current.errorCode {
            throw ResidentInputError(code: errorCode, message: "Cannot preserve the current resident settings for update")
        }
        guard spacesEnabled.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ResidentInputError(code: "SETTINGS.SPACE_KEY_INVALID", message: "Cannot persist an empty Space identity")
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try document(spacesEnabled: spacesEnabled, desiredRunning: desiredRunning).write(
            to: URL(fileURLWithPath: path), options: .atomic)
        guard chmod(path, 0o600) == 0 else {
            throw ResidentInputError(code: "SETTINGS.PERMISSION_FAILED", message: "Failed to restrict resident settings permissions")
        }
    }
}

/// Directory watchers are an acceleration-independent source: a baseline read
/// after reconnect handles missed events; parent watches handle directory swaps.
final class SettingsEvents: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "leyline.resident.settings.events")
    private let onSnapshot: @Sendable (ResidentSettingsSnapshot) -> Void
    private let readSnapshot: @Sendable (String, UInt64) -> ResidentSettingsSnapshot
    private var watches: [String: DispatchSourceFileSystemObject] = [:]
    private var running = false
    private var generation: UInt64 = 0
    private var lastSnapshot: ResidentSettingsSnapshot?
    private var sourceErrorCode: String?

    init(path: String = ResidentSettingsStore.defaultPath(),
         readSnapshot: @escaping @Sendable (String, UInt64) -> ResidentSettingsSnapshot = {
             ResidentSettingsStore.read(path: $0, generation: $1)
         },
         onSnapshot: @escaping @Sendable (ResidentSettingsSnapshot) -> Void) {
        self.path = path
        self.onSnapshot = onSnapshot
        self.readSnapshot = readSnapshot
    }

    func start() {
        queue.sync {
            guard !running else { return }
            running = true
            rebuildWatches()
            baseline(force: true)
        }
    }

    func stop() {
        queue.sync {
            running = false
            for source in watches.values { source.cancel() }
            watches.removeAll()
        }
    }

    func health() -> JSONObject {
        queue.sync {
            ["running": .bool(running), "directory_watch_count": .int(Int64(watches.count)),
             "generation": .int(Int64(generation)),
             "error_code": sourceErrorCode.map(JSONValue.string)
                ?? lastSnapshot?.errorCode.map(JSONValue.string) ?? .null]
        }
    }

    /// Test seam drives the real event/rebaseline path, without timers or GUI.
    #if LEYLINE_BUILD_TESTS
    func rebaselineForSelfTest() { queue.sync { rebuildWatches(); baseline(force: true) } }
    #endif


    private func rebuildWatches() {
        guard running else { return }
        let parent = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).standardizedFileURL.path
        var candidate = parent
        while !FileManager.default.fileExists(atPath: candidate), candidate != "/" {
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        // Watch the existing directory and its parent. If config itself is
        // renamed/replaced, the parent event restores the path-bound watch.
        let wanted = Set([candidate, (candidate as NSString).deletingLastPathComponent])
        for key in watches.keys where !wanted.contains(key) { watches.removeValue(forKey: key)?.cancel() }
        sourceErrorCode = nil
        for directory in wanted where watches[directory] == nil {
            let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { sourceErrorCode = "SETTINGS.WATCH_OPEN_FAILED"; continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, self.running else { return }
                if let source, !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.watches.removeValue(forKey: directory)?.cancel()
                }
                self.rebuildWatches()
                self.baseline(force: false)
            }
            source.setCancelHandler { close(descriptor) }
            watches[directory] = source
            source.resume()
        }
    }

    private func baseline(force: Bool) {
        let candidate = readSnapshot(path, generation + 1)
        if !force, let previous = lastSnapshot,
           candidate.spacesEnabled == previous.spacesEnabled,
           candidate.desiredRunning == previous.desiredRunning,
           candidate.configuration == previous.configuration,
           candidate.present == previous.present, candidate.errorCode == previous.errorCode { return }
        generation += 1
        lastSnapshot = candidate
        onSnapshot(candidate)
    }
}
