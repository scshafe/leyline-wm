// `leylined core` wires event-driven Workspace/AX/mode feeds into CoreServer.
// The read-only socket and recovery controls precede the asynchronous AX seed.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LeylineModel

typealias CoreMainOperationEnqueue = @Sendable (
    _ operation: @escaping @Sendable () -> Void
) -> Void
/// @canonical core_startup_bootstrap -- one queued first capture establishes
/// the genuine world seed without holding the main event loop or read surface.
/// The epoch is captured before enqueueing so STOP/restart invalidates both
/// queued work and a seed returning from an already blocked capture.
final class CoreStartupBootstrap: @unchecked Sendable {
    static let pendingDelta: JSONObject = [
        "event": .string("bootstrap_pending"), "focus": .null,
        "windows": .null, "windows_onscreen": .null,
        "active_context": .null, "space_contexts": .null,
        "observation": .object(["world_complete": .bool(false),
            "reason": .string("bootstrap_pending"),
            "world_failure_code": .string("bootstrap_pending")]),
    ]

    private let server: CoreServer
    private let lock = NSLock()
    private var activeEpoch: UInt64?

    init(server: CoreServer) { self.server = server }

    /// Only the synchronous feed delivery inside the initial capture requires
    /// this token. Later lifecycle starts retain their own generation checks.
    var requiredObservationEpoch: UInt64? {
        lock.withLock { activeEpoch }
    }

    func schedule(execute: @escaping CoreMainOperationEnqueue,
                  capture: @escaping @Sendable () -> Void,
                  discard: @escaping @Sendable () -> Void) {
        let epoch = server.observationEpoch
        execute { [self] in
            guard isCurrent(epoch) else { return }
            lock.withLock { activeEpoch = epoch }
            capture()
            lock.withLock { activeEpoch = nil }
            if !isCurrent(epoch) { discard() }
        }
    }

    private func isCurrent(_ epoch: UInt64) -> Bool {
        server.observationEpoch == epoch
            && server.worldState.at(path: "management_enabled")?.boolValue != false
    }
}

/// @canonical core_observation_publication_scope -- every read retains its original session;
/// audit diagnostics also require an epoch because they need not carry a world observation.
struct CoreObservationPublicationScope: Sendable {
    let requiredEpoch: UInt64?

    static func admit(_ delta: JSONObject, sessionGeneration: UInt64) -> Self? {
        let observationSession = delta["observation"]?.at(path: "session_generation")?.intValue
        let audit = delta["cache_integrity"]
        let auditSession = audit?.at(path: "session_generation")?.intValue
        guard let sourceSession = observationSession ?? auditSession, sourceSession >= 0,
              sourceSession == Int64(clamping: sessionGeneration) else { return nil }
        if let audit {
            guard auditSession == sourceSession,
                  let epoch = audit.at(path: "observation_epoch")?.intValue, epoch >= 0 else { return nil }
            return Self(requiredEpoch: UInt64(epoch))
        }
        return Self(requiredEpoch: nil)
    }
}

private final class CoreProjectionDriver: @unchecked Sendable {
    private let server: CoreServer
    private let maximumRevisions: Int
    let presentation: CorePresentationMailbox

    init(server: CoreServer, renderer: BorderRenderer?, maximumRevisions: Int) {
        self.server = server
        self.maximumRevisions = maximumRevisions
        presentation = CorePresentationMailbox(execute: { operation in
            DispatchQueue.main.async(execute: operation)
        }, present: { snapshot in
            MainActor.assumeIsolated {
                if let renderer {
                    _ = renderer.render(plan: snapshot.borderPlan, revision: snapshot.revision)
                    server.updateProjectionHealth(renderer.health)
                }
            }
        })
    }

    func applyWorld(_ delta: JSONObject, requiredObservationEpoch: UInt64? = nil) {
        finish(server.applyWorldDelta(delta, requiredObservationEpoch: requiredObservationEpoch))
    }
    func publish(_ snapshot: CoreCommittedSnapshot) { presentation.submit(snapshot) }
    private func finish(_ result: WmResult) {
        guard result.status == .accepted else { return }
        if maximumRevisions > 0, server.worldSeedReady,
           result.revision.value >= UInt64(maximumRevisions) {
            server.stop()
            exit(0)
        }
    }
}

private func projectionApplication(_ running: NSRunningApplication?) -> ProjectionApplication? {
    running.map {
        ProjectionApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "")
    }
}

