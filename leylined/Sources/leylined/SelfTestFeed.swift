// Hermetic feed tests: fake AX/lifecycle events drive the real generation,
// epoch and core transition boundaries. No AppKit, live socket, file mirror,
// or timer runs.
import ApplicationServices
import CoreGraphics
import Foundation
import LeylineModel

private final class AccessibilityHealthFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccessibilityObserverHealth] = []

    func append(_ value: AccessibilityObserverHealth) {
        lock.withLock { values.append(value) }
    }

    var all: [AccessibilityObserverHealth] {
        lock.withLock { values }
    }

    var latest: AccessibilityObserverHealth? { all.last }
}

private final class FeedSnapshotFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var next = ProjectionWorldSnapshot(windowsOnscreen: 0, focus: .null)
    private(set) var captures = 0

    func set(_ snapshot: ProjectionWorldSnapshot) {
        lock.lock()
        next = snapshot
        lock.unlock()
    }

    func capture(_ application: ProjectionApplication?) -> ProjectionWorldSnapshot {
        lock.lock()
        defer { lock.unlock() }
        captures += 1
        return next
    }
}

private final class FeedDeliveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JSONObject] = []

    func append(_ value: JSONObject) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [JSONObject] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func feedFocus(_ windowId: Int64, x: Double) -> JSONValue {
    .object([
        "window_id": .int(windowId),
        "frame": .object([
            "x": .double(x), "y": .double(10),
            "w": .double(400), "h": .double(300),
        ]),
    ])
}

func runFeedSelfTest() -> Int32 {
    var test = SelfTest()
    let systemPath = "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
    test.check(projectionIsSystemUIOwner(bundleIdentifier: "com.apple.WindowManager", executablePath: systemPath),
        "feed/positively-identified-system-composition-owner-is-excluded")
    test.check(!projectionIsSystemUIOwner(bundleIdentifier: "com.apple.WindowManager", executablePath: "/tmp/WindowManager")
        && !projectionIsSystemUIOwner(bundleIdentifier: "third.party.WindowManager", executablePath: systemPath)
        && !projectionIsSystemUIOwner(bundleIdentifier: nil, executablePath: nil),
        "feed/unknown-and-spoofed-owners-still-require-complete-AX-classification")
    // Live shape 2026-10-13: Safari native full-screen on type-4 Space 918; the
    // toolbar strip (no AX window) and the full-screen window occupy only 918.
    let spaceTypes: [UInt64: Int] = [4: 0, 874: 0, 800: 4, 918: 4]
    let memberships: [Int64: [UInt64]] = [13223: [918], 13161: [918], 5641: [4], 7: [4, 918], 8: [999], 9: []]
    let excluded = projectionNonDesktopOnlyWindowIds([13223, 13161, 5641, 7, 8, 9, 10], spaceTypes: spaceTypes) { memberships[$0] }
    test.check(excluded == [13223, 13161],
        "feed/full-screen-only-rows-are-outside-the-desktop-inventory-contract")
    test.check(!excluded.contains(5641) && !excluded.contains(7) && !excluded.contains(8)
        && !excluded.contains(9) && !excluded.contains(10),
        "feed/desktop-shared-unknown-empty-and-unreadable-memberships-stay-required")
    test.check(projectionNonDesktopOnlyWindowIds([13223], spaceTypes: [4: 0, 918: 0]) { memberships[$0] }.isEmpty,
        "feed/no-known-non-desktop-Space-excludes-nothing")
    // Live shape 2026-10-16: Xcode's Device Hub was a regular running app with
    // processIdentifier -1; enrolling it failed AXObserverCreate and refused
    // every world read for 12 h.
    test.check(projectionInventoryOwnerPids(visibleOwners: [1153, 10194], regularApplications: [675, 1153, 47208, -1, 0],
        excluded: [821]) == [675, 1153, 10194, 47208],
        "feed/regular-app-without-a-process-is-not-an-AX-enrollment-owner")
    test.check(projectionInventoryOwnerPids(visibleOwners: [821, 900], regularApplications: [821, 901],
        excluded: [821, 900]) == [901],
        "feed/self-and-system-owners-stay-excluded-from-the-owner-cohort")

    let observer = FakeAccessibilityObserver()
    let snapshots = FeedSnapshotFixture()
    let deliveries = FeedDeliveryFixture()
    let feedHealth = AccessibilityHealthFixture()
    let operations = ManualExecutor()
    let integratedCore = CoreServer(
        socketPath: selfTestSocketPath("leylined-feed-integrated"))
    snapshots.set(ProjectionWorldSnapshot(
        windowsOnscreen: 2, focus: feedFocus(101, x: 0)))
    let feed = ProjectionInputFeed(
        observer: observer,
        capture: { snapshots.capture($0) },
        executeOnObservationLane: { operations.enqueue($0) },
        onHealthChanged: {
            feedHealth.append($0)
            integratedCore.updateFocusObserverHealth($0)
        },
        deliver: {
            deliveries.append($0)
            _ = integratedCore.applyWorldDelta($0)
        })
    let appOne = ProjectionApplication(pid: 111, name: "One")
    feed.start(frontmost: appOne)

    test.check(
        deliveries.all.count == 1
            && deliveries.all[0]["event"]?.stringValue == "world_seed"
            && deliveries.all[0]["focus"]?.at(path: "window_id")?.intValue == 101
            && integratedCore.currentRevision == 1
            && integratedCore.worldState.at(path: "event")?.stringValue == "world_seed"
            && integratedCore.worldState.at(path: "focus.window_id")?.intValue == 101,
        "feed/world-seed-synchronously-commits-exact-core-revision-one")
    test.check(
        observer.attaches.count == 1 && observer.attaches[0].0 == 111
            && feedHealth.all.count == 3
            && feedHealth.all.first?.degradedReason == "not_started"
            && feedHealth.all.dropFirst().first?.degradedReason
                == "observer_rebinding"
            && feedHealth.latest?.ready == true,
        "feed/initial-app-observer-attach-is-checked")

    let firstGeneration = feed.currentGeneration
    snapshots.set(ProjectionWorldSnapshot(
        windowsOnscreen: 2, focus: feedFocus(102, x: 10)))
    observer.emit(.focusedWindowChanged, pid: 111, generation: firstGeneration)
    test.check(
        operations.pending == 1 && deliveries.all.count == 1,
        "feed/ax-callback-reenters-main-before-delivery")
    operations.runOne()
    test.check(
        deliveries.all.last?["event"]?.stringValue == "ax_focus_changed"
            && deliveries.all.last?["focus"]?.at(path: "window_id")?.intValue == 102,
        "feed/same-app-focus-captures-fresh-snapshot")

    observer.emitHealth(.degraded(
        pid: 111, generation: feed.currentGeneration,
        reason: "ax_window_registration_failed:test"))
    operations.runOne()
    observer.emitHealth(AccessibilityObserverHealth(
        ready: true, pid: 111, generation: feed.currentGeneration,
        windowNotificationsReady: true, degradedReason: nil))
    operations.runOne()
    test.check(
        feedHealth.all.contains {
            $0.degradedReason == "ax_window_registration_failed:test"
        } && feedHealth.latest?.ready == true
            && feedHealth.latest?.degradedReason == nil,
        "feed/health-callback-emits-initial-degradation-and-recovery")

    snapshots.set(ProjectionWorldSnapshot(
        windowsOnscreen: 2, focus: feedFocus(102, x: 20)))
    observer.emit(.focusedWindowMoved, pid: 111, generation: firstGeneration)
    operations.runOne()
    test.check(
        deliveries.all.last?["event"]?.stringValue == "ax_window_moved"
            && deliveries.all.last?["focus"]?.at(path: "frame.x")?.numberValue == 20,
        "feed/window-move-captures-new-frame")

    snapshots.set(ProjectionWorldSnapshot(
        windowsOnscreen: 2, focus: feedFocus(102, x: 30)))
    observer.emit(.focusedWindowResized, pid: 111, generation: firstGeneration)
    operations.runOne()
    test.check(
        deliveries.all.last?["event"]?.stringValue == "ax_window_resized"
            && deliveries.all.last?["focus"]?.at(path: "frame.x")?.numberValue == 30,
        "feed/window-resize-captures-new-frame")

    let appTwo = ProjectionApplication(pid: 222, name: "Two")
    snapshots.set(ProjectionWorldSnapshot(
        windowsOnscreen: 3, focus: feedFocus(201, x: 40)))
    feed.applicationActivated(appTwo)
    test.check(
        feed.currentGeneration > firstGeneration
            && observer.attaches.last?.0 == 222
            && deliveries.all.last?["event"]?.stringValue == "app_activated",
        "feed/app-activation-detaches-and-rebinds")

    let afterActivationCount = deliveries.all.count
    observer.emit(.focusedWindowChanged, pid: 111, generation: firstGeneration)
    operations.runOne()
    test.check(
        deliveries.all.count == afterActivationCount,
        "feed/late-prior-generation-callback-is-suppressed")

    let beforeSpaceGeneration = feed.currentGeneration
    feed.spaceChanged(frontmost: appTwo)
    test.check(
        feed.currentGeneration > beforeSpaceGeneration
            && observer.attaches.last?.0 == 222
            && deliveries.all.last?["event"]?.stringValue == "space_changed",
        "feed/space-change-rebinds-even-when-pid-is-stable")

    snapshots.set(ProjectionWorldSnapshot(windowsOnscreen: 2, focus: .null))
    observer.emit(
        .focusedWindowChanged, pid: 222, generation: feed.currentGeneration)
    operations.runOne()
    test.check(
        deliveries.all.last?["focus"] == .null,
        "feed/focus-null-clears-stale-focus")

    let accessibilitySourcePath = (#filePath as NSString)
        .deletingLastPathComponent + "/AccessibilityFocusObserver.swift"
    let accessibilitySource = try? String(
        contentsOfFile: accessibilitySourcePath, encoding: .utf8)
    test.check(
        accessibilitySource?.contains("bindFocusedWindowNotifications(notifiedWindow: notifiedWindow)") == true
            && accessibilitySource?.contains("kAXUIElementDestroyedNotification") == true
            && accessibilitySource?.contains("kAXWindowMiniaturizedNotification") == true
            && accessibilitySource?.contains("CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .commonModes") == true,
        "feed/canonical-ax-focus-callback-rebinds-and-cleans-both-window-registrations")

    snapshots.set(ProjectionWorldSnapshot(windowsOnscreen: 1, focus: .null))
    feed.applicationTerminated(pid: 222, frontmost: nil)
    test.check(
        deliveries.all.last?["event"]?.stringValue == "app_terminated"
            && deliveries.all.last?["frontmost_pid"] == .null
            && feedHealth.latest?.degradedReason == "no_frontmost_application",
        "feed/app-termination-detaches-and-clears-frontmost")
    let idleCaptureCount = snapshots.captures
    let idleDeliveryCount = deliveries.all.count
    test.check(
        snapshots.captures == idleCaptureCount
            && deliveries.all.count == idleDeliveryCount
            && operations.pending == 0,
        "feed/no-autonomous-polling-or-timer-work")

    var cursor = ModeFrameCursor()
    test.check(
        cursor.admit(ModeFrame(type: .changed, epoch: "e1", sequence: 1, mode: "move"))
            == .missingEpochBaseline,
        "mode/changed-cannot-establish-epoch")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e1", sequence: 0, mode: "default"))
            == .accepted,
        "mode/initial-locked-snapshot-establishes-epoch")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e1", sequence: 0, mode: "default"))
            == .confirmedCurrentSnapshot,
        "mode/equal-snapshot-confirms-current-reconnect-baseline")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e1", sequence: 0, mode: "move"))
            == .snapshotConflict && cursor.activeMode == "default",
        "mode/equal-sequence-conflicting-snapshot-is-visible-and-nonmutating")
    test.check(
        cursor.admit(ModeFrame(type: .changed, epoch: "e1", sequence: 1, mode: "move"))
            == .accepted,
        "mode/exact-next-change-is-accepted")
    test.check(
        cursor.admit(ModeFrame(type: .changed, epoch: "e1", sequence: 3, mode: "resize"))
            == .sequenceGap && cursor.activeSequence == 1,
        "mode/change-sequence-gap-is-visible-and-nonmutating")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e1", sequence: 5, mode: "resize"))
            == .accepted && cursor.activeSequence == 5,
        "mode/reconnect-snapshot-may-advance-same-epoch-baseline")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e2", sequence: 0, mode: "default"))
            == .accepted,
        "mode/new-epoch-snapshot-is-accepted")
    test.check(
        cursor.admit(ModeFrame(type: .snapshot, epoch: "e1", sequence: 99, mode: "move"))
            == .ignoredRetiredEpoch,
        "mode/retired-epoch-cannot-return")

    let corePath = selfTestSocketPath("leylined-feed-core")
    let core = CoreServer(socketPath: corePath)
    _ = core.applyWorldDelta(["event": .string("world_seed"), "focus": .null])
    let modeAccepted = core.applyModeFrame(
        ModeFrame(type: .snapshot, epoch: "core-e", sequence: 0, mode: "default"))
    let modeDuplicate = core.applyModeFrame(
        ModeFrame(type: .snapshot, epoch: "core-e", sequence: 0, mode: "default"))
    let modeNext = core.applyModeFrame(
        ModeFrame(type: .changed, epoch: "core-e", sequence: 1, mode: "move"))
    test.check(
        modeAccepted.status == .accepted && modeAccepted.revision.value == 2
            && modeDuplicate.status == .noop && modeDuplicate.revision.value == 2
            && modeNext.status == .accepted && modeNext.revision.value == 3,
        "mode/core-transition-mints-only-for-authoritative-frames")
    test.check(
        core.worldState.at(path: "mode")?.stringValue == "move"
            && core.worldState.at(path: "mode_epoch")?.stringValue == "core-e"
            && core.worldState.at(path: "mode_sequence")?.intValue == 1,
        "mode/core-world-folds-mode-epoch-and-sequence")

    runCacheIntegrityAuditScenarios(test: &test)
    runProjectionAXReadBudgetScenarios(test: &test)
    runProjectionTransientRecoveryScenarios(test: &test)
    runTargetedProjectionScenarios(test: &test)
    return test.finish("feed")
}

