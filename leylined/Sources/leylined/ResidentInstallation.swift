import Darwin
import Foundation
import LeylineModel

/// The operations the native installer accepts; main.swift dispatches on the same set.
let residentInstallationOperations = ["install", "uninstall", "service-status", "service-start", "service-stop", "service-restart"]

struct ResidentInstallationError: Error {
    let code: String
    let message: String
    var context: JSONObject = [:]
    var cause: JSONValue? = nil

    var json: JSONValue {
        .object(["code": .string(code), "message": .string(message),
                 "context": .object(context), "cause": cause ?? .null])
    }
}

struct ResidentInstallationCommand {
    let status: Int32
    let output: String
}

struct ResidentInstallationOptions {
    var operation: String
    var root: String
    var launchAgents: String
    var executable: String
    var resourceHome: String
    var plan = false
    var start = true
    var update = false

    var plistPath: String { launchAgents + "/" + ResidentInstallation.label + ".plist" }
    var service: String { "gui/\(geteuid())/" + ResidentInstallation.label }
    var directories: [String] {
        [root, ResidentLayout.config(root: root), ResidentLayout.runtime(root: root), ResidentLayout.sockets(root: root),
         root + "/state", ResidentLayout.state(root: root), launchAgents]
    }
    var plist: [String: Any] {
        ["Label": ResidentInstallation.label, "ProgramArguments": [executable, "core"],
         "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 1, "Umask": 0o077,
         "ProcessType": "Interactive", "EnvironmentVariables": [
            "LEYLINE_HOME": resourceHome, "LEYLINE_ROOT": root, "LEYLINE_RUNTIME_DIR": ResidentLayout.runtime(root: root)],
         "StandardOutPath": ResidentLayout.stdoutLog(root: root),
         "StandardErrorPath": ResidentLayout.stderrLog(root: root)]
    }
}

