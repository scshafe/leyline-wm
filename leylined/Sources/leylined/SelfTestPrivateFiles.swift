import Darwin
import Foundation
import LeylineModel

/// Real local file boundary tests; no user state or runtime input owner is involved.
func runPrivateFilesScenarios(test: inout SelfTest) {
    let path = "/tmp/ley-private-" + String(UUID().uuidString.prefix(12))
    do {
        let parent = try ResidentPrivateFiles.openDirectory(at: path, create: true)
        close(parent)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = path + "/original.jsonl"
        let journal = ResidentEffectorFileJournal(path: original)
        let record: JSONValue = .object(["type": .string("effect_intent"), "request_id": .string("private-file"),
            "revision": .int(1), "frame": Frame(x: 0, y: 0, w: 100, h: 100).json])
        try journal.append(record)
        let preserved = try Data(contentsOf: URL(fileURLWithPath: original))
        let symlinkPath = path + "/symlink.jsonl"
        guard symlinkPath.withCString({ linkName in original.withCString { Darwin.symlink($0, linkName) } }) == 0 else {
            test.check(false, "private-files/symlink-fixture-created"); return
        }
        let linked = ResidentEffectorFileJournal(path: symlinkPath)
        var rejectedRead = false, rejectedAppend = false
        do { _ = try linked.recover() } catch { rejectedRead = true }
        do { try linked.append(record) } catch { rejectedAppend = true }
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: original))
        test.check(rejectedRead && rejectedAppend && unchanged == preserved,
            "private-files/symlink-journal-refuses-read-and-write-without-changing-target")
        let hardlink = path + "/hardlink.jsonl"
        guard link(original, hardlink) == 0 else { test.check(false, "private-files/hardlink-fixture-created"); return }
        var sharedRejected = false
        do { _ = try journal.recover() } catch { sharedRejected = true }
        test.check(sharedRejected, "private-files/shared-inode-journal-refuses-recovery")
        unlink(hardlink)
        guard chmod(original, mode_t(0o644)) == 0 else { test.check(false, "private-files/permissions-fixture-created"); return }
        var publicRejected = false
        do { try journal.append(record) } catch { publicRejected = true }
        test.check(publicRejected, "private-files/group-or-world-readable-journal-refuses-append")
        let directoryLink = path + "/linked-directory"
        guard Darwin.symlink(path, directoryLink) == 0 else { test.check(false, "private-files/directory-symlink-created"); return }
        var directoryRejected = false
        do { close(try ResidentPrivateFiles.openDirectory(at: directoryLink, create: false)) } catch { directoryRejected = true }
        test.check(directoryRejected, "private-files/directory-walk-refuses-symlink-components")
    } catch { test.check(false, "private-files/fixture-failed: \(error)") }
}