private final class TargetedFeedWindowFixture: TargetedProjectionWindowReading, @unchecked Sendable {
    var records: [Int64: TargetedWindowObservation] = [:]
    var elements: [Int64: AXUIElement] = [:]
    var focusedId: Int64?
    var inventoryCalls = 0
    var focusCalls = 0
    var identityChecks = 0
    var readIds: [Int64] = []
    var beforeRead: (@Sendable () -> Void)?
    var beforeIdentityCheck: (@Sendable () -> Void)?
    var readFailure: ProjectionObservationFailure?
    var inventoryFailure: ProjectionObservationFailure?
    var identityAvailable = true
    var recycledIdentity = false
    var freshQueries: [(pid_t, Int64)] = []
    var freshOverride: Result<ProjectionWindowHandle, ProjectionObservationFailure>?
    var supportsCacheAudit = false
    var retirementInventoryOverride: ProjectionWindowInventory?
    func auditInventory(ignored: [ProjectionWindowHandle], beforeExternalCall: @escaping ProjectionAuditGuard)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        if let retirementInventoryOverride { return .success(retirementInventoryOverride) }
        return inventory(enrollOwners: { _ in .success(()) })
    }
    func auditRead(handle: ProjectionWindowHandle, beforeExternalCall: @escaping ProjectionAuditGuard)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        if let failure = beforeExternalCall() { return .failure(failure) }
        return read(element: handle.element, pid: handle.pid, expectedWindowId: handle.windowId)
    }

    func freshWindowHandle(pid: pid_t, windowId: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        freshQueries.append((pid, windowId))
        if let freshOverride { return freshOverride }
        guard let record = records[windowId], let element = elements[windowId] else {
            return .failure(.init(code: "effect_fresh_handle_missing"))
        }
        return .success(.init(element: element, pid: record.pid, windowId: windowId))
    }

    init(_ rows: [JSONValue]) {
        for row in rows {
            guard let id = row.at(path: "window_id")?.intValue,
                  let pid = row.at(path: "pid")?.intValue,
                  let frame = Frame.from(row.at(path: "frame")) else { continue }
            records[id] = TargetedWindowObservation(windowId: id, pid: pid_t(pid), frame: frame,
                role: row.at(path: "role")?.stringValue ?? "AXWindow", subrole: row.at(path: "subrole")?.stringValue ?? "AXStandardWindow", title: "Fixture", resizable: true,
                movable: true, minimized: false, onscreen: true)
            elements[id] = AXUIElementCreateApplication(pid_t(pid))
        }
        focusedId = records.keys.min()
    }

    func inventory(enrollOwners: (Set<pid_t>) -> Result<Void, ProjectionObservationFailure>)
        -> Result<ProjectionWindowInventory, ProjectionObservationFailure> {
        inventoryCalls += 1
        if case .failure(let failure) = enrollOwners(Set(records.values.map(\.pid))) { return .failure(failure) }
        if let inventoryFailure { return .failure(inventoryFailure) }
        return .success(.init(handles: records.keys.sorted().compactMap { id in
            guard let record = records[id], let element = elements[id] else { return nil }
            return ProjectionWindowHandle(element: element, pid: record.pid, windowId: id)
        }, visibleWindowIds: Set(records.keys), ownerPids: Set(records.values.map(\.pid))))
    }

    func focusedElement(pid: pid_t) -> Result<AXUIElement?, ProjectionObservationFailure> {
        focusCalls += 1
        return .success(focusedId.flatMap { elements[$0] })
    }

    func read(element: AXUIElement?, pid: pid_t, expectedWindowId: Int64?)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        if let readFailure { return .failure(readFailure) }
        guard let element, let id = expectedWindowId ?? focusedId,
              let record = records[id], let current = elements[id],
              ObjectIdentifier(element) == ObjectIdentifier(current) else {
            return .failure(.init(code: "fixture_target_unavailable"))
        }
        readIds.append(id)
        beforeRead?()
        if recycledIdentity {
            return .success(TargetedWindowObservation(windowId: id + 1, pid: record.pid, frame: record.frame,
                role: record.role, subrole: record.subrole, title: record.title, resizable: record.resizable,
                movable: record.movable, minimized: record.minimized, onscreen: record.onscreen))
        }
        return .success(record)
    }

    func move(_ id: Int64, x: Double) {
        guard let record = records[id] else { return }
        records[id] = TargetedWindowObservation(windowId: id, pid: record.pid,
            frame: Frame(x: x, y: record.frame.y, w: record.frame.w, h: record.frame.h),
            role: record.role, subrole: record.subrole, title: record.title,
            resizable: record.resizable, movable: record.movable,
            minimized: record.minimized, onscreen: record.onscreen)
    }

    func isCurrent(_ handle: ProjectionWindowHandle) -> Bool {
        identityChecks += 1
        beforeIdentityCheck?()
        return identityAvailable && records[handle.windowId]?.pid == handle.pid
            && elements[handle.windowId].map { ObjectIdentifier($0) == ObjectIdentifier(handle.element) } == true
    }

    func reuseWindowId(_ id: Int64) {
        guard let record = records[id] else { return }
        elements[id] = AXUIElementCreateApplication(record.pid)
        move(id, x: record.frame.x + 100)
    }
}

private final class TargetedFeedSpaceFixture: ProjectionSpaceObserving, @unchecked Sendable {
    var contexts: [Int64: ProjectionSpaceContext] = [:]
    /// Windows on a Space created after the baseline: no context, still on a Space.
    var unbaselined: Set<Int64> = []
    var unavailable = false
    var baselineCalls = 0
    var contextCalls = 0
    var currentContextCalls = 0
    init(_ rows: [JSONValue]) {
        for row in rows {
            guard let id = row.at(path: "window_id")?.intValue,
                  let key = row.at(path: "space_key")?.stringValue,
                  let display = row.at(path: "display_id")?.stringValue else { continue }
            contexts[id] = .init(key: key, displayId: display, visible: true)
        }
    }
    func rebaseline() -> Result<Void, ProjectionObservationFailure> {
        baselineCalls += 1
        return unavailable ? .failure(.init(code: "independent_space_observation_unavailable")) : .success(())
    }
    func context(windowId: Int64) -> Result<ProjectionSpaceContext, ProjectionObservationFailure> {
        contextCalls += 1
        guard !unavailable, let context = contexts[windowId] else {
            return .failure(.init(code: "independent_window_space_unknown_or_ambiguous"))
        }
        return .success(context)
    }
    func currentContexts() -> Result<[ProjectionSpaceContext], ProjectionObservationFailure> {
        currentContextCalls += 1
        guard !unavailable else { return .failure(.init(code: "independent_current_display_space_unavailable")) }
        let grouped = Dictionary(grouping: contexts.values, by: \.displayId)
        return .success(grouped.keys.sorted().compactMap { grouped[$0]?.first })
    }
    func occupiesSpace(windowId: Int64) -> Bool { contexts[windowId] != nil || unbaselined.contains(windowId) }
}

private final class TargetedFeedWorldObserverFixture: ProjectionWorldObserving, @unchecked Sendable {
    var onEvent: (@Sendable (AccessibilityFocusEvent) -> Void)?
    var windowIds: Set<Int64> = []
    var nextFailure: ProjectionObservationFailure?
    var begins = 0
    var activeGeneration: UInt64 = 0
    var stops = 0
    func begin(ownerPids: Set<pid_t>, generation: UInt64) -> Result<Void, ProjectionObservationFailure> {
        begins += 1
        activeGeneration = generation
        if let nextFailure { return .failure(nextFailure) }
        return .success(())
    }
    func replace(inventory: ProjectionWindowInventory, generation: UInt64) -> Result<Void, ProjectionObservationFailure> {
        windowIds = Set(inventory.handles.map(\.windowId))
        if let nextFailure { return .failure(nextFailure) }
        return .success(())
    }
    func stop(generation: UInt64) { stops += 1; windowIds.removeAll() }
    func emit(_ kind: AccessibilityFocusEventKind, pid: pid_t, generation: UInt64,
              element: AXUIElement?, windowId: Int64?, windowGeneration: UInt64 = 0) {
        onEvent?(AccessibilityFocusEvent(kind: kind, pid: pid, generation: generation,
            windowGeneration: windowGeneration, element: element, windowId: windowId, isWorldObservation: true))
    }
}

private final class TargetedFeedTrustFixture: @unchecked Sendable {
    var trusted = true
}

private final class TargetedFeedSessionFixture: @unchecked Sendable {
    let available = ResidentAtomic(true)
    let generation = ResidentAtomic<UInt64>(0)
    private let transitionInjected = ResidentAtomic(false)
    func lock() {
        available.store(false, ordering: .releasing)
        generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }
    func unlock() {
        generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        available.store(true, ordering: .releasing)
    }
    func injectLockUnlockOnce() {
        guard !transitionInjected.exchange(true, ordering: .acquiringAndReleasing) else { return }
        lock(); unlock()
    }
}

