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
    /// One global override; nil delegates to the canonical border configuration.
    let globalGutterWidth: Int?

    init(spacesEnabled: [String: Bool], desiredRunning: Bool, present: Bool,
         errorCode: String?, generation: UInt64, configuration: JSONValue? = nil,
         globalGutterWidth: Int? = nil) {
        self.spacesEnabled = spacesEnabled; self.desiredRunning = desiredRunning
        self.present = present; self.errorCode = errorCode; self.generation = generation
        self.configuration = configuration
        self.globalGutterWidth = globalGutterWidth
    }

    func enabled(spaceKey: String) -> Bool { spacesEnabled[spaceKey] ?? true }
}

/// @canonical resident_settings_store -- durable global and Space management
/// preferences. Absent is an explicit default; invalid/unreadable is a failure.
enum ResidentSettingsStore {
    static func defaultPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["LEYLINE_CONFIG_DIR"]
            ?? ((environment["LEYLINE_ROOT"] ?? (NSHomeDirectory() + "/.config/leyline")) + "/config")
        return config + "/leylined-settings.json"
    }

    static func read(path: String, generation: UInt64 = 0) -> ResidentSettingsSnapshot {
        var entry = stat()
        guard path.withCString({ lstat($0, &entry) }) == 0 else {
            let code = errno == ENOENT ? nil : "SETTINGS.STAT_FAILED"
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                                            present: false, errorCode: code, generation: generation)
        }
        guard let bytes = FileManager.default.contents(atPath: path) else {
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                                            present: true, errorCode: "SETTINGS.READ_FAILED", generation: generation)
        }
        guard let object = (try? JSONValue.parse(bytes))?.objectValue,
              object["schema"]?.stringValue == "leyline/resident-settings/v1",
              let spaces = object["spaces_enabled"]?.objectValue,
              let running = object["desired_running"]?.boolValue,
              spaces.allSatisfy({ !$0.key.isEmpty && $0.value.boolValue != nil }),
              object["global_gutter_width"] == nil
                || (object["global_gutter_width"]?.intValue.map { $0 >= 0 && $0 <= 512 } == true) else {
            return ResidentSettingsSnapshot(spacesEnabled: [:], desiredRunning: true,
                                            present: true, errorCode: "SETTINGS.INVALID", generation: generation)
        }
        let enabled = Dictionary(uniqueKeysWithValues: spaces.map { ($0.key, $0.value.boolValue!) })
        return ResidentSettingsSnapshot(spacesEnabled: enabled, desiredRunning: running,
                                        present: true, errorCode: nil, generation: generation,
                                        globalGutterWidth: object["global_gutter_width"]?.intValue.map(Int.init))
    }

    /// Updating management alone preserves the existing global override. A
    /// failed read refuses the update instead of replacing preferences.
    static func write(path: String, spacesEnabled: [String: Bool], desiredRunning: Bool) throws {
        let current = read(path: path)
        if let errorCode = current.errorCode {
            throw ResidentInputError(code: errorCode, message: "Cannot preserve the current resident settings for update")
        }
        try write(path: path, spacesEnabled: spacesEnabled, desiredRunning: desiredRunning,
                  globalGutterWidth: current.globalGutterWidth)
    }

    /// Writes the complete preference snapshot atomically; an explicit nil
    /// restores the registry preference. Filesystem work belongs off-main.
    static func write(path: String, spacesEnabled: [String: Bool], desiredRunning: Bool,
                      globalGutterWidth: Int?) throws {
        guard spacesEnabled.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ResidentInputError(code: "SETTINGS.SPACE_KEY_INVALID", message: "Cannot persist an empty Space identity")
        }
        guard globalGutterWidth.map({ (0...512).contains($0) }) ?? true else {
            throw ResidentInputError(code: "SETTINGS.GUTTER_WIDTH_INVALID", message: "Global gutter must be between 0 and 512 points")
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var value: JSONObject = ["schema": .string("leyline/resident-settings/v1"),
                                 "spaces_enabled": .object(JSONObject(unordered: spacesEnabled.mapValues(JSONValue.bool))),
                                 "desired_running": .bool(desiredRunning)]
        if let globalGutterWidth { value["global_gutter_width"] = .int(Int64(globalGutterWidth)) }
        try Data((JSONValue.object(value).canonical() + "\n").utf8).write(
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
             "generation": .int(Int64(generation)), "recurring_poll_count": .int(0),
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
           candidate.globalGutterWidth == previous.globalGutterWidth,
           candidate.configuration == previous.configuration,
           candidate.present == previous.present, candidate.errorCode == previous.errorCode { return }
        generation += 1
        lastSnapshot = candidate
        onSnapshot(candidate)
    }
}
