// self-test installation — fake launchctl registration, rollback and
// filesystem safety; no real launchctl command, resident socket, event tap or
// Accessibility call is used. Moved verbatim from ResidentInstallation.swift.
import Foundation

extension ResidentInstallation {
    static func selfTest() -> Int32 {
        var tests = SelfTest()
        let base = NSTemporaryDirectory() + "/leyline-installation-" + UUID().uuidString
        do {
            try createPrivateDirectory(base)
            defer {
                do { try FileManager.default.removeItem(atPath: base) }
                catch { tests.check(false, "installation/temporary-fixture-cleanup") }
            }
            func options(_ name: String, start: Bool = false) throws -> ResidentInstallationOptions {
                var result = try parse(["install", "--root", base + "/" + name + "/state",
                    "--launch-agents", base + "/" + name + "/agents", "--resource-home", ResidentResources.home()])
                result.start = start
                return result
            }
            func report(_ options: ResidentInstallationOptions, plist: [String: Any]? = nil, running: Bool = true) -> String {
                let value = plist ?? options.plist
                let arguments = value["ProgramArguments"] as! [String]
                let environment = value["EnvironmentVariables"] as! [String: String]
                return options.service + " = {\n\tpath = " + options.plistPath
                    + "\n\tprogram = " + arguments[0] + "\n\targuments = {\n"
                    + arguments.map { "\t\t" + $0 }.joined(separator: "\n")
                    + "\n\t}\n\tenvironment = {\n"
                    + environment.sorted(by: { $0.key < $1.key }).map { "\t\t" + $0.key + " => " + $0.value }.joined(separator: "\n")
                    + "\n\t}\n\tminimum runtime = 1\n\tproperties = keepalive | runatload | inferred program\n"
                    + (running ? "\tstate = running\n\tpid = 123\n" : "\tstate = waiting\n") + "}\n"
            }
            func absent(_ arguments: [String]) throws -> ResidentInstallationCommand {
                guard arguments.first == "print" else { throw failure("TEST_MUTATION", "No-start fixture attempted a live operation") }
                return ResidentInstallationCommand(status: 113, output: "not registered")
            }
            func refused(_ name: String, code: String, operation: () throws -> Void) {
                do { try operation(); tests.check(false, "installation/" + name) }
                catch { tests.check(errorJSON(error).at(path: "code")?.stringValue == "INSTALL." + code, "installation/" + name) }
            }

            var dry = try options("plan")
            dry.plan = true
            var calls: [[String]] = []
            let dryResult = try perform(dry, execute: { arguments in calls.append(arguments); return try absent(arguments) })
            tests.check(calls.isEmpty && dryResult["registration_checked"] == .bool(false)
                && !FileManager.default.fileExists(atPath: dry.root), "installation/plan-has-zero-writes-and-zero-launchctl-calls")

            let staged = try options("staged")
            calls = []
            let first = try perform(staged, execute: { arguments in calls.append(arguments); return try absent(arguments) })
            tests.check(calls == [["print", staged.service]] && first["registered"] == .bool(false), "installation/no-start-only-inspects-registration")
            tests.check(staged.directories.allSatisfy { path in
                var facts = stat(); return lstat(path, &facts) == 0 && (facts.st_mode & 0o777) == 0o700
            }, "installation/all-install-owned-directories-are-private")
            let original = try readPrivateFile(staged.plistPath)!
            let second = try perform(staged, execute: absent)
            let repeatedPlist = try readPrivateFile(staged.plistPath)
            tests.check(second["applied"] == .bool(false) && repeatedPlist == original,
                "installation/repeated-no-start-install-is-idempotent")
            tests.check(ownedPlist(staged.plist, root: staged.root) && staged.plist["Umask"] as? Int == 0o077,
                "installation/exactly-one-direct-job-with-private-umask-and-one-second-throttle")
            for name in ["Program", "BundleProgram", "MachServices"] {
                var overridden = staged.plist
                overridden[name] = "/bin/false"
                tests.check(!ownedPlist(overridden, root: staged.root), "installation/forbids-launchd-capability-override-" + name)
            }
            var injected = staged.plist
            var injectedEnvironment = injected["EnvironmentVariables"] as! [String: String]
            injectedEnvironment["DYLD_INSERT_LIBRARIES"] = "/private/untrusted.dylib"
            injected["EnvironmentVariables"] = injectedEnvironment
            tests.check(!ownedPlist(injected, root: staged.root), "installation/forbids-unrecognized-job-environment")
            let malformed = try PropertyListSerialization.data(fromPropertyList: injected, format: .xml, options: 0)
            try writePrivateFile(staged.plistPath, bytes: malformed)
            var unsafeStart = staged; unsafeStart.operation = "service-start"
            refused("start-refuses-noncanonical-job-before-bootstrap", code: "NOT_INSTALLED") {
                _ = try perform(unsafeStart, execute: absent)
            }
            try writePrivateFile(staged.plistPath, bytes: original)

            let settingsPath = ResidentLayout.settings(config: ResidentLayout.config(root: staged.root))
            let settings = Data("{\"schema\":\"leyline/resident-settings/v1\",\"spaces_enabled\":{\"desktop\":false},\"desired_running\":false}\n".utf8)
            let borderPath = ResidentLayout.borders(config: ResidentLayout.config(root: staged.root))
            let border = Data("{\"border_radius\":17,\"colors.focus\":\"0xff00ff00\"}\n".utf8)
            let journalPath = ResidentLayout.journal(root: staged.root)
            let journal = Data("existing journal evidence\n".utf8)
            try writePrivateFile(settingsPath, bytes: settings)
            try writePrivateFile(borderPath, bytes: border)
            try writePrivateFile(journalPath, bytes: journal)
            _ = try perform(staged, execute: absent)
            let preservedSettings = try readPrivateFile(settingsPath)
            let preservedBorder = try readPrivateFile(borderPath)
            let preservedJournal = try readPrivateFile(journalPath)
            tests.check(preservedSettings == settings && preservedBorder == border && preservedJournal == journal,
                "installation/settings-borders-and-journals-are-preserved")

            var same = staged; same.start = true
            calls = []
            let sameResult = try perform(same, execute: { arguments in
                calls.append(arguments)
                return ResidentInstallationCommand(status: 0, output: report(same))
            })
            tests.check(sameResult["applied"] == .bool(false) && calls.allSatisfy { $0.first == "print" },
                "installation/opening-an-already-running-identical-job-does-not-restart-it")

            let conflict = try options("conflict", start: true)
            refused("different-registration-is-refused-before-writing", code: "UPDATE_REQUIRED") {
                _ = try perform(conflict, execute: { _ in ResidentInstallationCommand(status: 0, output: "unrecognized registered job") })
            }
            tests.check(!FileManager.default.fileExists(atPath: conflict.root), "installation/refused-registration-does-not-create-root")
            refused("inspection-error-is-not-absence", code: "LAUNCHCTL_FAILED") {
                _ = try perform(conflict, execute: { _ in ResidentInstallationCommand(status: 5, output: "domain unavailable") })
            }

            var replacement = staged.plist
            var replacementEnvironment = replacement["EnvironmentVariables"] as! [String: String]
            replacementEnvironment["LEYLINE_HOME"] = staged.resourceHome + "/previous"
            replacement["EnvironmentVariables"] = replacementEnvironment
            let prior = try PropertyListSerialization.data(fromPropertyList: replacement, format: .xml, options: 0)
            try writePrivateFile(staged.plistPath, bytes: prior)
            refused("different-disk-plist-needs-explicit-update", code: "UPDATE_REQUIRED") { _ = try perform(staged, execute: absent) }
            let refusedPlist = try readPrivateFile(staged.plistPath)
            tests.check(refusedPlist == prior, "installation/refused-update-preserves-existing-plist")

            var update = same; update.update = true
            var fakeRegistration: [String: Any]? = replacement
            var bootstrapCount = 0
            calls = []
            let updateExecutor: Executor = { arguments in
                calls.append(arguments)
                if arguments.first == "print" {
                    return fakeRegistration.map { ResidentInstallationCommand(status: 0, output: report(update, plist: $0)) }
                        ?? ResidentInstallationCommand(status: 113, output: "not registered")
                }
                if arguments.first == "bootout" { fakeRegistration = nil; return ResidentInstallationCommand(status: 0, output: "") }
                if arguments.first == "bootstrap" {
                    bootstrapCount += 1
                    if bootstrapCount == 1 { return ResidentInstallationCommand(status: 5, output: "injected bootstrap failure") }
                    fakeRegistration = replacement
                    return ResidentInstallationCommand(status: 0, output: "")
                }
                throw failure("TEST_COMMAND_INVALID", "Unexpected fake launchctl operation")
            }
            do { _ = try perform(update, execute: updateExecutor); tests.check(false, "installation/bootstrap-failure-restores-prior-registration") }
            catch {
                let restored = try readPrivateFile(staged.plistPath)
                tests.check(errorJSON(error).at(path: "code") == .string("INSTALL.BOOTSTRAP_FAILED")
                    && errorJSON(error).at(path: "context.rollback_succeeded") == .bool(true)
                    && bootstrapCount == 2 && fakeRegistration != nil && restored == prior,
                    "installation/bootstrap-failure-restores-prior-registration")
            }
            tests.check(calls.first == ["print", update.service] && calls.filter { $0.first == "bootout" }.count == 1,
                "installation/update-inspects-before-stopping-and-writes-no-second-job")

            fakeRegistration = replacement
            do {
                _ = try perform(update, execute: { arguments in
                    if arguments.first == "print" {
                        return fakeRegistration.map { ResidentInstallationCommand(status: 0, output: report(update, plist: $0)) }
                            ?? ResidentInstallationCommand(status: 113, output: "")
                    }
                    if arguments.first == "bootout" { fakeRegistration = nil; return ResidentInstallationCommand(status: 0, output: "") }
                    return ResidentInstallationCommand(status: 5, output: "injected startup and rollback failure")
                })
                tests.check(false, "installation/rollback-failure-is-explicit-and-preserves-prior-plist")
            } catch {
                let restored = try readPrivateFile(staged.plistPath)
                tests.check(errorJSON(error).at(path: "context.rollback_succeeded") == .bool(false)
                    && errorJSON(error).at(path: "context.rollback_error.code") == .string("INSTALL.LAUNCHCTL_FAILED")
                    && restored == prior, "installation/rollback-failure-is-explicit-and-preserves-prior-plist")
            }

            let fresh = try options("fresh-failure", start: true)
            do {
                _ = try perform(fresh, execute: { arguments in
                    arguments.first == "print" ? ResidentInstallationCommand(status: 113, output: "")
                        : ResidentInstallationCommand(status: 5, output: "injected bootstrap failure")
                })
                tests.check(false, "installation/failed-first-bootstrap-removes-only-new-plist")
            } catch {
                tests.check(errorJSON(error).at(path: "context.rollback_succeeded") == .bool(true)
                    && !FileManager.default.fileExists(atPath: fresh.plistPath)
                    && FileManager.default.fileExists(atPath: ResidentLayout.settings(config: ResidentLayout.config(root: fresh.root))),
                    "installation/failed-first-bootstrap-removes-only-new-plist")
            }

            var remove = staged; remove.operation = "uninstall"; remove.plan = true
            calls = []
            _ = try perform(remove, execute: { arguments in calls.append(arguments); return try absent(arguments) })
            let dryRemovedPlist = try readPrivateFile(staged.plistPath)
            tests.check(calls.isEmpty && dryRemovedPlist == prior, "installation/uninstall-plan-preserves-plist-and-calls-nothing")
            remove.plan = false
            _ = try perform(remove, execute: absent)
            let removedSettings = try readPrivateFile(settingsPath)
            let removedJournal = try readPrivateFile(journalPath)
            tests.check(!FileManager.default.fileExists(atPath: staged.plistPath)
                && removedSettings == settings && removedJournal == journal,
                "installation/uninstall-preserves-user-data-and-removes-only-owned-plist")

            var startMissing = fresh; startMissing.operation = "service-start"
            refused("start-requires-canonical-installed-plist", code: "NOT_INSTALLED") { _ = try perform(startMissing, execute: absent) }
            refused("symlink-root-is-refused", code: "PATH_UNSAFE") {
                let linked = try options("linked")
                try createPrivateDirectory((linked.root as NSString).deletingLastPathComponent)
                guard symlink(staged.root, linked.root) == 0 else { throw failure("TEST_SYMLINK_FAILED", "Cannot create fixture symlink") }
                _ = try perform(linked, execute: absent)
            }
        } catch {
            tests.check(false, "installation/fixture-failed:" + errorJSON(error).canonical())
        }
        return tests.finish("installation")
    }
}

/// Test fake launchctl registration, rollback and filesystem safety; no real
/// launchctl command, resident socket, event tap or Accessibility call is used.
func runResidentInstallationSelfTest() -> Int32 { ResidentInstallation.selfTest() }