private final class TargetedLifetimeFixture {
    let reader: TargetedFeedWindowFixture
    let spaces: TargetedFeedSpaceFixture
    let worldObserver = TargetedFeedWorldObserverFixture()
    let trust = TargetedFeedTrustFixture()
    let session = TargetedFeedSessionFixture()
    let observer = FakeAccessibilityObserver()
    let operations = ManualExecutor()
    let deliveries = FeedDeliveryFixture()
    let snapshots: TargetedProjectionSnapshot
    let feed: ProjectionInputFeed
    let id: Int64
    let pid: pid_t
    var app: ProjectionApplication { .init(pid: pid, name: "Lifetime fixture") }
    var token: UInt64? { snapshots.windowGenerations[String(id)] }

    init(_ rows: [JSONValue], core: CoreServer? = nil) {
        reader = TargetedFeedWindowFixture(rows)
        spaces = TargetedFeedSpaceFixture(rows)
        id = reader.records.keys.min()!
        pid = reader.records[id]!.pid
        let reader = reader, trust = trust, spaces = spaces, worldObserver = worldObserver, session = session
        snapshots = TargetedProjectionSnapshot(trusted: { trust.trusted }, reader: reader,
            spaces: spaces, worldObserver: worldObserver, identityIsCurrent: { reader.isCurrent($0) },
            elementsMatch: { ObjectIdentifier($0) == ObjectIdentifier($1) },
            sessionAvailable: { session.available.load(ordering: .acquiring) },
            sessionGeneration: { session.generation.load(ordering: .acquiring) })
        let snapshots = snapshots, operations = operations, deliveries = deliveries
        feed = ProjectionInputFeed(observer: observer, captureTargeted: { snapshots.capture($0) },
            executeOnObservationLane: { operations.enqueue($0) }, onHealthChanged: { core?.updateFocusObserverHealth($0) },
            deliver: { deliveries.append($0); _ = core?.applyWorldDelta($0) })
        let feed = feed
        snapshots.onWorldEvent = { feed.worldAccessibilityEvent($0) }
        feed.start(frontmost: app)
    }

    func recover() { feed.spaceChanged(frontmost: app) }
    func refuses(_ token: UInt64) -> Bool {
        if case .failure(let failure) = snapshots.resolveWindow(windowId: id,
            observerGeneration: feed.currentGeneration, expectedWindowGeneration: token) {
            return failure.code == "window_resolver_lifetime_generation_mismatch"
        }
        return false
    }
    func finish() { feed.stop(); snapshots.stop() }
}

private func targetedLifetimePlannerWorld(_ scenario: TargetedLifetimeFixture, fixture: JSONValue) -> JSONValue {
    let windows = (scenario.deliveries.all.last?["windows"]?.arrayValue ?? []).map { window -> JSONValue in
        var record = window.objectValue!
        record["display"] = .int(1)
        record["display_id"] = .int(1)
        record["space_uuid"] = fixture.at(path: "context.space_uuid")
        record["space_identity_available"] = .bool(true)
        return .object(record)
    }
    return .object(["complete": .bool(true), "trusted": .bool(true),
        "observer_epoch": fixture.at(path: "observer_epoch")!, "observer_generation": .int(Int64(scenario.feed.currentGeneration)),
        "topology_revision": .int(1), "topology": fixture.at(path: "topology")!,
        "space_contexts": .array([fixture.at(path: "context")!]), "windows": .array(windows),
        "space_enabled": .bool(true), "active_space_key": fixture.at(path: "context.space_key")!,
        "focused_window_id": .int(scenario.id)])
}

/// A Mission Control move reaches the resident only as a window-server Space
/// notification. A cached window now on another Space admits one sweep through
/// the production feed; creation and destruction stay with the AX lifecycle.
private func runTargetedProjectionWindowSpaceScenarios(rows: [JSONValue], test: inout SelfTest) {
    let core = CoreServer(socketPath: selfTestSocketPath("leylined-window-space"))
    let scenario = TargetedLifetimeFixture(rows, core: core)
    let moved = scenario.reader.records.keys.max()!
    let origin = scenario.spaces.contexts[moved]!
    let tokens = scenario.snapshots.windowGenerations
    test.check(!scenario.snapshots.windowChangedSpace(windowId: moved)
        && !scenario.snapshots.windowChangedSpace(windowId: moved + 1_000),
        "window-space/unchanged-or-uncached-window-owes-no-sweep")
    scenario.spaces.contexts[moved] = nil
    test.check(!scenario.snapshots.windowChangedSpace(windowId: moved),
        "window-space/window-on-no-space-is-left-to-the-ax-lifecycle")
    scenario.spaces.unbaselined = [moved]
    test.check(scenario.snapshots.windowChangedSpace(windowId: moved),
        "window-space/window-on-a-space-created-after-the-baseline-owes-a-sweep")
    scenario.spaces.unbaselined = []

    let elsewhere = "space:uuid:window-space-elsewhere"
    scenario.spaces.contexts[moved] = .init(key: elsewhere, displayId: origin.displayId, visible: false)
    let record = scenario.reader.records[moved]!
    scenario.reader.records[moved] = TargetedWindowObservation(windowId: moved, pid: record.pid, frame: record.frame,
        role: record.role, subrole: record.subrole, title: record.title, resizable: record.resizable,
        movable: record.movable, minimized: false, onscreen: false)
    let inventories = scenario.reader.inventoryCalls
    let owed = scenario.snapshots.windowChangedSpace(windowId: moved)
    scenario.feed.windowSpaceChanged(frontmost: scenario.app)
    let delivered = scenario.deliveries.all.last
    let row = delivered?["windows"]?.arrayValue?.first { $0.at(path: "window_id")?.intValue == moved }
    test.check(owed && delivered?["event"]?.stringValue == "window_space_changed"
        && scenario.reader.inventoryCalls == inventories + 1
        && row?.at(path: "space_key")?.stringValue == elsewhere && row?.at(path: "space_visible")?.boolValue == false
        && row?.at(path: "managed")?.boolValue == false
        && core.worldState.at(path: "event")?.stringValue == "window_space_changed"
        && core.worldState.at(path: "observation.world_complete")?.boolValue == true
        && scenario.snapshots.windowGenerations == tokens,
        "window-space/window-on-another-space-sweeps-into-core-and-keeps-lifetimes")
    test.check(!scenario.snapshots.windowChangedSpace(windowId: moved),
        "window-space/second-notification-of-the-same-move-owes-nothing")
    scenario.finish()
}

/// App activation enters through the production feed and publishes into the
/// actual core. Only AX inventory/identity and notification backends are fake.
private func runTargetedProjectionActivationScenarios(rows: [JSONValue], test: inout SelfTest) {
    let core = CoreServer(socketPath: selfTestSocketPath("leylined-activation"))
    let active = TargetedLifetimeFixture(rows, core: core)
    let before = active.snapshots.windowGenerations
    let source = active.worldObserver.activeGeneration
    let initialInventories = active.reader.inventoryCalls
    active.feed.applicationActivated(active.app)
    test.check(active.snapshots.windowGenerations == before && active.reader.inventoryCalls == initialInventories
        && active.worldObserver.activeGeneration == source
        && core.worldState.at(path: "observation.world_recovered")?.boolValue == false
        && core.worldState.at(path: "observation.world_complete")?.boolValue == true,
        "targeted-activation/healthy-feed-rebind-preserves-world-source-and-tokens-without-enumeration")

    let staleId = active.reader.records.keys.max()!
    let staleToken = before[String(staleId)]!
    let oldElement = active.reader.elements[staleId]!
    let reads = active.reader.readIds.count
    let baselines = active.spaces.baselineCalls
    active.reader.reuseWindowId(staleId)
    active.feed.applicationActivated(active.app)
    let restored = active.snapshots.windowGenerations
    test.check(active.reader.inventoryCalls == initialInventories + 1 && active.spaces.baselineCalls == baselines + 1
        && active.reader.readIds.count == reads + rows.count + 1
        && core.worldState.at(path: "observation.world_complete")?.boolValue == true
        && core.worldState.at(path: "windows")?.arrayValue?.count == rows.count
        && active.worldObserver.activeGeneration == source,
        "targeted-activation/stale-background-handle-drives-one-complete-current-membership-observation")
    test.check(restored[String(active.id)] == before[String(active.id)] && (restored[String(staleId)] ?? 0) > staleToken,
        "targeted-activation/unvalidated-member-is-newcomer-and-continuously-valid-member-keeps-token")
    let observation = core.worldState.at(path: "observation")!
    let retired = observation.at(path: "retired_window_identities")?.arrayValue ?? []
    test.check(retired.count == 1 && retired[0].at(path: "window_id")?.intValue == staleId
        && retired[0].at(path: "pid")?.intValue == Int64(active.pid)
        && retired[0].at(path: "window_generation")?.intValue == Int64(staleToken)
        && observation.at(path: "world_recovery_reason")?.stringValue?.hasPrefix("ax_retained_window_identity_unavailable:") == true
        && observation.at(path: "inventory_is_cached")?.boolValue == false
        && observation.at(path: "world_recovered")?.boolValue == true
        && observation.at(path: "target_read_performed")?.boolValue == false,
        "targeted-activation/recovery-reports-exact-retired-identity-without-fabricating-notification-evidence")
    let refusal = active.snapshots.resolveWindow(windowId: staleId, observerGeneration: active.feed.currentGeneration,
        expectedWindowGeneration: staleToken)
    test.check({ if case .failure(let failure) = refusal { return failure.code == "window_resolver_lifetime_generation_mismatch" }; return false }(),
        "targeted-activation/old-background-effect-token-cannot-resolve-recovered-same-pid-id")
    active.worldObserver.emit(.focusedWindowDestroyed, pid: active.pid, generation: source, element: oldElement, windowId: staleId)
    active.operations.runOne()
    test.check(active.snapshots.windowGenerations == restored
        && core.worldState.at(path: "observation.world_complete")?.boolValue == true,
        "targeted-activation/old-retained-element-callback-cannot-destroy-refreshed-member")
    active.finish()

    let failedCore = CoreServer(socketPath: selfTestSocketPath("leylined-activation-failure"))
    let failed = TargetedLifetimeFixture(rows, core: failedCore)
    let oldTokens = failed.snapshots.windowGenerations
    let failingId = failed.reader.records.keys.max()!
    failed.reader.reuseWindowId(failingId)
    failed.reader.inventoryFailure = .init(code: "fixture_activation_inventory_failure")
    failed.feed.applicationActivated(failed.app)
    test.check(failed.reader.inventoryCalls == 2 && failed.operations.pending == 0
        && failed.snapshots.windowGenerations.isEmpty && failedCore.worldState.at(path: "focus") == .null
        && failedCore.worldState.at(path: "observation.ready")?.boolValue == false
        && failedCore.worldState.at(path: "observation.world_complete")?.boolValue == false
        && failedCore.worldState.at(path: "observation.world_recovered")?.boolValue == false
        && failedCore.worldState.at(path: "observation.world_failure_code")?.stringValue == "fixture_activation_inventory_failure",
        "targeted-activation/failed-current-inventory-stays-unavailable-without-retries-or-focused-read-resurrection")
    failed.reader.inventoryFailure = nil
    failed.feed.applicationActivated(failed.app)
    test.check(failed.reader.inventoryCalls == 3
        && failedCore.worldState.at(path: "observation.world_complete")?.boolValue == true
        && failed.snapshots.windowGenerations.allSatisfy { key, token in token > oldTokens[key]! },
        "targeted-activation/later-independent-activation-restores-authority-with-new-tokens-after-coverage-loss")
    failed.finish()

    let degraded = TargetedLifetimeFixture(rows)
    let expectedTokens = degraded.snapshots.windowGenerations
    degraded.observer.nextHealth = .degraded(pid: degraded.pid, generation: degraded.feed.currentGeneration + 1,
        reason: "ax_focus_registration_failed:-25204")
    degraded.feed.applicationActivated(degraded.app)
    test.check(degraded.snapshots.windowGenerations == expectedTokens && degraded.reader.inventoryCalls == 1
        && degraded.deliveries.all.last?["focus_observer_ready"]?.boolValue == false
        && degraded.deliveries.all.last?["focus_observer_degraded_reason"]?.stringValue == "ax_focus_registration_failed:-25204",
        "targeted-activation/foreground-registration-failure-remains-explicit-without-downgrading-valid-world-identities")
    degraded.finish()
}