/// Startup requires a logged-in console session and excludes the foreground
/// login window. The optional lock flag augments those public session facts;
/// absent console/login facts remain unavailable rather than assumed active.
func coreSessionInitiallyAvailable(locked: Bool?, onConsole: Bool?, loginDone: Bool?,
                                  loginWindowForeground: Bool) -> Bool {
    locked != true && onConsole == true && loginDone == true && !loginWindowForeground
}

@MainActor
private func coreReadSessionAvailability() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let foreground = NSWorkspace.shared.frontmostApplication
    let loginWindow = foreground?.bundleIdentifier == "com.apple.loginwindow"
        || foreground?.localizedName?.replacingOccurrences(of: " ", with: "").lowercased() == "loginwindow"
    return coreSessionInitiallyAvailable(locked: session?["CGSSessionScreenIsLocked"] as? Bool,
        onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool,
        loginDone: session?[kCGSessionLoginDoneKey as String] as? Bool,
        loginWindowForeground: loginWindow)
}

/// @canonical tiling_display_frame -- reserve menu/notch space, not the Dock.
/// AppKit frames use bottom-left coordinates; returned frames use CG top-left.
func coreTilingDisplayFrame(screen: Frame, visible: Frame, safeAreaTop: Double, primaryHeight: Double) -> Frame? {
    guard [screen.x, screen.y, screen.w, screen.h, visible.x, visible.y, visible.w, visible.h,
           safeAreaTop, primaryHeight].allSatisfy(\.isFinite),
          screen.w > 0, screen.h > 0, visible.w > 0, visible.h > 0, safeAreaTop >= 0,
          visible.x >= screen.x, visible.y >= screen.y,
          visible.maxX <= screen.maxX, visible.maxY <= screen.maxY else { return nil }
    let top = max(screen.maxY - visible.maxY, safeAreaTop)
    guard top < screen.h else { return nil }
    return Frame(x: screen.x, y: primaryHeight - screen.maxY + top, w: screen.w, h: screen.h - top)
}

/// AppKit supplies tiling frames only on bootstrap/display events. Dock edges
/// can overlay tiled content; their reservation must not leave unused strips.
@MainActor
private func coreUsableDisplayFrames() -> [String: Frame] {
    let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? 0
    var frames: [String: Frame] = [:]
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
        let key = CFUUIDCreateString(nil, uuid) as String
        let bounds = screen.frame, visible = screen.visibleFrame
        if let frame = coreTilingDisplayFrame(
            screen: Frame(x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height),
            visible: Frame(x: visible.minX, y: visible.minY, w: visible.width, h: visible.height),
            safeAreaTop: screen.safeAreaInsets.top, primaryHeight: primaryHeight) {
            frames[key] = frame
        }
    }
    return frames
}