/// @canonical resident_installation -- the bundled application and CLI share
/// one per-user install/update/uninstall and launchd administration path.
enum ResidentInstallation {
    static let label = "org.leyline.leylined"
    static let launchctlTimeoutSeconds: Double = 10
    static let launchctlMaximumOutputBytes = 1_048_576
    static let plistKeys: Set<String> = ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive",
        "ThrottleInterval", "Umask", "ProcessType", "EnvironmentVariables", "StandardOutPath", "StandardErrorPath"]
    static let environmentKeys: Set<String> = ["LEYLINE_HOME", "LEYLINE_ROOT", "LEYLINE_RUNTIME_DIR"]
    typealias Executor = ([String]) throws -> ResidentInstallationCommand

    static func parse(_ arguments: [String]) throws -> ResidentInstallationOptions {
        let operations = residentInstallationOperations
        guard let operation = arguments.first, operations.contains(operation) else {
            throw failure("ARGUMENT_INVALID", "Expected install, uninstall or a service operation")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let ownExecutable = Bundle.main.executableURL else {
            throw failure("EXECUTABLE_UNAVAILABLE", "Cannot locate the current executable")
        }
        var options = ResidentInstallationOptions(operation: operation,
            root: ResidentPaths.root(environment),
            launchAgents: NSHomeDirectory() + "/Library/LaunchAgents",
            executable: ownExecutable.resolvingSymlinksInPath().path, resourceHome: ResidentResources.home())
        var seen = Set<String>()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw failure("ARGUMENT_INVALID", "Repeated option \(flag)") }
            switch flag {
            case "--root", "--launch-agents", "--executable", "--resource-home":
                guard index + 1 < arguments.count else { throw failure("ARGUMENT_INVALID", "Missing value for \(flag)") }
                let value = arguments[index + 1]
                switch flag {
                case "--root": options.root = value
                case "--launch-agents": options.launchAgents = value
                case "--executable": options.executable = value
                default: options.resourceHome = value
                }
                index += 2
            case "--plan": options.plan = true; index += 1
            case "--update": options.update = true; index += 1
            case "--start", "--no-start":
                guard !seen.contains(flag == "--start" ? "--no-start" : "--start") else {
                    throw failure("ARGUMENT_INVALID", "Choose either --start or --no-start")
                }
                options.start = flag == "--start"; index += 1
            default: throw failure("ARGUMENT_INVALID", "Unknown option \(flag)")
            }
        }
        if operation != "install", seen.contains("--start") || seen.contains("--no-start") || options.update {
            throw failure("ARGUMENT_INVALID", "--start, --no-start and --update apply only to install")
        }
        for path in [options.root, options.launchAgents, options.executable, options.resourceHome] {
            guard path.hasPrefix("/"), path != "/", !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  !path.hasSuffix("/") else {
                throw failure("PATH_INVALID", "Installation paths must be absolute, normalized paths", ["path": .string(path)])
            }
        }
        guard geteuid() != 0, getuid() == geteuid() else {
            throw failure("USER_REQUIRED", "Install Leyline as your logged-in user, without sudo")
        }
        // launchd prints normalized paths. Normalize syntax and the documented
        // system aliases without following any user-controlled symlink.
        func normalized(_ path: String) -> String {
            let result = "/" + path.split(separator: "/").joined(separator: "/")
            if result == "/tmp" || result.hasPrefix("/tmp/") || result == "/var" || result.hasPrefix("/var/") {
                return "/private" + result
            }
            return result
        }
        options.root = normalized(options.root)
        options.launchAgents = normalized(options.launchAgents)
        options.executable = normalized(options.executable)
        options.resourceHome = normalized(options.resourceHome)
        return options
    }

    /// Arguments never enter a shell. Nonblocking output and an owned-child
    /// wait enforce an administrative deadline without timer/PID-reuse races.
    static func launchctl(_ arguments: [String]) throws -> ResidentInstallationCommand {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot create launchctl output pipe", ["errno": .int(Int64(errno))]) }
        defer { close(descriptors[0]) }
        var writeOpen = true
        defer { if writeOpen { close(descriptors[1]) } }
        // Finder may launch with standard descriptors closed. Keep pipe ends
        // above stderr so file-action dup/close operations cannot alias them.
        for index in descriptors.indices {
            let relocated = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
            guard relocated >= 0 else { throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot isolate launchctl output descriptors", ["errno": .int(Int64(errno))]) }
            close(descriptors[index]); descriptors[index] = relocated
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot configure launchctl output pipe", ["errno": .int(Int64(errno))])
        }
        var actions: posix_spawn_file_actions_t?
        let initialized = posix_spawn_file_actions_init(&actions)
        guard initialized == 0 else { throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot initialize launchctl file actions", ["errno": .int(Int64(initialized))]) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for code in [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO),
                     posix_spawn_file_actions_addclose(&actions, descriptors[0]),
                     posix_spawn_file_actions_addclose(&actions, descriptors[1])] {
            guard code == 0 else { throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot configure launchctl file actions", ["errno": .int(Int64(code))]) }
        }
        var argv = (["/bin/launchctl"] + arguments).map { strdup($0) }
        guard argv.allSatisfy({ $0 != nil }) else {
            for value in argv { free(value) }
            throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot allocate launchctl arguments")
        }
        argv.append(nil)
        defer { for value in argv { free(value) } }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, "/bin/launchctl", &actions, nil, &argv, environ)
        guard spawned == 0 else { throw failure("LAUNCHCTL_SPAWN_FAILED", "Cannot execute launchctl", ["errno": .int(Int64(spawned))]) }
        close(descriptors[1]); writeOpen = false
        var reaped = false
        var status: Int32 = 0
        defer {
            if !reaped {
                // The child cannot have its PID reused until this wait reaps it.
                _ = kill(child, SIGKILL)
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + launchctlTimeoutSeconds
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var endOfOutput = false
        while !reaped || !endOfOutput {
            while !endOfOutput {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { break }
                guard count >= 0 else { throw failure("LAUNCHCTL_READ_FAILED", "Cannot read launchctl output", ["errno": .int(Int64(errno))]) }
                if count == 0 { endOfOutput = true; break }
                guard bytes.count + count <= launchctlMaximumOutputBytes else {
                    throw failure("LAUNCHCTL_OUTPUT_TOO_LARGE", "launchctl output exceeded the administrative limit")
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            if !reaped {
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child { reaped = true }
                else if waited < 0, errno != EINTR {
                    if errno == ECHILD { reaped = true }
                    throw failure("LAUNCHCTL_WAIT_FAILED", "Cannot verify launchctl child exit", ["errno": .int(Int64(errno))])
                }
            }
            if reaped && endOfOutput { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw failure("LAUNCHCTL_TIMEOUT", "launchctl exceeded its ten-second administrative deadline", ["arguments": .array(arguments.map(JSONValue.string))])
            }
            if endOfOutput { usleep(20_000) }
            else {
                var event = pollfd(fd: descriptors[0], events: Int16(POLLIN | POLLHUP), revents: 0)
                let polled = poll(&event, 1, 20)
                guard polled >= 0 || errno == EINTR else { throw failure("LAUNCHCTL_WAIT_FAILED", "Cannot wait for launchctl output", ["errno": .int(Int64(errno))]) }
            }
        }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ResidentInstallationCommand(status: exitCode, output: String(decoding: bytes, as: UTF8.self))
    }

    static func perform(_ options: ResidentInstallationOptions, execute: Executor = launchctl) throws -> JSONObject {
        // All preflight inspections are read-only; in particular a conflicting
        // registered job never causes its plist to be replaced first.
        for directory in options.directories { try inspectDirectory(directory) }
        let priorBytes = try readPrivateFile(options.plistPath)
        let priorPlist = try priorBytes.map { try decodePlist($0, path: options.plistPath) }
        var data: JSONObject = ["operation": .string(options.operation), "label": .string(label),
            "service": .string(options.service), "plist_path": .string(options.plistPath),
            "root": .string(options.root), "applied": .bool(false), "plan": .bool(options.plan),
            "registered": .null, "user_data_preserved": .bool(true)]
        if options.operation == "install" {
            let defaults = try resourceDefaults(options)
            try inspectConfiguration(options)
            data["plist"] = try json(options.plist)
            data["configuration_defaults"] = .object(defaults)
        }
        if options.plan {
            data["registration_checked"] = .bool(false)
            data["launchctl_commands"] = .array(plannedCommands(options).map { .array($0.map(JSONValue.string)) })
            return data
        }

        let registration = try registered(options.service, execute: execute)
        data["registration_checked"] = .bool(true)
        data["registered"] = .bool(registration != nil)
        if options.operation == "service-status" {
            data["plist_present"] = .bool(priorBytes != nil)
            data["identity_matches_plist"] = .bool(registration.map { report in
                priorPlist.map { jobMatches(report, plist: $0, path: options.plistPath) } ?? false
            } ?? false)
            data["launchd"] = registration.map(JSONValue.string) ?? .null
            return data
        }

        if options.operation == "service-stop" || options.operation == "uninstall" {
            if let registration {
                guard let priorPlist, ownedPlist(priorPlist, root: options.root),
                      jobMatches(registration, plist: priorPlist, path: options.plistPath) else {
                    throw failure("REGISTRATION_CONFLICT", "The registered job does not match the owned Leyline plist; it was left running")
                }
                try stop(options, execute: execute)
            }
            if options.operation == "uninstall", priorBytes != nil {
                guard let priorPlist, ownedPlist(priorPlist, root: options.root) else {
                    throw failure("PLIST_INVALID", "The canonical plist is not an owned Leyline job; it was preserved")
                }
                try removePrivateFile(options.plistPath)
            }
            data["applied"] = .bool(registration != nil || (options.operation == "uninstall" && priorBytes != nil))
            data["registered"] = .bool(false)
            return data
        }

        if options.operation == "service-start" || options.operation == "service-restart" {
            guard let priorPlist, ownedPlist(priorPlist, root: options.root) else {
                throw failure("NOT_INSTALLED", "Install Leyline before starting its service")
            }
            try validateJobFiles(priorPlist)
            if let registration {
                guard jobMatches(registration, plist: priorPlist, path: options.plistPath) else {
                    throw failure("REGISTRATION_CONFLICT", "The registered job differs from its plist; run install --update to replace it")
                }
                if options.operation == "service-restart" || !jobRunning(registration) {
                    let arguments = options.operation == "service-restart" ? ["kickstart", "-k", options.service] : ["kickstart", options.service]
                    try requireSuccess(arguments, execute: execute)
                    data["applied"] = .bool(true)
                }
            } else {
                try requireSuccess(["bootstrap", "gui/\(geteuid())", options.plistPath], execute: execute)
                data["applied"] = .bool(true)
            }
            try verifyRegistration(options, plist: priorPlist, execute: execute)
            data["registered"] = .bool(true)
            return data
        }

        let wanted = options.plist
        let diskMatches = priorPlist.map { NSDictionary(dictionary: $0).isEqual(to: wanted) } ?? false
        let registrationMatches = registration.map { jobMatches($0, plist: wanted, path: options.plistPath) } ?? false
        if let priorPlist, !ownedPlist(priorPlist, root: nil) {
            throw failure("PLIST_INVALID", "The existing canonical plist is not an owned Leyline job; it was preserved")
        }
        if priorPlist != nil, !diskMatches, !options.update {
            throw failure("UPDATE_REQUIRED", "A different Leyline plist already exists; use install --update to replace it")
        }
        if registration != nil, !registrationMatches {
            guard options.update, options.start else {
                throw failure("UPDATE_REQUIRED", "A different Leyline job is registered; use install --update --start to replace it")
            }
            guard let priorPlist, ownedPlist(priorPlist, root: nil),
                  jobMatches(registration!, plist: priorPlist, path: options.plistPath) else {
                throw failure("ROLLBACK_UNAVAILABLE", "The current registration cannot be restored from the owned plist; update was refused")
            }
        }
        for directory in options.directories { try createPrivateDirectory(directory) }
        let configurationCreated = try createConfiguration(options)
        let bytes = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
        var serviceChanged = false
        do {
            if registration != nil, !registrationMatches { try stop(options, execute: execute) }
            if !diskMatches { try writePrivateFile(options.plistPath, bytes: bytes) }
            if options.start {
                if registrationMatches {
                    if !jobRunning(registration!) {
                        try requireSuccess(["kickstart", options.service], execute: execute)
                        serviceChanged = true
                    }
                }
                else { try requireSuccess(["bootstrap", "gui/\(geteuid())", options.plistPath], execute: execute) }
                try verifyRegistration(options, plist: wanted, execute: execute)
                if !registrationMatches { serviceChanged = true }
                data["registered"] = .bool(true)
            }
        } catch {
            if !diskMatches || (registration != nil && !registrationMatches) {
                let rollback = rollback(options, priorBytes: priorBytes, priorPlist: priorPlist,
                    wasRegistered: registration != nil, wanted: wanted, execute: execute)
                throw ResidentInstallationError(code: "INSTALL.BOOTSTRAP_FAILED", message: "Leyline did not start; installation rollback was attempted",
                    context: ["rollback_succeeded": .bool(rollback == nil), "rollback_error": rollback ?? .null], cause: errorJSON(error))
            }
            throw error
        }
        data["applied"] = .bool(!diskMatches || configurationCreated || serviceChanged)
        data["configuration_defaults"] = nil
        return data
    }

    private static func rollback(_ options: ResidentInstallationOptions, priorBytes: Data?, priorPlist: [String: Any]?,
                                 wasRegistered: Bool, wanted: [String: Any], execute: Executor) -> JSONValue? {
        do {
            if let report = try registered(options.service, execute: execute) {
                guard jobMatches(report, plist: wanted, path: options.plistPath) else {
                    throw failure("ROLLBACK_CONFLICT", "Rollback found an unexpected registered job; it was left running")
                }
                try stop(options, execute: execute)
            }
            if let priorBytes { try writePrivateFile(options.plistPath, bytes: priorBytes) }
            else { try removePrivateFile(options.plistPath) }
            if wasRegistered {
                guard let priorPlist else { throw failure("ROLLBACK_UNAVAILABLE", "The previous registered job has no saved plist") }
                try requireSuccess(["bootstrap", "gui/\(geteuid())", options.plistPath], execute: execute)
                try verifyRegistration(options, plist: priorPlist, execute: execute)
            }
            return nil
        } catch { return errorJSON(error) }
    }

    private static func registered(_ service: String, execute: Executor) throws -> String? {
        let result = try execute(["print", service])
        if result.status == 113 { return nil }
        guard result.status == 0 else { throw commandError(["print", service], result) }
        return result.output
    }

    private static func requireSuccess(_ arguments: [String], execute: Executor) throws {
        let result = try execute(arguments)
        guard result.status == 0 else { throw commandError(arguments, result) }
    }

    private static func stop(_ options: ResidentInstallationOptions, execute: Executor) throws {
        let result = try execute(["bootout", options.service])
        // A launchctl error is not proof of deregistration. Inspect until down,
        // with a bounded administrative deadline independent of resident timers.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if try registered(options.service, execute: execute) == nil { return }
            usleep(50_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw failure("STOP_NOT_VERIFIED", "The Leyline job remains registered after bootout",
            ["launchctl_status": .int(Int64(result.status)), "launchctl_output": .string(result.output)])
    }

    private static func verifyRegistration(_ options: ResidentInstallationOptions, plist: [String: Any], execute: Executor) throws {
        guard let report = try registered(options.service, execute: execute), jobMatches(report, plist: plist, path: options.plistPath) else {
            throw failure("REGISTRATION_NOT_VERIFIED", "launchd did not register the expected direct Leyline job")
        }
    }

    private static func jobMatches(_ report: String, plist: [String: Any], path: String) -> Bool {
        let lines = report.components(separatedBy: .newlines)
        func field(_ name: String) -> String? {
            let prefix = "\t" + name + " = "
            return lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        func block(_ name: String) -> [String] {
            guard let index = lines.firstIndex(of: "\t" + name + " = {") else { return [] }
            return Array(lines.dropFirst(index + 1).prefix(while: { $0 != "\t}" }))
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let arguments = plist["ProgramArguments"] as? [String], arguments.count == 2,
              let environment = plist["EnvironmentVariables"] as? [String: String],
              field("path") == path, field("program") == arguments.first,
              block("arguments") == arguments, field("minimum runtime") == "1",
              field("properties")?.components(separatedBy: " | ").contains("keepalive") == true,
              field("properties")?.components(separatedBy: " | ").contains("runatload") == true else { return false }
        let environmentLines = block("environment")
        return environment.allSatisfy { key, value in environmentLines.contains(key + " => " + value) }
    }

    private static func jobRunning(_ report: String) -> Bool {
        report.components(separatedBy: .newlines).contains("\tstate = running")
            && report.components(separatedBy: .newlines).contains { line in
                line.hasPrefix("\tpid = ") && Int32(line.dropFirst("\tpid = ".count)).map { $0 > 0 } == true
            }
    }

    static func ownedPlist(_ plist: [String: Any], root: String?) -> Bool {
        // Program/BundleProgram and unrecognized launchd capabilities can
        // override argv or create additional services. Refuse them before boot.
        guard Set(plist.keys) == plistKeys, plist["Label"] as? String == label,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.count == 2, arguments[0].hasPrefix("/"), arguments[1] == "core",
              let environment = plist["EnvironmentVariables"] as? [String: String],
              Set(environment.keys) == environmentKeys,
              let installedRoot = environment["LEYLINE_ROOT"], installedRoot.hasPrefix("/"),
              root == nil || installedRoot == root,
              environment["LEYLINE_RUNTIME_DIR"] == ResidentLayout.runtime(root: installedRoot),
              environment["LEYLINE_HOME"]?.hasPrefix("/") == true,
              plist["StandardOutPath"] as? String == ResidentLayout.stdoutLog(root: installedRoot),
              plist["StandardErrorPath"] as? String == ResidentLayout.stderrLog(root: installedRoot),
              plist["ProcessType"] as? String == "Interactive", plist["Umask"] as? Int == 0o077,
              plist["KeepAlive"] as? Bool == true, plist["RunAtLoad"] as? Bool == true,
              plist["ThrottleInterval"] as? Int == 1 else { return false }
        return true
    }

    private static func resourceDefaults(_ options: ResidentInstallationOptions) throws -> JSONObject {
        try validateImmutableFile(options.executable, executable: true)
        for name in ResidentLayout.keymapFiles {
            let path = ResidentLayout.keymap(name, home: options.resourceHome)
            let bytes = try readImmutableFile(path)
            guard (try? JSONValue.parse(bytes))?.objectValue != nil else { throw failure("RESOURCES_INVALID", "Packaged keymap is invalid", ["path": .string(path)]) }
        }
        let version = String(decoding: try readImmutableFile(options.resourceHome + "/VERSION"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == ResidentVersion.current else { throw failure("VERSION_MISMATCH", "Packaged resources and executable have different versions") }
        return BorderPalette.configurationDefaults
    }

    private static func validateJobFiles(_ plist: [String: Any]) throws {
        guard let arguments = plist["ProgramArguments"] as? [String], let executable = arguments.first,
              let environment = plist["EnvironmentVariables"] as? [String: String], let home = environment["LEYLINE_HOME"] else {
            throw failure("PLIST_INVALID", "Installed Leyline job has no executable or resource home")
        }
        try validateImmutableFile(executable, executable: true)
        for path in [home + "/VERSION"] + ResidentLayout.keymapFiles.map({ ResidentLayout.keymap($0, home: home) }) {
            try validateImmutableFile(path)
        }
    }

    private static func inspectConfiguration(_ options: ResidentInstallationOptions) throws {
        let config = ResidentLayout.config(root: options.root)
        for path in [ResidentLayout.borders(config: config), ResidentLayout.settings(config: config)] {
            if let bytes = try readPrivateFile(path), (try? JSONValue.parse(bytes))?.objectValue == nil {
                throw failure("CONFIGURATION_INVALID", "Existing configuration is invalid and was preserved", ["path": .string(path)])
            }
        }
        for path in [ResidentLayout.stdoutLog(root: options.root), ResidentLayout.stderrLog(root: options.root),
                     ResidentLayout.journal(root: options.root)] {
            try inspectPrivateFile(path)
        }
    }

    private static func createConfiguration(_ options: ResidentInstallationOptions) throws -> Bool {
        let defaults = try resourceDefaults(options), config = ResidentLayout.config(root: options.root)
        var created = false
        for (path, bytes) in [(ResidentLayout.borders(config: config), Data((JSONValue.object(defaults).canonical() + "\n").utf8)),
                              (ResidentLayout.settings(config: config), ResidentSettingsStore.document(spacesEnabled: [:], desiredRunning: true)),
                              (ResidentLayout.stdoutLog(root: options.root), Data()), (ResidentLayout.stderrLog(root: options.root), Data())] {
            if try privateFileDescriptor(path).map({ descriptor in close(descriptor); return true }) != true {
                try writePrivateFile(path, bytes: bytes)
                created = true
            }
        }
        return created
    }

    private static func inspectDirectory(_ path: String) throws {
        var candidate = path
        while true {
            do {
                let descriptor = try ResidentPrivateFiles.openDirectory(at: candidate, create: false,
                    privateMode: false, allowSystemTerminal: candidate != path)
                close(descriptor)
                return
            } catch let error as ResidentPrivateFileError where error.errorNumber == ENOENT {
                candidate = (candidate as NSString).deletingLastPathComponent
                guard candidate != "/" else { throw failure("PATH_UNSAFE", "Installation requires an owned directory ancestor", ["path": .string(path)]) }
            }
        }
    }

    static func createPrivateDirectory(_ path: String) throws {
        let descriptor = try ResidentPrivateFiles.openDirectory(at: path, create: true, repairPermissions: true)
        close(descriptor)
    }

    private static func privateFileDescriptor(_ path: String) throws -> Int32? {
        let parent = (path as NSString).deletingLastPathComponent
        let directory: Int32
        do { directory = try ResidentPrivateFiles.openDirectory(at: parent, create: false, privateMode: false) }
        catch let error as ResidentPrivateFileError where error.errorNumber == ENOENT { return nil }
        defer { close(directory) }
        let descriptor = openat(directory, (path as NSString).lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw failure("FILE_UNSAFE", "Cannot safely inspect the installation file", ["path": .string(path), "errno": .int(Int64(errno))]) }
        do { try ResidentPrivateFiles.validateRegular(descriptor, path: path) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private static func inspectPrivateFile(_ path: String) throws {
        if let descriptor = try privateFileDescriptor(path) { close(descriptor) }
    }

    static func readPrivateFile(_ path: String) throws -> Data? {
        guard let descriptor = try privateFileDescriptor(path) else { return nil }
        defer { close(descriptor) }
        return try readBytes(descriptor, path: path)
    }

    private static func readImmutableFile(_ path: String) throws -> Data {
        let descriptor = try immutableFileDescriptor(path)
        defer { close(descriptor) }
        return try readBytes(descriptor, path: path)
    }

    private static func validateImmutableFile(_ path: String, executable: Bool = false) throws {
        let descriptor = try immutableFileDescriptor(path, executable: executable)
        close(descriptor)
    }

    private static func immutableFileDescriptor(_ path: String, executable: Bool = false) throws -> Int32 {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = try ResidentPrivateFiles.openDirectory(at: parent, create: false, privateMode: false, allowSystemTerminal: true)
        defer { close(directory) }
        let descriptor = openat(directory, (path as NSString).lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure("RESOURCES_UNAVAILABLE", "Required executable or resource cannot be opened", ["path": .string(path), "errno": .int(Int64(errno))]) }
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, (facts.st_mode & S_IFMT) == S_IFREG,
              facts.st_uid == geteuid() || facts.st_uid == 0, (facts.st_mode & 0o022) == 0,
              !executable || (facts.st_mode & 0o111) != 0 else {
            close(descriptor)
            throw failure("RESOURCES_UNSAFE", "Required executable or resource has unsafe ownership, type or permissions", ["path": .string(path)])
        }
        return descriptor
    }

    private static func readBytes(_ descriptor: Int32, path: String) throws -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("FILE_READ_FAILED", "Cannot read the installation file", ["path": .string(path), "errno": .int(Int64(errno))]) }
            if count == 0 { return bytes }
            guard bytes.count + count <= 4_194_304 else { throw failure("FILE_TOO_LARGE", "Installation metadata exceeds 4 MiB", ["path": .string(path)]) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writePrivateFile(_ path: String, bytes: Data) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = try ResidentPrivateFiles.openDirectory(at: parent, create: false)
        defer { close(directory) }
        let target = (path as NSString).lastPathComponent
        let staged = ".leyline-install-" + UUID().uuidString
        let descriptor = openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure("STAGE_FAILED", "Cannot stage the installation file", ["path": .string(path), "errno": .int(Int64(errno))]) }
        defer { close(descriptor); _ = unlinkat(directory, staged, 0) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("STAGE_FAILED", "Cannot write the staged installation file", ["path": .string(path), "errno": .int(Int64(errno))]) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure("STAGE_FAILED", "Cannot sync the staged installation file", ["path": .string(path), "errno": .int(Int64(errno))]) }
        // Recheck an existing target through the same anchored directory before
        // replacement. A symlink or shared/non-private file is never overwritten.
        let current = openat(directory, target, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if current >= 0 {
            defer { close(current) }
            try ResidentPrivateFiles.validateRegular(current, path: path)
        } else if errno != ENOENT { throw failure("FILE_UNSAFE", "The installation target became unsafe", ["path": .string(path), "errno": .int(Int64(errno))]) }
        guard renameat(directory, staged, directory, target) == 0, fsync(directory) == 0 else {
            throw failure("REPLACE_FAILED", "Cannot atomically replace the installation file", ["path": .string(path), "errno": .int(Int64(errno))])
        }
    }

    private static func removePrivateFile(_ path: String) throws {
        let directory = try ResidentPrivateFiles.openDirectory(at: (path as NSString).deletingLastPathComponent, create: false, privateMode: false)
        defer { close(directory) }
        let target = (path as NSString).lastPathComponent
        let descriptor = openat(directory, target, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw failure("FILE_UNSAFE", "Cannot safely remove the owned plist", ["path": .string(path)]) }
        defer { close(descriptor) }
        try ResidentPrivateFiles.validateRegular(descriptor, path: path)
        guard unlinkat(directory, target, 0) == 0, fsync(directory) == 0 else { throw failure("REMOVE_FAILED", "Cannot remove the owned plist", ["path": .string(path), "errno": .int(Int64(errno))]) }
    }

    private static func decodePlist(_ bytes: Data, path: String) throws -> [String: Any] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)) as? [String: Any] else {
            throw failure("PLIST_INVALID", "Existing launchagent plist is invalid and was preserved", ["path": .string(path)])
        }
        return plist
    }

    private static func plannedCommands(_ options: ResidentInstallationOptions) -> [[String]] {
        switch options.operation {
        case "install": return options.start ? [["print", options.service], ["bootstrap", "gui/\(geteuid())", options.plistPath]] : [["print", options.service]]
        case "uninstall", "service-stop": return [["print", options.service], ["bootout", options.service], ["print", options.service]]
        case "service-start": return [["print", options.service], ["bootstrap", "gui/\(geteuid())", options.plistPath]]
        case "service-restart": return [["print", options.service], ["kickstart", "-k", options.service]]
        default: return [["print", options.service]]
        }
    }

    private static func commandError(_ arguments: [String], _ result: ResidentInstallationCommand) -> ResidentInstallationError {
        failure("LAUNCHCTL_FAILED", "launchctl did not complete the installation operation", [
            "arguments": .array(arguments.map(JSONValue.string)), "launchctl_status": .int(Int64(result.status)),
            "launchctl_output": .string(result.output)])
    }

    static func failure(_ code: String, _ message: String, _ context: JSONObject = [:], cause: Error? = nil) -> ResidentInstallationError {
        .init(code: "INSTALL." + code, message: message, context: context, cause: cause.map(errorJSON))
    }

    static func errorJSON(_ error: Error) -> JSONValue {
        if let error = error as? ResidentInstallationError { return error.json }
        if let error = error as? ResidentPrivateFileError {
            return failure("PATH_UNSAFE", "Installation path ownership, permissions or type is unsafe", [
                "operation": .string(error.operation), "path": .string(error.path), "errno": .int(Int64(error.errorNumber))]).json
        }
        return .object(["code": .string("INSTALL.EXTERNAL_FAILURE"), "message": .string(String(describing: error)), "context": .object([:]), "cause": .null])
    }

    private static func json(_ value: [String: Any]) throws -> JSONValue {
        try JSONValue.parse(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}

/// Run the native per-user installer/service CLI. Arguments begin with one of
/// six operations; path options require absolute paths. Every result is a typed
/// JSON data/error/meta envelope. --plan performs no writes or launchctl calls.
/// Returns0 on success,64 for invalid arguments and65 for a refused/failed
/// installation. Settings and journals are preserved, including on uninstall.
func runResidentInstallation(_ arguments: [String]) -> Int32 {
    let requestID = UUID().uuidString
    var data: JSONValue = .null
    var errorValue: JSONValue = .null
    var exitCode: Int32 = 0
    do {
        let options = try ResidentInstallation.parse(arguments)
        data = .object(try ResidentInstallation.perform(options))
    } catch {
        errorValue = ResidentInstallation.errorJSON(error)
        exitCode = errorValue.at(path: "code")?.stringValue == "INSTALL.ARGUMENT_INVALID" ? ResidentExitCode.usage : ResidentExitCode.refused
    }
    print(ResidentReply.cliEnvelope(data: data, error: errorValue, meta: [
        "owner": .string("leylined"), "transport": .string("native_installation"),
        "version": .string(ResidentVersion.current), "request_id": .string(requestID),
        "completed": .bool(exitCode == 0)]).canonical())
    return exitCode
}
