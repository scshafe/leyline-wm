import Foundation

/// The window server tells every connection when a window joins (1325) or
/// leaves (1326) a Space; the payload words are [space id, 0, window id]. A
/// Mission Control move raises no AX or workspace event, so this is its only
/// prompt evidence. Handlers run on the main thread inside the AppKit event
/// loop. Private ABI follows yabai; a missing entry point reports false.
enum CoreWindowSpaceNotifications {
    private typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias Register = @convention(c) (Handler, UInt32, UnsafeMutableRawPointer?) -> Int32
    static let windowAddedToSpace: UInt32 = 1325
    static let windowRemovedFromSpace: UInt32 = 1326
    nonisolated(unsafe) private static var receive: ((Int64) -> Void)?

    /// Registers once for the process lifetime.
    @MainActor
    static func register(_ receive: @escaping (Int64) -> Void) -> Bool {
        guard self.receive == nil,
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
              let pointer = dlsym(handle, "SLSRegisterNotifyProc") else { return false }
        let register = unsafeBitCast(pointer, to: Register.self)
        self.receive = receive
        let handler: Handler = { _, data, length, _ in
            guard let data, length >= 12 else { return }
            CoreWindowSpaceNotifications.receive?(Int64(data.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        }
        return [windowAddedToSpace, windowRemovedFromSpace].allSatisfy { register(handler, $0, nil) == 0 }
    }
}
