// Shared scaffolding for the hermetic self-test suites. Developer build only:
// every SelfTest* source is excluded from the shipping profile.
import ApplicationServices
import Foundation
import LeylineModel

/// Where the suites read their frozen inputs from. One rule for every suite:
/// `--home` on the command line, then LEYLINE_HOME, then this source tree.
enum SelfTestFixtures {
    /// The repository root: resources (`keymap/`), sources and `leylined/Fixtures` hang off it.
    static func repositoryRoot(arguments: [String] = []) -> String {
        if let index = arguments.firstIndex(of: "--home"), index + 1 < arguments.count { return arguments[index + 1] }
        if let home = ProcessInfo.processInfo.environment["LEYLINE_HOME"], !home.isEmpty { return home }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Absolute path of `leylined/Fixtures/<relative>` under `root`.
    static func path(_ relative: String, root: String = repositoryRoot()) -> String {
        root + "/leylined/Fixtures/" + relative
    }

    static func url(_ relative: String, root: String = repositoryRoot()) -> URL {
        URL(fileURLWithPath: path(relative, root: root))
    }

    static func data(_ relative: String, root: String = repositoryRoot()) -> Data? {
        FileManager.default.contents(atPath: path(relative, root: root))
    }

    /// The parsed fixture, or nil when it is missing or malformed.
    static func json(_ relative: String, root: String = repositoryRoot()) -> JSONValue? {
        data(relative, root: root).flatMap { try? JSONValue.parse($0) }
    }
}

/// Poll `predicate` every `pollMicroseconds` until it holds or `seconds` elapse.
func selfTestWaitUntil(seconds: Double = 2, pollMicroseconds: UInt32 = 500, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if predicate() { return true }
        usleep(pollMicroseconds)
    }
    return false
}

extension JSONValue {
    /// Required fixture scalars. A missing or mistyped key is a fixture
    /// authoring bug, so these trap instead of turning into a skipped check.
    func requiredUInt64(_ path: String) -> UInt64 { UInt64(at(path: path)!.intValue!) }
    func requiredInt(_ path: String) -> Int { Int(at(path: path)!.intValue!) }
    func requiredString(_ path: String) -> String { at(path: path)!.stringValue! }
}

/// The pid-scoped short socket path the hermetic servers bind (sockaddr_un caps at ~104 bytes).
func selfTestSocketPath(_ name: String) -> String {
    "/tmp/leyline-tests-\(getpid())/\(name)-\(getpid()).sock"
}

/// A thread-safe append-only record of what a fake observed.
final class Recorded<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ element: Element) { lock.withLock { items.append(element) } }
    var values: [Element] { lock.withLock { items } }
    var last: Element? { lock.withLock { items.last } }
    var count: Int { lock.withLock { items.count } }
}

/// An executor the test drives by hand: work queues FIFO and runs only when asked.
class ManualExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []
    func enqueue(_ operation: @escaping @Sendable () -> Void) { lock.withLock { operations.append(operation) } }
    var pending: Int { lock.withLock { operations.count } }
    /// Run the oldest queued operation, if any.
    func runOne() {
        let operation: (@Sendable () -> Void)? = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
        operation?()
    }
    /// Run queued operations in order until the queue is empty, including work they enqueue.
    func drain() {
        while true {
            let operation: (@Sendable () -> Void)? = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
            guard let operation else { return }
            operation()
        }
    }
}

/// A manual executor that also records the snapshots a presentation mailbox hands it.
final class ManualPresenter: ManualExecutor, @unchecked Sendable {
    private let presentedLock = NSLock()
    private var rendered: [CoreCommittedSnapshot] = []
    func present(_ snapshot: CoreCommittedSnapshot) { presentedLock.withLock { rendered.append(snapshot) } }
    var presented: [CoreCommittedSnapshot] { presentedLock.withLock { rendered } }
}

/// An AX focus observer that records attaches/detaches and emits what the test injects.
final class FakeAccessibilityObserver: AccessibilityFocusObserving, @unchecked Sendable {
    var onEvent: ((AccessibilityFocusEvent) -> Void)?
    var onHealthChanged: ((AccessibilityObserverHealth) -> Void)?
    var attaches: [(pid_t, UInt64)] = []
    var detachGenerations: [UInt64] = []
    var nextHealth: AccessibilityObserverHealth?

    func attach(to pid: pid_t, generation: UInt64) -> AccessibilityObserverHealth {
        attaches.append((pid, generation))
        return nextHealth ?? AccessibilityObserverHealth(
            ready: true, pid: pid, generation: generation,
            windowNotificationsReady: true, degradedReason: nil)
    }

    func detach(generation: UInt64) {
        detachGenerations.append(generation)
    }

    func emit(_ kind: AccessibilityFocusEventKind, pid: pid_t, generation: UInt64,
              windowGeneration: UInt64 = 0, element: AXUIElement? = nil, windowId: Int64? = nil) {
        onEvent?(AccessibilityFocusEvent(kind: kind, pid: pid, generation: generation,
            windowGeneration: windowGeneration, element: element, windowId: windowId))
    }

    func emitHealth(_ health: AccessibilityObserverHealth) {
        onHealthChanged?(health)
    }
}
