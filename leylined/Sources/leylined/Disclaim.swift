// The resident owns its Accessibility attribution independently of its launcher.
// Re-exec in place once using the macOS responsibility disclaim API before AX work.
import Foundation

private func terminatedCString(_ chars: [CChar]) -> String {
    String(decoding: chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func ownExecutablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
    var real = [CChar](repeating: 0, count: Int(PATH_MAX))
    return (realpath(buf, &real) != nil) ? terminatedCString(real) : terminatedCString(buf)
}

func selfDisclaimReexecIfNeeded() {
    if ProcessInfo.processInfo.environment["LEYLINED_DISCLAIMED"] == "1" { return }
    let selfPath = ownExecutablePath()
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_spawnattrs_setdisclaim") else {
        FileHandle.standardError.write(Data("leylined: disclaim API unavailable — proceeding undisclaimed (AX may not attribute)\n".utf8))
        return
    }
    _ = unsafeBitCast(sym, to: DisclaimFn.self)(&attr, 1)
    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { return }
    setenv("LEYLINED_DISCLAIMED", "1", 1)
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(selfPath)]
    for a in CommandLine.arguments.dropFirst() { argv.append(strdup(a)) }
    argv.append(nil)
    var pid: pid_t = 0
    _ = posix_spawn(&pid, selfPath, nil, &attr, argv, environ)
    // SETEXEC replaces the image on success and never returns; reaching here failed.
    FileHandle.standardError.write(Data("leylined: self-disclaim re-exec failed — proceeding undisclaimed\n".utf8))
}
