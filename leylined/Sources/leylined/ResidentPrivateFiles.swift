import Darwin
import Foundation

struct ResidentPrivateFileError: Error {
    let operation: String
    let path: String
    let errorNumber: Int32
}

/// @canonical resident_private_files -- state paths never traverse user-controlled symlinks.
/// Directory walks are anchored to descriptors; final state directories and files are owner-only.
enum ResidentPrivateFiles {
    /// Return an owned directory descriptor; caller closes it. Creation uses mode0700.
    /// System /tmp and /var aliases are normalized before no-follow traversal.
    /// Existing non-private terminal directories fail unless repairPermissions is explicitly requested.
    static func openDirectory(at path: String, create: Bool, privateMode: Bool = true,
                              repairPermissions: Bool = false, allowSystemTerminal: Bool = false) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw failure("directory_absolute_path", path, EINVAL) }
        var normalized = path
        if normalized == "/tmp" || normalized.hasPrefix("/tmp/") { normalized = "/private" + normalized }
        if normalized == "/var" || normalized.hasPrefix("/var/") { normalized = "/private" + normalized }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw failure("directory_components", path, EINVAL)
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure("directory_root_open", path, errno) }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(parent, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw failure("directory_create", path, errno)
                    }
                    next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw failure("directory_open", path, errno) }
                close(parent); parent = next
                var facts = stat()
                guard fstat(parent, &facts) == 0 else { throw failure("directory_stat", path, errno) }
                let terminal = index == components.count - 1
                let rootSticky = facts.st_uid == 0 && (facts.st_mode & S_ISVTX) != 0
                guard (facts.st_mode & S_IFMT) == S_IFDIR,
                      facts.st_uid == geteuid() || ((!terminal || (allowSystemTerminal && !privateMode)) && facts.st_uid == 0),
                      (facts.st_mode & 0o022) == 0 || ((!terminal || (allowSystemTerminal && !privateMode)) && rootSticky) else {
                    throw failure("directory_owner_or_permissions", path, EPERM)
                }
                if terminal && privateMode && (facts.st_mode & 0o077) != 0 {
                    guard repairPermissions, fchmod(parent, mode_t(0o700)) == 0 else {
                        throw failure("directory_not_private", path, EPERM)
                    }
                }
            }
            return parent
        } catch { close(parent); throw error }
    }

    /// Require a regular, unshared same-user descriptor with no group/world access.
    static func validateRegular(_ descriptor: Int32, path: String) throws {
        var facts = stat()
        guard fstat(descriptor, &facts) == 0 else { throw failure("file_stat", path, errno) }
        guard (facts.st_mode & S_IFMT) == S_IFREG, facts.st_uid == geteuid(),
              facts.st_nlink == 1, (facts.st_mode & 0o077) == 0 else {
            throw failure("file_owner_type_or_permissions", path, EPERM)
        }
    }

    private static func failure(_ operation: String, _ path: String, _ number: Int32) -> ResidentPrivateFileError {
        .init(operation: operation, path: path, errorNumber: number)
    }
}