/// Actual activation/feed/provider pipeline. AX/CG inventory and lifecycle
/// backends are fixtures; no focus setters, live AX calls or pixel matching.
private func runTargetedIgnoredRetainedHandleScenarios(rows: [JSONValue], test: inout SelfTest) {
    let path = SelfTestFixtures.url("feed/ignored-retained-identity.json")
    guard let data = try? Data(contentsOf: path), let proof = try? JSONValue.parse(data),
          let cases = proof.at(path: "unsafe_cases")?.arrayValue?.compactMap(\.stringValue), cases.count == 11 else {
        test.check(false, "ignored-retained/nonvacuous-fixture"); return
    }
    var ignored = rows[0].objectValue!
    let ignoredId = (rows.map { $0.at(path: "window_id")!.intValue! }.max() ?? 0) + 100
    ignored["window_id"] = .int(ignoredId); ignored["subrole"] = proof.at(path: "ignored_subrole")
    let positive = TargetedLifetimeFixture(rows + [.object(ignored)])
    positive.reader.supportsCacheAudit = true
    let before = positive.snapshots.windowGenerations, source = positive.worldObserver.activeGeneration
    let begins = positive.worldObserver.begins, stops = positive.worldObserver.stops, baselines = positive.spaces.baselineCalls
    positive.reader.records.removeValue(forKey: ignoredId); positive.reader.elements.removeValue(forKey: ignoredId)
    positive.feed.applicationActivated(positive.app)
    let observation = positive.deliveries.all.last?["observation"]
    test.check(observation?.at(path: "world_complete")?.boolValue == true
        && observation?.at(path: "world_recovered")?.boolValue == false
        && observation?.at(path: "ignored_retained_window_ids")?.arrayValue == [.int(ignoredId)]
        && observation?.at(path: "ignored_retained_cohort_validation_performed")?.boolValue == true
        && observation?.at(path: "inventory_is_cached")?.boolValue == false,
        "ignored-retained/dead-positive-dialog-retires-only-after-live-cohort-conservation-proof")
    test.check(rows.allSatisfy { positive.snapshots.windowGenerations[String($0.at(path: "window_id")!.intValue!)]
            == before[String($0.at(path: "window_id")!.intValue!)] }
        && positive.snapshots.windowGenerations[String(ignoredId)] == nil
        && positive.worldObserver.activeGeneration == source && positive.worldObserver.begins == begins
        && positive.worldObserver.stops == stops && positive.spaces.baselineCalls == baselines,
        "ignored-retained/healthy-managed-handles-keep-lifetimes-and-continuous-notification-source")
    let live = positive.snapshots.resolveWindow(windowId: positive.id, observerGeneration: positive.feed.currentGeneration,
        expectedWindowGeneration: before[String(positive.id)])
    test.check({ if case .success = live { return true }; return false }()
        && positive.deliveries.all.last?["focus"]?.at(path: "window_generation")?.intValue == Int64(before[String(positive.id)]!),
        "ignored-retained/issued-original-managed-token-still-resolves-and-focused-read-is-fresh")
    positive.finish()
    for name in cases {
        var specimen = ignored
        if name == "unknown" { specimen["subrole"] = .string("AXUnknown") }
        if name == "standard" { specimen["subrole"] = .string("AXStandardWindow") }
        let scenario = TargetedLifetimeFixture(rows + [.object(specimen)])
        scenario.reader.supportsCacheAudit = true
        let prior = scenario.snapshots.windowGenerations
        scenario.reader.records.removeValue(forKey: ignoredId); scenario.reader.elements.removeValue(forKey: ignoredId)
        let handles = scenario.reader.records.keys.sorted().map { id in
            ProjectionWindowHandle(element: scenario.reader.elements[id]!, pid: scenario.reader.records[id]!.pid, windowId: id)
        }
        let owners = Set(handles.map(\.pid)), ids = Set(handles.map(\.windowId))
        switch name {
        case "duplicate": scenario.reader.retirementInventoryOverride = .init(handles: handles + [handles[0]], visibleWindowIds: ids, ownerPids: owners)
        case "pid":
            var changed = handles; changed[0] = .init(element: handles[0].element, pid: handles[0].pid + 1, windowId: handles[0].windowId)
            scenario.reader.retirementInventoryOverride = .init(handles: changed, visibleWindowIds: ids, ownerPids: owners)
        case "space", "display":
            let old = scenario.spaces.contexts[scenario.id]!
            scenario.spaces.contexts[scenario.id] = .init(key: name == "space" ? "space:changed" : old.key,
                displayId: name == "display" ? "display:changed" : old.displayId, visible: true)
        case "visible_missing": scenario.reader.retirementInventoryOverride = .init(handles: handles, visibleWindowIds: ids.subtracting([scenario.id]), ownerPids: owners)
        case "visible_retired_id": scenario.reader.retirementInventoryOverride = .init(handles: handles, visibleWindowIds: ids.union([ignoredId]), ownerPids: owners,
            ignoredWindowIds: [ignoredId])
        case "inventory": scenario.reader.inventoryFailure = .init(code: "fixture_ignored_retirement_inventory_unavailable")
        case "new_managed":
            let id = ignoredId + 1, old = scenario.reader.records[scenario.id]!
            scenario.reader.records[id] = .init(windowId: id, pid: old.pid, frame: old.frame, role: "AXWindow", subrole: "AXStandardWindow",
                title: "New member", resizable: true, movable: true, minimized: false, onscreen: true)
            scenario.reader.elements[id] = AXUIElementCreateApplication(old.pid)
            scenario.spaces.contexts[id] = scenario.spaces.contexts[scenario.id]
        case "coverage": scenario.worldObserver.nextFailure = .init(code: "fixture_ignored_retirement_registration_failure")
        default: break
        }
        scenario.feed.applicationActivated(scenario.app)
        let after = scenario.snapshots.windowGenerations
        let attemptedSafeRetirement = scenario.deliveries.all.last?["observation"]?.at(path: "ignored_retained_window_ids") != nil
        let fenced = name == "standard" ? after[String(ignoredId)] == nil
            : rows.allSatisfy { let key = String($0.at(path: "window_id")!.intValue!); return after[key] == nil || after[key]! > prior[key]! }
        test.check(fenced && (name == "coverage" || !attemptedSafeRetirement),
            "ignored-retained/\(name)-cannot-grant-managed-survivor-exemption")
        scenario.finish()
    }
}

/// Independent failure/reuse/recovery episodes drive actual resolver and cached
/// partition admission. Every episode starts with nonzero lifetime authority.
private func runTargetedProjectionLifetimeScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.url("feed/lifetime-scenes.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let rows = fixture.at(path: "windows")?.arrayValue, rows.count == 2 else {
        test.check(false, "targeted-lifetime/nonvacuous-fixture-load"); return
    }
    runTargetedProjectionActivationScenarios(rows: rows, test: &test)
    runTargetedProjectionWindowSpaceScenarios(rows: rows, test: &test)
    runTargetedIgnoredRetainedHandleScenarios(rows: rows, test: &test)
    for gap in ["baseline", "inventory", "observer", "trust", "off"] {
        let scenario = TargetedLifetimeFixture(rows)
        guard let old = scenario.token, old > 0 else {
            test.check(false, "targeted-lifetime/\(gap)-positive-baseline-token"); scenario.finish(); continue
        }
        let source = scenario.worldObserver.activeGeneration
        let world = targetedLifetimePlannerWorld(scenario, fixture: fixture)
        let seed = ResidentPlanner.plan(actionID: "world.reconcile", state: .object([:]), world: world)
        let started = ResidentPlanner.plan(actionID: "resize.start", state: seed.state, world: world)
        let manual = ResidentPlanner.plan(actionID: "resize.adjust.east", state: started.state, world: world)
        let stopped = ResidentPlanner.plan(actionID: "resize.off", state: manual.state, world: world)
        test.check(seed.status == .accepted && manual.status == .accepted
            && stopped.state.at(path: "space_partitions.partitions.1:fixture-a.arrangement.segments")?.arrayValue?.first?.at(path: "coord")?.numberValue
                == fixture.at(path: "manual_divider")?.numberValue, "targeted-lifetime/\(gap)-manual-cache-has-old-token-and-authored-geometry")
        switch gap {
        case "baseline": scenario.spaces.unavailable = true; scenario.recover(); scenario.spaces.unavailable = false
        case "inventory": scenario.reader.inventoryFailure = .init(code: "fixture_inventory_failure"); scenario.recover(); scenario.reader.inventoryFailure = nil
        case "observer":
            scenario.worldObserver.emit(.worldObserverDegraded, pid: scenario.pid, generation: source, element: nil, windowId: nil)
            scenario.operations.runOne()
        case "trust": scenario.trust.trusted = false; scenario.feed.trustChanged(frontmost: scenario.app); scenario.trust.trusted = true
        default: scenario.snapshots.stop()
        }
        test.check(scenario.snapshots.windowGenerations.isEmpty && scenario.worldObserver.windowIds.isEmpty,
            "targeted-lifetime/\(gap)-coverage-gap-retires-all-cached-and-uncached-tokens")
        scenario.reader.reuseWindowId(scenario.id)
        scenario.recover()
        let renewed = scenario.token ?? 0
        test.check(renewed > old && scenario.refuses(old),
            "targeted-lifetime/\(gap)-same-pid-reused-id-recovery-refuses-old-effect-token")
        let recoveredWorld = targetedLifetimePlannerWorld(scenario, fixture: fixture)
        let command = ResidentPlanner.plan(actionID: "resize.start", state: stopped.state, world: recoveredWorld)
        let reconciled = ResidentPlanner.plan(actionID: "world.reconcile", state: stopped.state, world: recoveredWorld)
        test.check(command.status == .refused && command.state == stopped.state && command.targets == .object([:])
            && reconciled.status == .accepted
            && reconciled.state.at(path: "space_partitions.partitions.1:fixture-a.window_identities")?.objectValue?[String(scenario.id)]?.at(path: "window_generation")?.intValue == Int64(renewed)
            && reconciled.state.at(path: "space_partitions.partitions.1:fixture-a.arrangement")
                != stopped.state.at(path: "space_partitions.partitions.1:fixture-a.arrangement"),
            "targeted-lifetime/\(gap)-cached-old-layout-refuses-command-and-reinserts-newcomer")
        let deliveries = scenario.deliveries.all.count
        scenario.worldObserver.emit(.focusedWindowDestroyed, pid: scenario.pid, generation: source,
            element: scenario.reader.elements[scenario.id], windowId: scenario.id)
        test.check(scenario.operations.pending == 0 && scenario.deliveries.all.count == deliveries && scenario.token == renewed,
            "targeted-lifetime/\(gap)-old-concrete-source-callback-cannot-enter-recovered-feed")
        scenario.finish()
    }

    let continuous = TargetedLifetimeFixture(rows)
    let initial = continuous.token!
    let oldSource = continuous.worldObserver.activeGeneration
    let begins = continuous.worldObserver.begins, stops = continuous.worldObserver.stops
    continuous.feed.applicationActivated(continuous.app)
    test.check(continuous.token == initial && continuous.worldObserver.begins == begins && continuous.worldObserver.stops == stops,
        "targeted-lifetime/ordinary-app-rebind-retains-concrete-all-app-lifecycle-source")
    let receipt = fixture.requiredUInt64("receipt_uptime_ns")
    continuous.worldObserver.onEvent?(AccessibilityFocusEvent(kind: .focusedWindowMoved, pid: continuous.pid,
        generation: oldSource, element: continuous.reader.elements[continuous.id], windowId: continuous.id, receiptUptimeNs: receipt,
        isWorldObservation: true))
    continuous.operations.runOne()
    let observation = continuous.deliveries.all.last?["observation"]
    test.check(continuous.token == initial && observation?.at(path: "source_observer_generation")?.intValue == Int64(oldSource)
        && observation?.at(path: "admission_observer_generation")?.intValue == Int64(continuous.feed.currentGeneration)
        && observation?.at(path: "target_receipt_uptime_ns")?.intValue == Int64(receipt)
        && observation?.at(path: "source_receipt_uptime_ns")?.intValue == Int64(receipt),
        "targeted-lifetime/retained-source-callback-preserves-source-generation-and-original-receipt")
    continuous.recover()
    test.check(continuous.token == initial && continuous.worldObserver.activeGeneration == oldSource,
        "targeted-lifetime/validated-space-recovery-preserves-continuously-observed-handle")
    let oldElement = continuous.reader.elements[continuous.id]!
    continuous.reader.reuseWindowId(continuous.id)
    continuous.worldObserver.emit(.windowCreated, pid: continuous.pid, generation: oldSource,
        element: continuous.reader.elements[continuous.id], windowId: continuous.id)
    continuous.operations.runOne()
    let recreated = continuous.token!
    continuous.worldObserver.emit(.focusedWindowDestroyed, pid: continuous.pid, generation: oldSource,
        element: oldElement, windowId: continuous.id)
    continuous.operations.runOne()
    test.check(recreated > initial && continuous.token == recreated
        && continuous.deliveries.all.last?["observation"]?.at(path: "failure_code")?.stringValue == "lifecycle_notification_identity_mismatch",
        "targeted-lifetime/late-destroyed-old-element-does-not-retire-same-id-new-window")
    continuous.reader.identityAvailable = false
    continuous.recover()
    continuous.reader.identityAvailable = true
    continuous.recover()
    test.check((continuous.token ?? 0) > recreated && continuous.refuses(recreated),
        "targeted-lifetime/recovery-with-unvalidated-old-handle-allocates-newcomer-token")
    continuous.finish()

    let inactive = TargetedLifetimeFixture(rows)
    let inactiveToken = inactive.token!
    let record = inactive.reader.records.removeValue(forKey: inactive.id)!
    inactive.recover()
    inactive.reader.records[inactive.id] = record
    inactive.reader.reuseWindowId(inactive.id)
    inactive.recover()
    test.check((inactive.token ?? 0) > inactiveToken && inactive.refuses(inactiveToken),
        "targeted-lifetime/window-absent-during-inactive-space-gap-cannot-resurrect-cached-token")
    inactive.finish()
}