func runCore(_ args: [String]) -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let root = environment["LEYLINE_ROOT"] ?? (NSHomeDirectory() + "/.config/leyline")
    let runtime = environment["LEYLINE_RUNTIME_DIR"] ?? (root + "/runtime")
    var socketPath = runtime + "/sockets/leylined.sock"
    #if LEYLINE_BUILD_TESTS
    var maximumRevisions = 0
    var simulateNoTrust = false
    let usage = "usage: leylined core [--socket <path>] [--max-revisions <n>] [--simulate-no-trust]\n"
    #else
    let maximumRevisions = 0
    let simulateNoTrust = false
    let usage = "usage: leylined core [--socket <path>]\n"
    #endif
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--socket" where index + 1 < args.count:
            socketPath = args[index + 1]
            index += 2
        #if LEYLINE_BUILD_TESTS
        case "--max-revisions" where index + 1 < args.count:
            maximumRevisions = Int(args[index + 1]) ?? 0
            index += 2
        case "--simulate-no-trust":
            simulateNoTrust = true
            index += 1
        #endif
        default:
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
    }

    signal(SIGPIPE, SIG_IGN)
    let simulateTrustLoss = simulateNoTrust
    let trustProvider: @Sendable () -> Bool = { !simulateTrustLoss && AXIsProcessTrusted() }
    let sessionActive = ResidentAtomic(MainActor.assumeIsolated { coreReadSessionAvailability() })
    let sessionGeneration = ResidentAtomic<UInt64>(0)
    let sessionAvailable: @Sendable () -> Bool = { sessionActive.load(ordering: .acquiring) }
    let observationTrusted: @Sendable () -> Bool = { sessionAvailable() && trustProvider() }
    let trusted = trustProvider()
    let journalPath = root + "/state/leylined/journal.jsonl"
    let journal = ResidentEffectorFileJournal(path: journalPath)
    var initialRevision: UInt64 = 0
    var initialState: JSONValue = .object([:])
    do {
        let journalDirectory = try ResidentPrivateFiles.openDirectory(
            at: (journalPath as NSString).deletingLastPathComponent, create: true)
        close(journalDirectory)
        let recovered = try journal.recoverCheckpoint()
        initialRevision = recovered.highWaterRevision
        if let state = recovered.state {
            initialState = .object(["model_state": state, "checkpoint_recovered": .bool(true)])
        }
    } catch {
        FileHandle.standardError.write(Data("leylined: JOURNAL.RECOVERY_FAILED \(error)\n".utf8))
        initialState = .object(["persistence_available": .bool(false), "journal_highwater_available": .bool(false),
            "resident_status": .string("Saved state unavailable"), "resident_unavailable_reason": .string("journal_recovery_failed")])
    }
    let server = CoreServer(socketPath: socketPath, initialRevision: initialRevision, initialState: initialState)

    let rendererSetup: (renderer: BorderRenderer?, health: CoreProjectionHealth) = MainActor.assumeIsolated {
        // Establish the dockless identity before mount can create an NSPanel.
        NSApplication.shared.setActivationPolicy(.accessory)
        var initialBorderStore = BorderConfiguration.readStore()?.objectValue ?? [:]
        let initialPreferences = ResidentSettingsStore.read(path: ResidentSettingsStore.defaultPath())
        if let width = initialPreferences.globalGutterWidth { initialBorderStore["width"] = .int(Int64(width)) }
        let candidate = BorderRenderer(store: .object(initialBorderStore))
        _ = candidate.mount()
        return (candidate, candidate.health)
    }
    server.updateProjectionHealth(rendererSetup.health)
    let driver = CoreProjectionDriver(
        server: server, renderer: rendererSetup.renderer, maximumRevisions: maximumRevisions)
    let bootstrap = CoreStartupBootstrap(server: server)
    server.setCommittedSnapshotHandler { driver.publish($0) }
    let observationQueue = DispatchQueue(label: "leylined.observation", qos: .userInitiated)
    let snapshots = TargetedProjectionSnapshot(
        trustedProvider: trustProvider, spaceEnabled: { server.spaceIsEnabled($0) },
        sessionAvailable: sessionAvailable,
        sessionGeneration: { sessionGeneration.load(ordering: .acquiring) })
    let usableFrames = MainActor.assumeIsolated { coreUsableDisplayFrames() }
    observationQueue.sync { snapshots.setUsableDisplayFrames(usableFrames) }
    let accessibilityObserver = AccessibilityFocusObserver(trustedProvider: observationTrusted)
    let transientRecovery = ProjectionTransientRecovery(execute: { observationQueue.async(execute: $0) })
    let feed = ProjectionInputFeed(
        observer: accessibilityObserver,
        captureTargeted: { snapshots.capture($0) },
        executeOnMain: { operation in
            observationQueue.async(execute: operation)
        },
        onHealthChanged: { health in
            server.updateFocusObserverHealth(health)
        },
        transientRecovery: transientRecovery,
        recoverySessionGeneration: { sessionGeneration.load(ordering: .acquiring) },
        recoveryObservationEpoch: { server.observationEpoch },
        recoveryPermitted: { observationTrusted() && server.worldState.at(path: "management_enabled")?.boolValue != false },
        deliver: { delta in
            // A delayed read may return after both lock and unlock. Its old
            // session cannot regain authority merely because the boolean is ON.
            guard let scope = CoreObservationPublicationScope.admit(delta,
                sessionGeneration: sessionGeneration.load(ordering: .acquiring)) else { return }
            driver.applyWorld(delta, requiredObservationEpoch: scope.requiredEpoch
                ?? bootstrap.requiredObservationEpoch ?? transientRecovery.requiredObservationEpoch)
        })
    let cacheAudit = ProjectionCacheIntegrityAudit(
        executeCompletion: { observationQueue.async(execute: $0) },
        permitted: { seed in
            observationTrusted()
                && sessionGeneration.load(ordering: .acquiring) == seed.sessionGeneration
                && server.observationEpoch == seed.observationEpoch
                && server.worldState.at(path: "management_enabled")?.boolValue != false
        })
    observationQueue.sync {
        feed.configureCacheAudit(cacheAudit,
            makeSeed: { snapshots.makeCacheAuditSeed(observerGeneration: $0,
                observationEpoch: server.observationEpoch) },
            finish: { snapshots.finishCacheAudit(seed: $0, probe: $1) })
    }

    let preferences = ResidentSettingsStore.read(path: ResidentSettingsStore.defaultPath())
    let gap = preferences.globalGutterWidth ?? Int(BorderConfiguration.readStore()?.at(path: "width")?.intValue ?? Int64(BorderPalette.defaultThickness))
    guard (0...512).contains(gap) else {
        FileHandle.standardError.write(Data("leylined: CONFIG.GAP_INVALID\n".utf8)); return 65
    }
    let actions = ResidentActionController(server: server, snapshots: snapshots,
        observationQueue: observationQueue, journal: journal, gap: gap)
    let services: CoreRuntimeServices
    do {
        services = try CoreRuntimeServices(server: server,
            home: ResidentResources.home(), observationQueue: observationQueue,
            feed: feed, snapshots: snapshots, renderer: rendererSetup.renderer, actions: actions,
            trustedProvider: observationTrusted)
    } catch {
        FileHandle.standardError.write(Data("leylined: INPUT.CONFIGURATION_FAILED \(error)\n".utf8)); return 65
    }
    server.setCommittedSnapshotHandler { snapshot in
        driver.publish(snapshot)
        services.receive(snapshot)
        let event = snapshot.world.at(path: "event")?.stringValue ?? ""
        if ["world_seed", "global_start", "wake_recovery", "topology_changed", "application_launch_recovery", "explicit_recovery"].contains(event),
           snapshot.world.at(path: "observation.world_complete")?.boolValue == true,
           snapshot.world.at(path: "cache_audit_recovery")?.boolValue != true,
           let sourceGeneration = snapshot.world.at(path: "observer_generation")?.intValue,
           let sourceSession = snapshot.world.at(path: "observation.session_generation")?.intValue {
            let epoch = server.observationEpoch
            observationQueue.async {
                guard observationTrusted(), server.observationEpoch == epoch,
                      sourceSession == Int64(clamping: sessionGeneration.load(ordering: .acquiring)),
                      sourceGeneration == Int64(clamping: feed.currentGeneration),
                      server.worldState.at(path: "management_enabled")?.boolValue != false else { return }
                _ = feed.requestCacheAudit(reason: "after_" + event)
            }
        }
    }
    server.configureCommands(actionIDs: Array(ResidentActionController.actionIDs)) { actions.handle($0) }
    let observe: @Sendable (@escaping @Sendable () -> Void) -> Void = { operation in
        observationQueue.async {
            guard server.worldState.at(path: "management_enabled")?.boolValue != false else { return }
            operation()
        }
    }

    // Startup is explicitly unknown. The real observation alone may establish
    // readiness; the early socket exposes status/recovery while AX is blocked.
    snapshots.onWorldEvent = { event in feed.worldAccessibilityEvent(event) }
    let frontmost = projectionApplication(NSWorkspace.shared.frontmostApplication)
    driver.applyWorld(CoreStartupBootstrap.pendingDelta)
    if !sessionAvailable() { services.sessionUnavailable() }
    guard server.start(requireWorldSeed: false) else {
        FileHandle.standardError.write(Data(
            "leylined core: cannot bind \(socketPath)\n".utf8))
        services.stopForShutdown()
        return 65
    }

    let started: JSONObject = [
        "type": .string("core_started"),
        "socket": .string(socketPath),
        "pid": .int(Int64(ProcessInfo.processInfo.processIdentifier)),
        "epoch_ms": .int(server.epochMs),
        "revision": .int(Int64(server.currentRevision)),
        "ax_trusted": .bool(trusted),
        "world_seed_ready": .bool(server.worldSeedReady),
    ]
    print(JSONValue.object(started).canonical())
    fflush(stdout)

    // Arms native startup without reconciling the still-pending world. The
    // genuine off-lane baseline below supplies the readiness continuation.
    services.start()

    let notificationCenter = NSWorkspace.shared.notificationCenter
    let sessionBecameUnavailable: @Sendable () -> Void = {
        transientRecovery.invalidate()
        sessionActive.store(false, ordering: .releasing)
        sessionGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        services.sessionUnavailable()
        observationQueue.async {
            snapshots.sessionUnavailable()
            guard server.worldState.at(path: "management_enabled")?.boolValue != false else { return }
            feed.trustChanged(frontmost: nil)
        }
    }
    let sessionBecameAvailable: @Sendable () -> Void = {
        sessionGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        sessionActive.store(true, ordering: .releasing)
        guard services.sessionMayResume() else { return }
        var unlocked: JSONObject = ["event": .string("session_unlocked")]
        let prior = server.worldState
        if prior.at(path: "resident_unavailable_reason") == .string("session_locked")
            || prior.at(path: "resident_status") == .string("Desktop locked") {
            unlocked["resident_unavailable_reason"] = .null
            unlocked["resident_status"] = .string("Starting")
        }
        _ = server.applyWorldDelta(unlocked)
        DispatchQueue.main.async {
            guard sessionAvailable(), services.sessionMayResume() else { return }
            let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
            let frames = MainActor.assumeIsolated { coreUsableDisplayFrames() }
            observe {
                guard sessionAvailable(), services.sessionMayResume() else { return }
                snapshots.setUsableDisplayFrames(frames)
                feed.wake(frontmost: app)
                guard sessionAvailable(), services.sessionMayResume(),
                      server.worldState.at(path: "observation.world_complete")?.boolValue == true,
                      server.worldState.at(path: "persistence_available")?.boolValue != false,
                      server.worldState.at(path: "geometry_available")?.boolValue != false else { return }
                _ = server.applyWorldDelta(["event": .string("session_recovered"),
                    "resident_unavailable_reason": .null, "resident_status": .string("Running")])
            }
        }
    }
    let distributed = DistributedNotificationCenter.default()
    let sessionLockedToken = distributed.addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { _ in sessionBecameUnavailable() }
    let sessionUnlockedToken = distributed.addObserver(
        forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { _ in sessionBecameAvailable() }
    let sessionActiveToken = notificationCenter.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        if MainActor.assumeIsolated({ coreReadSessionAvailability() }) { sessionBecameAvailable() }
    }
    let sessionInactiveToken = notificationCenter.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
    ) { _ in sessionBecameUnavailable() }
    let spaceToken = notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in
        let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
        observe { feed.spaceChanged(frontmost: app) }
    }
    let activateToken = notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil, queue: .main
    ) { notification in
        let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        let resolved = running ?? NSWorkspace.shared.frontmostApplication
        let app = projectionApplication(resolved)
        observe { feed.applicationActivated(app) }
    }
    let terminateToken = notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil, queue: .main
    ) { notification in
        let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        let pid = terminated?.processIdentifier ?? -1
        let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
        observe { feed.applicationTerminated(pid: pid, frontmost: app) }
    }
    let launchToken = notificationCenter.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
    ) { _ in
        let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
        observe { feed.applicationLaunched(frontmost: app) }
    }
    let wakeToken = notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
        let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
        observe { feed.wake(frontmost: app) }
    }
    let screenToken = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        let frames = MainActor.assumeIsolated { coreUsableDisplayFrames() }
        let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
        observe {
            snapshots.setUsableDisplayFrames(frames)
            feed.topologyChanged(frontmost: app)
        }
    }
    let trustAudit = CoreTrustAudit(read: trustProvider) { isTrusted in
        if !isTrusted {
            _ = server.applyWorldDelta(["event": .string("trust_changed"), "focus": .null,
                "observation": .object(["world_complete": .bool(false), "failure_code": .string("ax_untrusted")])])
        }
        DispatchQueue.main.async {
            let app = projectionApplication(NSWorkspace.shared.frontmostApplication)
            observe { feed.trustChanged(frontmost: app) }
        }
    }
    trustAudit.start()
    let notificationTokens = [spaceToken, activateToken, terminateToken, launchToken, wakeToken, screenToken,
        sessionLockedToken, sessionUnlockedToken, sessionActiveToken, sessionInactiveToken]
    _ = notificationTokens

    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }

    bootstrap.schedule(execute: { observationQueue.async(execute: $0) },
        capture: { feed.start(frontmost: frontmost) },
        discard: { feed.stop(); snapshots.stop() })

    MainActor.assumeIsolated {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.run()
    }
    trustAudit.stop()
    services.stopForShutdown()
    observationQueue.sync { feed.stop(); snapshots.stop() }
    server.stop()
    return 0
}