/// Session changes retire the real snapshot provider's authority independently
/// of AX permission. Injected windows/Spaces expose every attempted read.
private func runTargetedProjectionSessionScenarios(test: inout SelfTest) {
    let fixtureRoot = SelfTestFixtures.url("feed")
    guard let windowData = try? Data(contentsOf: fixtureRoot.appendingPathComponent("lifetime-scenes.json")),
          let fixture = try? JSONValue.parse(windowData), let rows = fixture.at(path: "windows")?.arrayValue,
          rows.count == 2,
          let sessionData = try? Data(contentsOf: fixtureRoot.appendingPathComponent("session-scenes.json")),
          let sessions = try? JSONValue.parse(sessionData),
          let initialCases = sessions.at(path: "initial_cases")?.arrayValue, !initialCases.isEmpty,
          let pid = rows.first?.at(path: "pid")?.intValue,
          let id = rows.first?.at(path: "window_id")?.intValue else {
        test.check(false, "targeted-session/nonvacuous-fixtures-load"); return
    }
    for row in initialCases {
        let actual = coreSessionInitiallyAvailable(locked: row.at(path: "locked")?.boolValue,
            onConsole: row.at(path: "on_console")?.boolValue, loginDone: row.at(path: "login_done")?.boolValue,
            loginWindowForeground: row.at(path: "loginwindow_foreground")?.boolValue ?? true)
        test.check(actual == row.at(path: "expected_available")?.boolValue,
            "targeted-session/initial-\(row.at(path: "name")?.stringValue ?? "unknown")")
    }

    let initiallyLocked = TargetedFeedSessionFixture()
    initiallyLocked.lock()
    let reader = TargetedFeedWindowFixture(rows)
    let spaces = TargetedFeedSpaceFixture(rows)
    let observer = TargetedFeedWorldObserverFixture()
    let provider = TargetedProjectionSnapshot(trusted: { true }, reader: reader, spaces: spaces,
        worldObserver: observer, identityIsCurrent: { reader.isCurrent($0) },
        sessionAvailable: { initiallyLocked.available.load(ordering: .acquiring) },
        sessionGeneration: { initiallyLocked.generation.load(ordering: .acquiring) })
    provider.setUsableDisplayFrames([:])
    let locked = provider.capture(.init(reason: "world_seed", application: .init(pid: pid_t(pid), name: "Fixture"),
        observerGeneration: 1, accessibilityEvent: nil))
    test.check(reader.inventoryCalls == 0 && reader.focusCalls == 0 && reader.readIds.isEmpty
        && reader.identityChecks == 0 && spaces.baselineCalls == 0 && spaces.contextCalls == 0
        && spaces.currentContextCalls == 0 && observer.begins == 0
        && locked.observation["display_enumeration_count"] == .int(0),
        "targeted-session/initial-locked-provider-performs-zero-AX-CG-Space-enumerations-or-reads")
    test.check(locked.focus == .null && locked.windows.isEmpty && locked.topology.isEmpty
        && locked.activeContext == .null && locked.spaceContexts.isEmpty
        && locked.observation["failure_code"] == .string("session_locked")
        && locked.observation["world_failure_code"] == .string("session_locked")
        && locked.observation["world_complete"] == .bool(false),
        "targeted-session/locked-world-is-typed-unavailable-and-never-an-empty-complete-world")
    var lockedResolver = false
    if case .failure(let failure) = provider.resolveWindow(windowId: id, observerGeneration: 1) {
        lockedResolver = failure.code == "session_locked"
    }
    var lockedReadback = false
    if case .failure(let failure) = provider.readWindow(windowId: id, observerGeneration: 1) {
        lockedReadback = failure.code == "session_locked"
    }
    test.check(lockedResolver && lockedReadback && reader.readIds.isEmpty && reader.identityChecks == 0
        && spaces.contextCalls == 0 && provider.windowGenerations.isEmpty,
        "targeted-session/locked-resolver-and-readback-refuse-before-any-stale-handle-read")
    initiallyLocked.unlock()
    let recovered = provider.capture(.init(reason: "wake_recovery", application: .init(pid: pid_t(pid), name: "Fixture"),
        observerGeneration: 2, accessibilityEvent: nil))
    test.check(recovered.observation["world_complete"] == .bool(true)
        && recovered.observation["failure_code"] == .null && recovered.windows.count == rows.count
        && reader.inventoryCalls == 1 && spaces.baselineCalls == 1 && observer.begins == 1,
        "targeted-session/unlock-recovery-obtains-a-fresh-window-and-Space-baseline")
    provider.stop()

    let active = TargetedLifetimeFixture(rows)
    let oldToken = active.token ?? 0, oldSource = active.worldObserver.activeGeneration
    let oldReads = active.reader.readIds.count, oldInventories = active.reader.inventoryCalls
    let oldFocusReads = active.reader.focusCalls, oldIdentities = active.reader.identityChecks
    let oldBaselines = active.spaces.baselineCalls, oldContexts = active.spaces.contextCalls
    let oldCurrentContexts = active.spaces.currentContextCalls
    let oldDisplayEnumerations = active.deliveries.all.last?["observation"]?.at(path: "display_enumeration_count")
    active.session.lock()
    active.snapshots.sessionUnavailable()
    active.feed.trustChanged(frontmost: nil)
    active.snapshots.setUsableDisplayFrames([:])
    active.feed.wake(frontmost: active.app)
    test.check(oldToken > 0 && active.token == nil && active.worldObserver.windowIds.isEmpty
        && active.reader.readIds.count == oldReads && active.reader.inventoryCalls == oldInventories
        && active.reader.focusCalls == oldFocusReads && active.reader.identityChecks == oldIdentities
        && active.spaces.baselineCalls == oldBaselines && active.spaces.contextCalls == oldContexts
        && active.spaces.currentContextCalls == oldCurrentContexts
        && active.deliveries.all.last?["observation"]?.at(path: "display_enumeration_count") == oldDisplayEnumerations,
        "targeted-session/lock-retires-positive-authority-and-repeated-events-perform-zero-new-reads")
    active.session.unlock()
    active.feed.wake(frontmost: active.app)
    test.check((active.token ?? 0) > oldToken && active.refuses(oldToken)
        && active.reader.inventoryCalls == oldInventories + 1 && active.spaces.baselineCalls == oldBaselines + 1,
        "targeted-session/unlock-renews-lifetimes-and-denies-every-pre-lock-effect-token")
    let deliveries = active.deliveries.all.count
    active.worldObserver.emit(.focusedWindowDestroyed, pid: active.pid, generation: oldSource,
        element: active.reader.elements[active.id], windowId: active.id)
    test.check(active.operations.pending == 0 && active.deliveries.all.count == deliveries,
        "targeted-session/pre-lock-source-callback-cannot-enter-unlocked-recovery")
    active.finish()

    let spanningCapture = TargetedLifetimeFixture(rows)
    let session = spanningCapture.session
    spanningCapture.reader.beforeRead = { session.injectLockUnlockOnce() }
    spanningCapture.feed.wake(frontmost: spanningCapture.app)
    test.check(spanningCapture.snapshots.windowGenerations.isEmpty
        && spanningCapture.deliveries.all.last?["observation"]?.at(path: "failure_code") == .string("session_locked")
        && spanningCapture.deliveries.all.last?["observation"]?.at(path: "world_complete") == .bool(false),
        "targeted-session/capture-spanning-lock-unlock-rejects-old-session-despite-active-boolean")
    spanningCapture.reader.beforeRead = nil
    spanningCapture.feed.wake(frontmost: spanningCapture.app)
    test.check(spanningCapture.token != nil
        && spanningCapture.deliveries.all.last?["observation"]?.at(path: "world_complete") == .bool(true),
        "targeted-session/next-fresh-capture-recovers-after-spanning-read-was-rejected")
    spanningCapture.finish()

    let spanningResolver = TargetedLifetimeFixture(rows)
    let resolverSession = spanningResolver.session
    spanningResolver.reader.beforeIdentityCheck = { resolverSession.injectLockUnlockOnce() }
    let contextReads = spanningResolver.spaces.contextCalls
    var staleResolverRefused = false
    if case .failure(let failure) = spanningResolver.snapshots.resolveWindow(windowId: spanningResolver.id,
        observerGeneration: spanningResolver.feed.currentGeneration, expectedWindowGeneration: spanningResolver.token) {
        staleResolverRefused = failure.code == "session_locked"
    }
    test.check(staleResolverRefused && spanningResolver.snapshots.windowGenerations.isEmpty
        && spanningResolver.spaces.contextCalls == contextReads,
        "targeted-session/resolver-spanning-lock-unlock-refuses-before-new-Space-read")
    spanningResolver.finish()
}

/// Real feed/provider/core transitions with injectable OS reads. Fixture scenes
/// freeze warm six/stress twenty windows; counters are actual adapter invocations.
private func runTargetedEffectHandleRefreshScenarios(test: inout SelfTest) {
    let url = SelfTestFixtures.url("feed/effect-handle-refresh.json")
    guard let data = try? Data(contentsOf: url), let fixture = try? JSONValue.parse(data),
          let rows = fixture.at(path: "windows")?.arrayValue, rows.count == 2 else {
        test.check(false, "effect-handle-refresh/fixture-load"); return
    }
    test.check(fixture.at(path: "scenarios")?.arrayValue?.count == 8
        && fixture.at(path: "message_budget_ns")?.intValue == Int64(TargetedProjectionSnapshot.effectRefreshMessageBudgetNs)
        && fixture.at(path: "total_budget_ns")?.intValue == Int64(TargetedProjectionSnapshot.effectRefreshTotalBudgetNs),
        "effect-handle-refresh/nonempty-eight-scenario-fixture-with-one-hundred-ms-reserve-and-two-hundred-ms-total")
    let valid = TargetedLifetimeFixture(rows), token = valid.token!, gen = valid.feed.currentGeneration
    let source = valid.worldObserver.activeGeneration, inventory = valid.reader.inventoryCalls, before = valid.reader.readIds.count
    let identitiesBeforeRead = valid.reader.identityChecks, targetReadsBefore = valid.reader.readIds.count
    let paired = valid.snapshots.readWindowWithHandle(windowId: valid.id, observerGeneration: gen, expectedWindowGeneration: token)
    test.check({ if case .success(let value) = paired {
        return value.handle.windowId == valid.id && value.handle.pid == valid.pid
            && ObjectIdentifier(value.handle.element) == ObjectIdentifier(valid.reader.elements[valid.id]!)
            && value.observation == valid.reader.records[valid.id] && value.observerGeneration == gen
            && value.completedUptimeNs > 0
        }; return false }() && valid.reader.identityChecks == identitiesBeforeRead + 1
        && valid.reader.readIds.count == targetReadsBefore + 1,
        "effect-handle-refresh/canonical-read-pairs-exact-handle-and-observation-with-one-resolver-proof")
    let refreshed = valid.snapshots.refreshEffectWindow(windowId: valid.id, observerGeneration: gen, expectedWindowGeneration: token)
    let succeeded: Bool = { if case .success(let handle) = refreshed { return handle.windowId == valid.id && handle.pid == valid.pid }; return false }()
    test.check(succeeded && valid.token == token && valid.worldObserver.activeGeneration == source
        && valid.reader.readIds.count == before + 2 && valid.reader.freshQueries.count == 1
        && valid.reader.freshQueries[0].0 == valid.pid && valid.reader.freshQueries[0].1 == valid.id
        && valid.reader.inventoryCalls == inventory,
        "effect-handle-refresh/exact-owner-target-read-preserves-concrete-source-and-lifetime-without-full-enumeration")
    let telemetry = valid.snapshots.capture(.init(reason: "telemetry", application: valid.app, observerGeneration: gen, accessibilityEvent: nil))
    test.check(telemetry.observation["effect_handle_refresh_count"]?.intValue == 1
        && telemetry.observation["world_complete"]?.boolValue == true,
        "effect-handle-refresh/exceptional-owner-query-counter-is-separate-from-full-inventory")
    let noQuery = valid.reader.freshQueries.count
    let stale = valid.snapshots.refreshEffectWindow(windowId: valid.id, observerGeneration: gen + 1, expectedWindowGeneration: token)
    let reused = valid.snapshots.refreshEffectWindow(windowId: valid.id, observerGeneration: gen, expectedWindowGeneration: token + 999)
    test.check({ if case .failure(let error) = stale { return error.code == "window_resolver_generation_mismatch" }; return false }()
        && { if case .failure(let error) = reused { return error.code == "window_resolver_lifetime_generation_mismatch" }; return false }()
        && valid.reader.freshQueries.count == noQuery,
        "effect-handle-refresh/stale-observer-or-window-lifetime-refuses-before-owner-query")
    let element = valid.reader.elements[valid.id]!, exact = ProjectionWindowHandle(element: element, pid: valid.pid, windowId: valid.id)
    for (name, candidates) in [("missing", []), ("alias", [exact, exact]),
        ("foreign", [ProjectionWindowHandle(element: element, pid: valid.pid + 1, windowId: valid.id)]),
        ("unknown", [ProjectionWindowHandle(element: element, pid: valid.pid, windowId: 0)])] {
        test.check({ if case .failure = projectionUniqueFreshWindowHandle(candidates, pid: valid.pid, windowId: valid.id) { return true }; return false }(),
            "effect-handle-refresh/\(name)-candidate-cannot-replace-canonical-handle")
    }
    valid.reader.freshOverride = .success(.init(element: AXUIElementCreateApplication(valid.pid + 1), pid: valid.pid, windowId: valid.id))
    let unequal = valid.snapshots.refreshEffectWindow(windowId: valid.id, observerGeneration: gen, expectedWindowGeneration: token)
    test.check({ if case .failure(let error) = unequal { return error.code == "effect_refresh_registered_identity_changed" }; return false }()
        && valid.token == token, "effect-handle-refresh/matching-PID-ID-with-unequal-registered-wrapper-refuses-without-token-replacement")
    valid.reader.freshOverride = .failure(.init(code: "effect_fresh_handle_missing"))
    let missing = valid.snapshots.refreshEffectWindow(windowId: valid.id, observerGeneration: gen, expectedWindowGeneration: token)
    test.check({ if case .failure(let error) = missing { return error.code == "effect_fresh_handle_missing" }; return false }()
        && valid.token == token, "effect-handle-refresh/missing-fresh-target-never-falls-back-to-world-rebaseline")
    valid.finish()
    let locked = TargetedLifetimeFixture(rows), session = locked.session
    locked.reader.beforeRead = { session.injectLockUnlockOnce() }
    let sessionResult = locked.snapshots.refreshEffectWindow(windowId: locked.id, observerGeneration: locked.feed.currentGeneration,
                                                             expectedWindowGeneration: locked.token!)
    test.check({ if case .failure(let error) = sessionResult { return error.code == "session_locked" }; return false }()
        && locked.snapshots.windowGenerations.isEmpty, "effect-handle-refresh/read-crossing-lock-unlock-cannot-restore-old-lifetime")
    locked.finish()
    let moved = TargetedLifetimeFixture(rows), spaces = moved.spaces, id = moved.id
    moved.reader.beforeRead = { spaces.contexts[id] = .init(key: "space:uuid:elsewhere", displayId: "display-a", visible: true) }
    let movedResult = moved.snapshots.refreshEffectWindow(windowId: id, observerGeneration: moved.feed.currentGeneration,
                                                         expectedWindowGeneration: moved.token!)
    test.check({ if case .failure(let error) = movedResult { return error.code == "window_resolver_space_changed" }; return false }(),
        "effect-handle-refresh/fresh-read-Space-drift-is-refused-before-canonical-replacement")
    moved.finish()
    let aliasReader = TargetedFeedWindowFixture(rows), aliasSpaces = TargetedFeedSpaceFixture(rows)
    let aliasSnapshots = TargetedProjectionSnapshot(trusted: { true }, reader: aliasReader, spaces: aliasSpaces,
        worldObserver: TargetedFeedWorldObserverFixture(), identityIsCurrent: { _ in true },
        elementsMatch: { ObjectIdentifier($0) == ObjectIdentifier($1) })
    _ = aliasSnapshots.capture(.init(reason: "world_seed", application: .init(pid: 111, name: "Fixture"), observerGeneration: 1, accessibilityEvent: nil))
    let idToReuse = rows[0].at(path: "window_id")!.intValue!, oldAliasToken = aliasSnapshots.windowGenerations[String(idToReuse)]!
    aliasReader.reuseWindowId(idToReuse)
    _ = aliasSnapshots.capture(.init(reason: "explicit_recovery", application: .init(pid: 111, name: "Fixture"), observerGeneration: 2, accessibilityEvent: nil))
    test.check((aliasSnapshots.windowGenerations[String(idToReuse)] ?? 0) > oldAliasToken,
        "effect-handle-refresh/baseline-new-alias-cannot-inherit-lifetime-despite-valid-cached-PID-private-ID")
    aliasSnapshots.stop()
    let start: UInt64 = 1_000
    test.check(projectionEffectRefreshBudgetAllowsCall(started: start, now: start + 100_000_000)
        && !projectionEffectRefreshBudgetAllowsCall(started: start, now: start + 100_000_001)
        && !projectionEffectRefreshBudgetAllowsCall(started: start, now: start - 1),
        "effect-handle-refresh/whole-message-reserve-prevents-starting-a-call-that-can-overrun-total-budget")
}

func runTargetedProjectionScenarios(test: inout SelfTest) {
    runProjectionWindowAttributeBatchScenarios(test: &test)
    runSettledFrameRepairScenarios(test: &test)
    runTargetedEffectHandleRefreshScenarios(test: &test)
    runAccessibilityNotificationTargetScenarios(test: &test)
    runProjectionInventoryClassificationScenarios(test: &test)
    runProjectionNamedWindowDescriptionScenarios(test: &test)
    runProjectionWindowOnscreenScenarios(test: &test)
    let fixtureURL = SelfTestFixtures.url("feed/window-scenes.json")
    guard let data = try? Data(contentsOf: fixtureURL), let fixture = try? JSONValue.parse(data) else {
        test.check(false, "targeted-feed/frozen-warm-stress-scenes-missing")
        return
    }
    for name in ["warm", "stress"] {
        let rows = fixture.at(path: name)?.arrayValue ?? []
        let expectedCount = name == "warm" ? 6 : 20
        test.check(rows.count == expectedCount, "targeted-feed/\(name)-nonvacuous-scene")
        let reader = TargetedFeedWindowFixture(rows)
        let spaces = TargetedFeedSpaceFixture(rows)
        let worldObserver = TargetedFeedWorldObserverFixture()
        let trust = TargetedFeedTrustFixture()
        let snapshots = TargetedProjectionSnapshot(trusted: { trust.trusted }, reader: reader,
            spaces: spaces, spaceEnabled: { $0 == "space:uuid:fixture-a" }, worldObserver: worldObserver,
            identityIsCurrent: { _ in true })
        let observer = FakeAccessibilityObserver()
        let operations = ManualExecutor()
        let deliveries = FeedDeliveryFixture()
        let core = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/leylined-targeted-\(name)-\(getpid()).sock")
        let feed = ProjectionInputFeed(observer: observer, captureTargeted: { snapshots.capture($0) },
            executeOnObservationLane: { operations.enqueue($0) }, deliver: {
                deliveries.append($0)
                _ = core.applyWorldDelta($0)
            })
        snapshots.onWorldEvent = { feed.worldAccessibilityEvent($0) }
        guard let firstId = reader.records.keys.min(), let pid = reader.records[firstId]?.pid else {
            test.check(false, "targeted-feed/\(name)-identity-missing")
            continue
        }
        feed.start(frontmost: .init(pid: pid, name: "Fixture"))
        let bootstrapLifetimes = snapshots.windowGenerations
        test.check(reader.inventoryCalls == 1 && worldObserver.windowIds.count == expectedCount
            && deliveries.all.last?["observation"]?.at(path: "world_complete")?.boolValue == true
            && deliveries.all.last?["windows"]?.arrayValue?.count == expectedCount
            && deliveries.all.last?["windows"]?.arrayValue?.allSatisfy {
                $0.at(path: "space_identity_available")?.boolValue == true
                    && $0.at(path: "space_identity_source")?.stringValue == "window_server_space_uuid"
            } == true
            && core.currentRevision == 1, "targeted-feed/\(name)-complete-world-seed-is-observed-before-authority")
        test.check(bootstrapLifetimes.count == expectedCount && bootstrapLifetimes.values.allSatisfy { $0 > 0 },
            "targeted-feed/\(name)-bootstrap-allocates-positive-window-lifetime-tokens")
        let seedReads = reader.readIds.count
        let generation = feed.currentGeneration
        for (index, id) in reader.records.keys.sorted().enumerated() {
            reader.focusedId = id
            observer.emit(.focusedWindowChanged, pid: pid, generation: generation,
                windowGeneration: UInt64(index + 1), element: reader.elements[id], windowId: id)
            operations.runOne()
            reader.move(id, x: Double(index + 100))
            observer.emit(.focusedWindowMoved, pid: pid, generation: generation,
                windowGeneration: UInt64(index + 1), element: reader.elements[id], windowId: id)
            operations.runOne()
            observer.emit(.focusedWindowResized, pid: pid, generation: generation,
                windowGeneration: UInt64(index + 1), element: reader.elements[id], windowId: id)
            operations.runOne()
        }
        _ = core.applyModeFrame(.init(type: .snapshot, epoch: "targeted-\(name)", sequence: 0, mode: "default"))
        test.check(reader.inventoryCalls == 1 && spaces.baselineCalls == 1
            && reader.readIds.count - seedReads == expectedCount * 3
            && deliveries.all.last?["observation"]?.at(path: "full_enumeration_count")?.intValue == 1,
            "targeted-feed/\(name)-focus-move-resize-mode-do-not-enumerate")
        test.check(snapshots.windowGenerations == bootstrapLifetimes,
            "targeted-feed/\(name)-ordinary-notification-registration-tokens-do-not-change-window-lifetime")
        let lastId = reader.records.keys.max()!
        test.check(deliveries.all.last?["focus"]?.at(path: "window_id")?.intValue == lastId
            && deliveries.all.last?["focus"]?.at(path: "frame.x")?.numberValue == Double(expectedCount - 1 + 100)
            && deliveries.all.last?["notification_window_id"]?.intValue == lastId,
            "targeted-feed/\(name)-notification-target-is-exact-with-final-burst-frame")
        let exactReceipt = deliveries.all.last?["observation_receipt_uptime_ns"]?.intValue ?? 0
        let exactRead = deliveries.all.last?["observation_completed_uptime_ns"]?.intValue ?? 0
        test.check(deliveries.all.last?["observation_window_id"]?.intValue == lastId
            && exactReceipt > 0 && exactRead >= exactReceipt
            && deliveries.all.last?["focus"]?.at(path: "observed_uptime_ns")?.intValue == exactRead,
            "targeted-feed/\(name)-fresh-target-provenance-binds-receipt-read-and-window")
        let readsBeforeTelemetry = reader.readIds.count
        let telemetry = snapshots.capture(.init(reason: "telemetry", application: .init(pid: pid, name: "Fixture"),
            observerGeneration: generation, accessibilityEvent: nil))
        test.check(reader.readIds.count == readsBeforeTelemetry
            && telemetry.observation["target_read_performed"]?.boolValue == false
            && telemetry.observation["target_window_id"] == .null
            && telemetry.focus.at(path: "observed_uptime_ns")?.intValue == exactRead,
            "targeted-feed/\(name)-telemetry-preserves-cache-stamp-and-has-no-fresh-target-evidence")
        let windows = deliveries.all.last?["windows"]?.arrayValue ?? []
        test.check(windows.contains { $0.at(path: "display_id")?.stringValue == "display-a"
                && $0.at(path: "space_enabled")?.boolValue == true }
            && windows.contains { $0.at(path: "display_id")?.stringValue == "display-b"
                && $0.at(path: "space_enabled")?.boolValue == false },
            "targeted-feed/\(name)-display-a-on-and-b-off-are-independent")
        let beforeStale = deliveries.all.count
        observer.emit(.focusedWindowMoved, pid: pid, generation: generation,
            windowGeneration: 0, element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        observer.emit(.focusedWindowMoved, pid: pid + 1, generation: generation,
            windowGeneration: UInt64(expectedCount), element: reader.elements[lastId], windowId: lastId)
        operations.runOne()
        test.check(deliveries.all.count == beforeStale,
            "targeted-feed/\(name)-old-window-generation-and-foreign-pid-refuse-before-read")
        worldObserver.emit(.focusedWindowMoved, pid: pid, generation: generation,
            element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"]?.at(path: "window_id")?.intValue == lastId
            && reader.readIds.last == firstId && reader.inventoryCalls == 1,
            "targeted-feed/\(name)-background-window-update-does-not-retarget-focus")
        worldObserver.emit(.focusedWindowMoved, pid: pid, generation: generation,
            element: reader.elements[firstId], windowId: firstId, windowGeneration: 10)
        operations.runOne()
        let beforeOldRegistration = deliveries.all.count
        worldObserver.emit(.focusedWindowMoved, pid: pid, generation: generation,
            element: reader.elements[firstId], windowId: firstId, windowGeneration: 9)
        operations.runOne()
        test.check(deliveries.all.count == beforeOldRegistration,
            "targeted-feed/\(name)-same-pid-and-window-id-old-registration-token-is-rejected")
        worldObserver.emit(.focusedWindowDestroyed, pid: pid, generation: generation,
            element: reader.elements[lastId], windowId: lastId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["windows"]?.arrayValue?.count == expectedCount - 1
            && reader.inventoryCalls == 1,
            "targeted-feed/\(name)-destruction-revokes-focus-and-cache-without-read")
        observer.emit(.focusedWindowChanged, pid: pid, generation: generation,
            windowGeneration: UInt64(expectedCount + 1), element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        observer.emit(.focusedWindowMinimized, pid: pid, generation: generation,
            windowGeneration: UInt64(expectedCount + 1), element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"] == .null,
            "targeted-feed/\(name)-minimize-clears-ring-authority-immediately")
        reader.readFailure = .init(code: "ax_attribute_read_failed:AXPosition:-25204")
        observer.emit(.focusedWindowChanged, pid: pid, generation: generation,
            windowGeneration: UInt64(expectedCount + 2), element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["observation"]?.at(path: "ready")?.boolValue == false
            && deliveries.all.last?["observation"]?.at(path: "world_complete")?.boolValue == false,
            "targeted-feed/\(name)-failed-ax-read-is-explicit-and-never-stale-success")
        reader.readFailure = nil
        reader.recycledIdentity = true
        observer.emit(.focusedWindowChanged, pid: pid, generation: generation,
            windowGeneration: UInt64(expectedCount + 3), element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["observation"]?.at(path: "failure_code")?.stringValue == "ax_notification_identity_mismatch",
            "targeted-feed/\(name)-recycled-ax-identity-does-not-authorize-another-window")
        reader.recycledIdentity = false
        spaces.unavailable = true
        observer.emit(.focusedWindowChanged, pid: pid, generation: generation,
            windowGeneration: UInt64(expectedCount + 4), element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["observation"]?.at(path: "failure_code")?.stringValue == "independent_window_space_unknown_or_ambiguous",
            "targeted-feed/\(name)-unknown-space-has-no-runtime-identity-fallback")
        trust.trusted = false
        feed.trustChanged(frontmost: .init(pid: pid, name: "Fixture"))
        test.check(deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["windows"]?.arrayValue?.isEmpty == true
            && deliveries.all.last?["observation"]?.at(path: "failure_code")?.stringValue == "ax_untrusted"
            && worldObserver.windowIds.isEmpty,
            "targeted-feed/\(name)-trust-loss-revokes-world-and-all-window-registrations")
        trust.trusted = true
        spaces.unavailable = false
        feed.spaceChanged(frontmost: .init(pid: pid, name: "Fixture"))
        let beforeOverflow = deliveries.all.count
        for _ in 0...ProjectionInputFeed.maximumPendingInputs {
            observer.emit(.focusedWindowMoved, pid: pid, generation: feed.currentGeneration,
                windowGeneration: 1, element: reader.elements[firstId], windowId: firstId)
        }
        test.check(operations.pending == 1 && deliveries.all.count == beforeOverflow,
            "targeted-feed/\(name)-burst-mailbox-has-one-drain-and-bounded-admission")
        operations.runOne()
        test.check(deliveries.all.count == beforeOverflow + 1
            && deliveries.all.last?["event"]?.stringValue == "projection_feed_input_overflow"
            && deliveries.all.last?["focus"] == .null
            && deliveries.all.last?["observation"]?.at(path: "world_complete")?.boolValue == false
            && deliveries.all.last?["feed_queue_max_depth"]?.intValue == 64
            && deliveries.all.last?["feed_queue_overflow_count"]?.intValue == 1,
            "targeted-feed/\(name)-overflow-refuses-batch-and-invalidates-before-further-authority")
        observer.emit(.focusedWindowMoved, pid: pid, generation: feed.currentGeneration,
            windowGeneration: 2, element: reader.elements[firstId], windowId: firstId)
        test.check(operations.pending == 0,
            "targeted-feed/\(name)-overflow-fences-further-notifications-until-recovery")
        feed.spaceChanged(frontmost: .init(pid: pid, name: "Fixture"))
        observer.emit(.focusedWindowMoved, pid: pid, generation: feed.currentGeneration,
            windowGeneration: 1, element: reader.elements[firstId], windowId: firstId)
        operations.runOne()
        test.check(deliveries.all.last?["event"]?.stringValue == "ax_window_moved"
            && deliveries.all.last?["observation"]?.at(path: "world_complete")?.boolValue == true,
            "targeted-feed/\(name)-recovery-replaces-generation-and-resumes-authority")
        worldObserver.nextFailure = .init(code: "ax_window_created_registration_failed:notificationUnsupported")
        feed.spaceChanged(frontmost: .init(pid: pid, name: "Fixture"))
        test.check(deliveries.all.last?["observation"]?.at(path: "world_complete")?.boolValue == false
            && deliveries.all.last?["observation"]?.at(path: "world_failure_code")?.stringValue
                == "ax_window_created_registration_failed:notificationUnsupported",
            "targeted-feed/\(name)-unsupported-lifecycle-observation-does-not-certify-a-seed-only-cache")
        worldObserver.nextFailure = nil
        feed.spaceChanged(frontmost: .init(pid: pid, name: "Fixture"))
        let lifetimeBeforeRebind = snapshots.windowGenerations[String(firstId)]!
        feed.applicationActivated(.init(pid: pid, name: "Fixture"))
        test.check(snapshots.windowGenerations[String(firstId)] == lifetimeBeforeRebind,
            "targeted-feed/\(name)-app-observer-generation-rebind-preserves-live-window-lifetime")
        worldObserver.emit(.windowCreated, pid: pid, generation: worldObserver.activeGeneration,
            element: reader.elements[firstId], windowId: firstId, windowGeneration: 321)
        operations.runOne()
        let recreatedLifetime = snapshots.windowGenerations[String(firstId)]!
        let resolverResult = snapshots.resolveWindow(windowId: firstId, observerGeneration: feed.currentGeneration,
            expectedWindowGeneration: lifetimeBeforeRebind)
        let resolverReason: String?
        switch resolverResult {
        case .failure(let failure): resolverReason = failure.code
        case .success: resolverReason = nil
        }
        test.check(recreatedLifetime > lifetimeBeforeRebind && resolverReason == "window_resolver_lifetime_generation_mismatch",
            "targeted-feed/\(name)-same-id-recreation-retires-lifetime-and-refuses-queued-old-effect")
        feed.stop()
        snapshots.stop()
    }
    runTargetedProjectionLifetimeScenarios(test: &test)
    runTargetedProjectionSessionScenarios(test: &test)
    let emptyReader = TargetedFeedWindowFixture([])
    let emptySpaces = TargetedFeedSpaceFixture([])
    emptySpaces.contexts[-1] = .init(key: "space:uuid:empty-desktop", displayId: "sole-display", visible: true)
    let emptyWorldObserver = TargetedFeedWorldObserverFixture()
    let emptySnapshot = TargetedProjectionSnapshot(trusted: { true }, reader: emptyReader,
        spaces: emptySpaces, worldObserver: emptyWorldObserver)
    let emptyWorld = emptySnapshot.capture(.init(reason: "world_seed", application: nil,
        observerGeneration: 1, accessibilityEvent: nil))
    test.check(emptyWorld.focus == .null && emptyWorld.windows.isEmpty
        && emptyWorld.observation["world_complete"]?.boolValue == true
        && emptyWorld.activeContext.at(path: "space_key")?.stringValue == "space:uuid:empty-desktop",
        "targeted-feed/empty-no-focus-space-is-targeted-by-independent-sole-display-context")
    emptySpaces.contexts[-2] = .init(key: "space:uuid:other-desktop", displayId: "other-display", visible: true)
    let ambiguousEmpty = emptySnapshot.capture(.init(reason: "space_changed", application: nil,
        observerGeneration: 2, accessibilityEvent: nil))
    test.check(ambiguousEmpty.activeContext == .null && ambiguousEmpty.spaceContexts.count == 2,
        "targeted-feed/multiple-empty-display-contexts-refuse-an-unobserved-control-target")
    emptySpaces.unavailable = true
    let unknownEmpty = emptySnapshot.capture(.init(reason: "space_changed", application: nil,
        observerGeneration: 3, accessibilityEvent: nil))
    test.check(unknownEmpty.activeContext == .null && unknownEmpty.spaceContexts.isEmpty
        && unknownEmpty.observation["world_complete"]?.boolValue == false,
        "targeted-feed/unknown-empty-space-never-becomes-a-runtime-counter-target")
    emptySnapshot.stop()
    emptySpaces.unavailable = false
    let changingTrust = TargetedFeedTrustFixture()
    changingTrust.trusted = false
    let changingSnapshot = TargetedProjectionSnapshot(trusted: { changingTrust.trusted }, reader: emptyReader,
        spaces: emptySpaces, worldObserver: TargetedFeedWorldObserverFixture(), identityIsCurrent: { _ in true })
    let untrustedSeed = changingSnapshot.capture(.init(reason: "world_seed", application: nil,
        observerGeneration: 1, accessibilityEvent: nil))
    changingTrust.trusted = true
    let grantedRecovery = changingSnapshot.capture(.init(reason: "trust_changed", application: nil,
        observerGeneration: 2, accessibilityEvent: nil))
    test.check(untrustedSeed.observation["failure_code"]?.stringValue == "ax_untrusted"
        && grantedRecovery.observation["world_complete"]?.boolValue == true
        && grantedRecovery.observation["failure_code"] == .null,
        "targeted-feed/startup-without-trust-recovers-from-live-trust-provider-after-grant")
    changingSnapshot.stop()
    let independentObserver = AccessibilityFocusObserver(trustedProvider: { false })
    test.check(independentObserver.isObservationRunLoopIndependentOfMain,
        "targeted-feed/observer-runloop-executes-independently-of-appkit-main-thread")
    test.check(TargetedProjectionSnapshot.axReadTimeoutSeconds > 0
        && TargetedProjectionSnapshot.axReadTimeoutSeconds <= 0.1
        && TargetedProjectionSnapshot.axTotalReadBudgetNs <= 200_000_000,
        "targeted-feed/hostile-ax-timeout-and-total-read-bounds-are-frozen")
}

/// Exercises the live inventory's canonical classifier with AX/clock injection.
/// No actual Accessibility attribute or window-server identity read occurs.
private func runProjectionInventoryClassificationScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.url("feed/inventory-classification.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let pid = fixture.at(path: "pid")?.intValue,
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 14 else {
        test.check(false, "inventory-classification/nonvacuous-fixture-load"); return
    }
    for scenario in scenarios {
        let name = scenario.requiredString("name")
        let element = AXUIElementCreateApplication(pid_t(pid))
        var attributes: [String] = []
        var identityReads = 0
        var timeoutConfigurations = 0
        var configuredBeforeRead = true
        var elapsed: UInt64 = 0
        let result = projectionInventoryWindowIdentity(element: element, pid: pid_t(pid), readStringAttribute: { _, attribute in
            let attributeName = attribute as String
            configuredBeforeRead = configuredBeforeRead && timeoutConfigurations == 1
            attributes.append(attributeName)
            let key = attributeName == "AXRole" ? "role" : "subrole"
            elapsed = UInt64(scenario.at(path: "read_elapsed_ns")?.intValue ?? 0)
            guard let value = scenario.at(path: key)?.stringValue else {
                return .failure(.init(code: "fixture_attribute_unavailable:" + attributeName))
            }
            return .success(value)
        }, readIdentity: { _ in
            identityReads += 1
            guard let identityPid = scenario.at(path: "identity_pid")?.intValue,
                  let id = scenario.at(path: "window_id")?.intValue else { return nil }
            return .init(windowId: UInt32(id), pid: pid_t(identityPid))
        }, uptimeNs: { elapsed }, configureTimeout: { _ in
            timeoutConfigurations += 1
            return scenario.at(path: "timeout_failure")?.boolValue == true ? .cannotComplete : .success
        })
        let observed: String
        switch result {
        case .failure(let failure): observed = failure.code
        case .success(let identity): observed = identity == nil ? "excluded" : "retained"
        }
        let expectedAttributes = scenario.at(path: "expected_attributes")!.arrayValue!.compactMap(\.stringValue)
        let expected = scenario.requiredString("expected")
        let classificationFailed = expected.contains("attribute_unavailable") || expected.contains("unknown")
            || expected.contains("deadline_exceeded") || expected.contains("timeout_configuration_failed")
        test.check(observed == expected && attributes == expectedAttributes && identityReads == (classificationFailed ? 0 : 1)
            && timeoutConfigurations == 1 && configuredBeforeRead,
            "inventory-classification/" + name)
    }
}

/// Quartz takes a CFArray of raw CGWindowID integers, not NSNumber objects.
/// The injected description reader inspects pointers without dereferencing them;
/// every response and refusal is independent of the user's actual window list.
private func runProjectionNamedWindowDescriptionScenarios(test: inout SelfTest) {
    let fixturePath = SelfTestFixtures.url("feed/named-window-description.json")
    guard let data = try? Data(contentsOf: fixturePath), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 10 else {
        test.check(false, "named-window-description/nonvacuous-fixture-load"); return
    }
    for scenario in scenarios {
        let name = scenario.requiredString("name")
        let windowID = CGWindowID(scenario.at(path: "window_id")!.intValue!)
        var readerCalls = 0
        var exactRawIntegerRequest = true
        let result = projectionNamedWindowDescription(windowID: windowID, descriptionReader: { ids in
            readerCalls += 1
            exactRawIntegerRequest = exactRawIntegerRequest && CFArrayGetCount(ids) == 1
                && CFArrayGetValueAtIndex(ids, 0) == UnsafeRawPointer(bitPattern: UInt(windowID))
            guard let response = scenario.at(path: "descriptions"), response != .null,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(response.canonical().utf8)),
                  let descriptions = decoded as? [Any] else { return nil }
            return descriptions as CFArray
        })
        let observed: String
        var exactReturnedRecord = true
        switch result {
        case .failure(let failure): observed = failure.code
        case .success(let row):
            observed = "success"
            exactReturnedRecord = (row[kCGWindowNumber as String] as? NSNumber)?.uint64Value == UInt64(windowID)
                && row["fixture_marker"] as? String == scenario.at(path: "descriptions")?.arrayValue?.first?.at(path: "fixture_marker")?.stringValue
        }
        test.check(observed == scenario.requiredString("expected")
            && readerCalls == scenario.requiredInt("reader_calls")
            && exactRawIntegerRequest && exactReturnedRecord, "named-window-description/" + name)
    }
    // The compiled source tree, not the fixture root: this pins the production reader's text.
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = try? String(contentsOf: sourceRoot.appendingPathComponent("LiveTargetedProjectionWindowReader.swift"), encoding: .utf8)
    let start = source?.range(of: "func projectionNamedWindowDescription(")
    let end = start.flatMap { source?.range(of: "/// @canonical projection_inventory_identity", range: $0.upperBound..<source!.endIndex) }
    let helper = start.flatMap { start in end.map { String(source![start.lowerBound..<$0.lowerBound]) } }
    test.check(helper?.contains("CGWindowListCreateDescriptionFromArray") == true
        && helper?.contains("CGWindowListCopyWindowInfo") == false,
        "named-window-description/exact-description-capability-has-no-window-list-fallback")
}

/// Uses concrete CFBoolean/CFNumber objects so Swift NSNumber-to-Bool coercion
/// cannot make malformed Quartz metadata look like an observed visibility flag.
private func runProjectionWindowOnscreenScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.url("feed/window-onscreen.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 8 else {
        test.check(false, "window-onscreen/nonvacuous-fixture-load"); return
    }
    for scenario in scenarios {
        let name = scenario.requiredString("name")
        let value: Any?
        var exactFixtureType = true
        switch scenario.requiredString("kind") {
        case "absent": value = nil
        case "cfboolean":
            let flag = scenario.at(path: "value")!.boolValue! ? kCFBooleanTrue! : kCFBooleanFalse!
            value = flag
            exactFixtureType = CFGetTypeID(flag) == CFBooleanGetTypeID()
        case "cfnumber":
            var numeric = scenario.at(path: "value")!.intValue!
            guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &numeric) else {
                test.check(false, "window-onscreen/" + name); continue
            }
            value = number
            exactFixtureType = CFGetTypeID(number) == CFNumberGetTypeID()
                && CFGetTypeID(number) != CFBooleanGetTypeID()
        case "string": value = scenario.requiredString("value") as NSString
        default: value = NSNull()
        }
        let observed: String
        switch projectionWindowOnscreen(value) {
        case .failure(let failure): observed = failure.code
        case .success(let visible): observed = visible ? "true" : "false"
        }
        test.check(exactFixtureType && observed == scenario.requiredString("expected"), "window-onscreen/" + name)
    }
}
