// The canonical Accessibility focus observer. Both `observe --follow` and
// the resident core use this exact implementation: app-level focus changes
// rebind the focused-window moved/resized notifications, while an app/Space
// lifecycle rebind replaces the whole observer generation. Registration
// failures are typed degradations at the macOS Accessibility boundary; they
// are never mistaken for a healthy feed.
import ApplicationServices
import Foundation

/// A validated window callback reads the immutable registered element, rather
/// than a fresh AX wrapper whose private window-ID metadata may be unavailable.
/// App callbacks have no registered window and retain their notified target.
func accessibilityNotificationTarget<Element>(notifiedElement: Element, registeredElement: Element,
                                             registeredWindowId: Int64?) -> Element {
    registeredWindowId == nil ? notifiedElement : registeredElement
}

/// @canonical accessibility_window_notification_slots -- only positively
/// standard windows need frame notifications; ignored windows retain lifecycle.
func accessibilityWindowNotificationNames(role: String?, subrole: String?)
    -> Result<[String], ProjectionObservationFailure> {
    guard let role, !role.isEmpty, let subrole, !subrole.isEmpty else {
        return .failure(.init(code: "ax_window_notification_structure_unknown"))
    }
    let lifecycle = [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    return .success(role == kAXWindowRole as String && subrole == kAXStandardWindowSubrole as String
        ? [kAXMovedNotification, kAXResizedNotification] + lifecycle : lifecycle)
}

func accessibilityWindowNotificationIsRegistered(_ notification: String, notifications: [String]) -> Bool {
    notifications.contains(notification)
}

/// Installs exactly the classified slots and rolls back a partial registration.
/// Injectable registration operations exercise the real slot loop without AX.
func accessibilityRegisterWindowNotificationSlots(_ notifications: [String], add: (String) -> AXError,
                                                  remove: (String) -> Void)
    -> Result<[String], ProjectionObservationFailure> {
    var registered: [String] = []
    for notification in notifications {
        let error = add(notification)
        guard error == .success || error == .notificationAlreadyRegistered else {
            for prior in registered { remove(prior) }
            return .failure(.init(code: "ax_window_registration_failed:\(notification):\(error.rawValue)"))
        }
        registered.append(notification)
    }
    return .success(registered)
}

enum AccessibilityFocusEventKind: String, Sendable {
    case focusedWindowChanged = "ax_focus_changed"
    case focusedWindowMoved = "ax_window_moved"
    case focusedWindowResized = "ax_window_resized"
    case focusedWindowDestroyed = "ax_window_destroyed"
    case focusedWindowMinimized = "ax_window_minimized"
    case focusedWindowRestored = "ax_window_restored"
    case windowCreated = "ax_window_created"
    case worldObserverDegraded = "ax_world_observer_degraded"
}

struct AccessibilityFocusEvent: @unchecked Sendable {
    let kind: AccessibilityFocusEventKind
    let pid: pid_t
    let generation: UInt64
    let sourceObserverGeneration: UInt64?
    let windowGeneration: UInt64
    let element: AXUIElement?
    let windowId: Int64?
    let receiptUptimeNs: UInt64
    let isWorldObservation: Bool
    let degradedReason: String?

    init(kind: AccessibilityFocusEventKind, pid: pid_t, generation: UInt64,
         windowGeneration: UInt64 = 0, element: AXUIElement? = nil,
         windowId: Int64? = nil, receiptUptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
         isWorldObservation: Bool = false, degradedReason: String? = nil,
         sourceObserverGeneration: UInt64? = nil) {
        self.kind = kind
        self.pid = pid
        self.generation = generation
        self.sourceObserverGeneration = sourceObserverGeneration
        self.windowGeneration = windowGeneration
        self.element = element
        self.windowId = windowId
        self.receiptUptimeNs = receiptUptimeNs
        self.isWorldObservation = isWorldObservation
        self.degradedReason = degradedReason
    }
}

/// A timer-free observation run loop. AX registration, rebinding, and reads run
/// here so a tracking NSMenu or a blocked AppKit renderer cannot starve AX.
private final class AccessibilityRunLoopResult<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}

private final class AccessibilityNotificationRegistration {
    weak var owner: AccessibilityFocusObserver?
    let observerGeneration: UInt64
    let windowGeneration: UInt64
    let windowId: Int64?
    let element: AXUIElement
    let notifications: [String]

    init(owner: AccessibilityFocusObserver, observerGeneration: UInt64,
         windowGeneration: UInt64, windowId: Int64?, element: AXUIElement, notifications: [String] = []) {
        self.owner = owner
        self.observerGeneration = observerGeneration
        self.windowGeneration = windowGeneration
        self.windowId = windowId
        self.element = element
        self.notifications = notifications
    }
}

private final class AccessibilityObserverRunLoop: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
    }
    private let state = State()
    private let thread: Thread

    init() {
        let state = self.state
        thread = Thread {
            var context = CFRunLoopSourceContext(
                version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil, schedule: nil,
                cancel: nil, perform: { _ in })
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            let loop = CFRunLoopGetCurrent()!
            state.loop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            state.ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "leyline.accessibility.observation"
        thread.start()
        state.ready.wait()
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) -> T {
        if Thread.current == thread { return operation() }
        let result = AccessibilityRunLoopResult<T>()
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(state.loop, CFRunLoopMode.commonModes.rawValue) {
            result.value = operation()
            done.signal()
        }
        CFRunLoopWakeUp(state.loop)
        done.wait()
        return result.value!
    }

    deinit {
        CFRunLoopStop(state.loop)
        CFRunLoopWakeUp(state.loop)
    }
}

struct AccessibilityObserverHealth: Equatable, Sendable {
    let ready: Bool
    let pid: pid_t?
    let generation: UInt64
    let windowNotificationsReady: Bool
    let degradedReason: String?

    static func detached(generation: UInt64, reason: String? = nil) -> Self {
        Self(ready: false, pid: nil, generation: generation,
             windowNotificationsReady: false, degradedReason: reason)
    }

    static func degraded(pid: pid_t?, generation: UInt64, reason: String) -> Self {
        Self(ready: false, pid: pid, generation: generation,
             windowNotificationsReady: false, degradedReason: reason)
    }
}

/// @canonical accessibility_focus_observer -- every live AX focus/move/resize
/// feed must attach through this interface and implementation.
protocol AccessibilityFocusObserving: AnyObject {
    var onEvent: ((AccessibilityFocusEvent) -> Void)? { get set }
    var onHealthChanged: ((AccessibilityObserverHealth) -> Void)? { get set }

    @discardableResult
    func attach(to pid: pid_t, generation: UInt64) -> AccessibilityObserverHealth
    func detach(generation: UInt64)
}

final class AccessibilityFocusObserver: AccessibilityFocusObserving, @unchecked Sendable {
    var onEvent: ((AccessibilityFocusEvent) -> Void)?
    var onHealthChanged: ((AccessibilityObserverHealth) -> Void)?

    private let trustedProvider: @Sendable () -> Bool
    private let observationRunLoop = AccessibilityObserverRunLoop()
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedWindowElement: AXUIElement?
    private var observedPid: pid_t = 0
    private var generation: UInt64 = 0
    private var sourceInstalled = false
    private var windowGeneration: UInt64 = 0
    private var trackedWindows: [Int64: AXUIElement] = [:]
    private var worldObservation = false
    private var focusedWindowId: Int64?
    private var applicationRegistration: AccessibilityNotificationRegistration?
    private var windowRegistrations: [Int64: AccessibilityNotificationRegistration] = [:]
    private var retiredRegistrations: [AccessibilityNotificationRegistration] = []
    private static let maximumRetiredRegistrations = 256

    convenience init(trusted: Bool) {
        self.init(trustedProvider: { trusted && AXIsProcessTrusted() })
    }

    init(trustedProvider: @escaping @Sendable () -> Bool) {
        self.trustedProvider = trustedProvider
    }

    var isObservationRunLoopIndependentOfMain: Bool {
        observationRunLoop.perform {
            !Thread.isMainThread && CFRunLoopGetCurrent() != CFRunLoopGetMain()
        }
    }

    @discardableResult
    func attach(to pid: pid_t, generation: UInt64) -> AccessibilityObserverHealth {
        observationRunLoop.perform { [self] in
            attachOnObservationRunLoop(to: pid, generation: generation, worldWindows: nil)
        }
    }

    func attachWorld(to pid: pid_t, generation: UInt64,
                     windows: [ProjectionWindowHandle]) -> AccessibilityObserverHealth {
        observationRunLoop.perform { [self] in
            attachOnObservationRunLoop(to: pid, generation: generation, worldWindows: windows)
        }
    }

    /// Add the inventoried windows to the already enrolled application source.
    /// Keeping that concrete source closes the create-during-bootstrap gap.
    func registerWorldWindows(_ windows: [ProjectionWindowHandle], generation: UInt64)
        -> AccessibilityObserverHealth {
        observationRunLoop.perform { [self] in
            guard worldObservation, generation == self.generation, observedPid > 0 else {
                return .degraded(pid: observedPid, generation: generation, reason: "ax_world_registration_generation_mismatch")
            }
            for handle in windows {
                guard handle.pid == observedPid,
                      liveProjectionAXWindowIdentity(handle.element)
                        == ProjectionAXWindowIdentity(windowId: CGWindowID(handle.windowId), pid: observedPid) else {
                    return .degraded(pid: observedPid, generation: generation, reason: "ax_world_inventory_identity_changed")
                }
                if let reason = registerWindow(handle.element) {
                    return .degraded(pid: observedPid, generation: generation, reason: reason)
                }
                trackedWindows[handle.windowId] = handle.element
            }
            return AccessibilityObserverHealth(ready: true, pid: observedPid, generation: generation,
                windowNotificationsReady: true, degradedReason: nil)
        }
    }

    private func attachOnObservationRunLoop(to pid: pid_t, generation: UInt64,
                                           worldWindows: [ProjectionWindowHandle]?) -> AccessibilityObserverHealth {
        let priorWindowGeneration = self.generation == generation ? windowGeneration : 0
        detachOnObservationRunLoop(generation: generation)
        self.generation = generation
        windowGeneration = priorWindowGeneration
        guard trustedProvider() else {
            return .degraded(pid: pid, generation: generation, reason: "ax_untrusted")
        }

        var created: AXObserver?
        let callback: AXObserverCallback = { callbackObserver, element, notification, refcon in
            guard let refcon else { return }
            let registration = Unmanaged<AccessibilityNotificationRegistration>
                .fromOpaque(refcon).takeUnretainedValue()
            registration.owner?.receive(observer: callbackObserver, element: element,
                notification: notification as String, registration: registration)
        }
        let createError = AXObserverCreate(pid, callback, &created)
        guard createError == .success, let created else {
            return .degraded(
                pid: pid, generation: generation,
                reason: "ax_observer_create_failed:\(createError.rawValue)")
        }

        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            return .degraded(pid: pid, generation: generation, reason: "ax_timeout_configuration_failed")
        }
        let registration = AccessibilityNotificationRegistration(owner: self,
            observerGeneration: generation, windowGeneration: 0, windowId: nil, element: application)
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
        if worldWindows == nil {
            let focusError = AXObserverAddNotification(
                created, application,
                kAXFocusedWindowChangedNotification as CFString, refcon)
            guard focusError == .success else {
                return .degraded(
                    pid: pid, generation: generation,
                    reason: "ax_focus_registration_failed:\(focusError.rawValue)")
            }
        }

        observer = created
        applicationElement = application
        applicationRegistration = registration
        observedPid = pid
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .commonModes)
        sourceInstalled = true

        if let worldWindows {
            worldObservation = true
            let createdError = AXObserverAddNotification(created, application, kAXWindowCreatedNotification as CFString, refcon)
            guard createdError == .success else {
                return .degraded(pid: pid, generation: generation,
                    reason: "ax_window_created_registration_failed:\(createdError.rawValue):pid=\(pid)")
            }
            for handle in worldWindows {
                if let reason = registerWindow(handle.element) {
                    return .degraded(pid: pid, generation: generation, reason: reason)
                }
                trackedWindows[handle.windowId] = handle.element
            }
            return AccessibilityObserverHealth(ready: true, pid: pid, generation: generation,
                windowNotificationsReady: true, degradedReason: nil)
        }

        let windowHealth = bindFocusedWindowNotifications()
        return AccessibilityObserverHealth(
            ready: windowHealth.degradedReason == nil,
            pid: pid,
            generation: generation,
            windowNotificationsReady: windowHealth.windowNotificationsReady,
            degradedReason: windowHealth.degradedReason)
    }

    func detach(generation: UInt64) {
        observationRunLoop.perform { [self] in
            detachOnObservationRunLoop(generation: generation)
        }
    }

    private func detachOnObservationRunLoop(generation: UInt64) {
        if let observer, sourceInstalled {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        applicationElement = nil
        focusedWindowElement = nil
        observedPid = 0
        sourceInstalled = false
        self.generation = generation
        windowGeneration = 0
        trackedWindows.removeAll()
        worldObservation = false
        focusedWindowId = nil
        applicationRegistration = nil
        windowRegistrations.removeAll()
        retiredRegistrations.removeAll()
    }

    private func receive(observer callbackObserver: AXObserver, element: AXUIElement, notification: String,
                         registration: AccessibilityNotificationRegistration) {
        // A removed CFRunLoop source may already have queued a callback. Match
        // the callback's concrete observer identity before stamping the
        // mutable current generation, or an old callback could masquerade as
        // belonging to the newly attached app/Space generation.
        guard let observer, CFEqual(callbackObserver, observer), observedPid > 0,
              registration.observerGeneration == generation else {
            return
        }
        if let id = registration.windowId {
            guard let current = windowRegistrations[id], current === registration,
                  CFEqual(element, registration.element),
                  accessibilityWindowNotificationIsRegistered(notification, notifications: registration.notifications) else { return }
        } else {
            guard applicationRegistration === registration else { return }
        }
        guard trustedProvider() else {
            onHealthChanged?(.degraded(pid: observedPid, generation: generation, reason: "ax_untrusted"))
            return
        }
        let receipt = DispatchTime.now().uptimeNanoseconds
        guard AXUIElementSetMessagingTimeout(element, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            onHealthChanged?(.degraded(pid: observedPid, generation: generation, reason: "ax_notification_timeout_configuration_failed"))
            return
        }
        let kind: AccessibilityFocusEventKind
        var target: AXUIElement? = accessibilityNotificationTarget(notifiedElement: element,
            registeredElement: registration.element, registeredWindowId: registration.windowId)
        switch notification {
        case kAXFocusedWindowChangedNotification:
            if worldObservation { return }
            let notifiedWindow = liveProjectionAXWindowIdentity(element)?.pid == observedPid ? element : nil
            let health = bindFocusedWindowNotifications(notifiedWindow: notifiedWindow)
            onHealthChanged?(health)
            kind = .focusedWindowChanged
            target = focusedWindowElement
        case kAXMovedNotification:
            kind = .focusedWindowMoved
        case kAXResizedNotification:
            kind = .focusedWindowResized
        case kAXUIElementDestroyedNotification:
            kind = .focusedWindowDestroyed
        case kAXWindowMiniaturizedNotification:
            kind = .focusedWindowMinimized
        case kAXWindowDeminiaturizedNotification:
            kind = .focusedWindowRestored
        case kAXWindowCreatedNotification:
            guard worldObservation else { return }
            kind = .windowCreated
            let identity: ProjectionAXWindowIdentity
            switch projectionInventoryWindowIdentity(element: element, pid: observedPid) {
            case .failure(let failure):
                onHealthChanged?(.degraded(pid: observedPid, generation: generation, reason: failure.code))
                return
            case .success(let observed):
                // A positively classified ID-less desktop/pseudo-element has
                // no managed lifecycle identity and must not degrade the source.
                guard let observed else { return }
                identity = observed
            }
            retireWindowRegistration(id: Int64(identity.windowId))
            if let reason = registerWindow(element) {
                onHealthChanged?(.degraded(pid: observedPid, generation: generation, reason: reason))
                return
            }
            trackedWindows[Int64(identity.windowId)] = element
        default:
            return
        }
        let registeredId: Int64?
        if worldObservation {
            registeredId = trackedWindows.first { CFEqual(element, $0.value) }?.key
            guard registeredId != nil else { return }
        } else {
            if kind != .focusedWindowChanged {
                guard let focusedWindowElement, CFEqual(element, focusedWindowElement) else { return }
            }
            registeredId = focusedWindowId
        }
        // Registered window callbacks already carry their exact source ID;
        // the canonical targeted reader validates it before publishing data.
        let identity = registration.windowId == nil
            ? target.flatMap { liveProjectionAXWindowIdentity($0) } : nil
        onEvent?(AccessibilityFocusEvent(
            kind: kind, pid: observedPid, generation: generation,
            windowGeneration: registration.windowId == nil ? windowGeneration : registration.windowGeneration,
            element: target,
            windowId: registration.windowId ?? identity.map { Int64($0.windowId) } ?? registeredId,
            receiptUptimeNs: receipt, isWorldObservation: worldObservation))
        if kind == .focusedWindowDestroyed || kind == .focusedWindowMinimized {
            if worldObservation {
                if kind == .focusedWindowDestroyed, let registeredId {
                    trackedWindows.removeValue(forKey: registeredId)
                    if let old = windowRegistrations.removeValue(forKey: registeredId) {
                        retiredRegistrations.append(old)
                    }
                }
            } else { removeWindowNotifications() }
        }
        if retiredRegistrations.count >= Self.maximumRetiredRegistrations {
            // Replacing the concrete source safely releases old refcons and
            // bounds registration history without a timer or world enumeration.
            let pid = observedPid
            let handles: [ProjectionWindowHandle]? = worldObservation ? trackedWindows.map {
                ProjectionWindowHandle(element: $0.value, pid: pid, windowId: $0.key)
            } : nil
            let health = attachOnObservationRunLoop(to: pid, generation: generation, worldWindows: handles)
            onHealthChanged?(health)
        }
    }

    private func registerWindow(_ window: AXUIElement) -> String? {
        guard let observer else { return "ax_observer_not_attached" }
        guard AXUIElementSetMessagingTimeout(window, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            return "ax_timeout_configuration_failed"
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var rawStructure: CFArray?
        let structureError = AXUIElementCopyMultipleAttributeValues(window,
            [kAXRoleAttribute, kAXSubroleAttribute] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 1), &rawStructure)
        guard structureError == .success else {
            return "ax_window_notification_structure_read_failed:\(structureError.rawValue)"
        }
        guard let structure = rawStructure as? [Any], structure.count == 2 else { return "ax_window_notification_structure_unknown" }
        guard DispatchTime.now().uptimeNanoseconds &- started < TargetedProjectionSnapshot.axTotalReadBudgetNs else {
            return "ax_window_notification_structure_deadline_exceeded"
        }
        let notifications: [String]
        switch accessibilityWindowNotificationNames(role: structure[0] as? String, subrole: structure[1] as? String) {
        case .failure(let failure): return failure.code
        case .success(let names): notifications = names
        }
        guard let identity = liveProjectionAXWindowIdentity(window), identity.pid == observedPid else {
            return "ax_window_registration_identity_unavailable"
        }
        let id = Int64(identity.windowId)
        if let existing = windowRegistrations[id], CFEqual(existing.element, window), existing.notifications == notifications { return nil }
        retireWindowRegistration(id: id)
        windowGeneration &+= 1
        let registration = AccessibilityNotificationRegistration(owner: self,
            observerGeneration: generation, windowGeneration: windowGeneration,
            windowId: id, element: window, notifications: notifications)
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
        let installed = accessibilityRegisterWindowNotificationSlots(notifications, add: {
            AXObserverAddNotification(observer, window, $0 as CFString, refcon)
        }, remove: { _ = AXObserverRemoveNotification(observer, window, $0 as CFString) })
        if case .failure(let failure) = installed {
            retiredRegistrations.append(registration)
            return failure.code
        }
        windowRegistrations[id] = registration
        return nil
    }

    private func retireWindowRegistration(id: Int64) {
        guard let observer, let old = windowRegistrations.removeValue(forKey: id) else { return }
        for notification in old.notifications {
            _ = AXObserverRemoveNotification(observer, old.element, notification as CFString)
        }
        retiredRegistrations.append(old)
    }

    private func removeWindowNotifications() {
        if let id = focusedWindowId { retireWindowRegistration(id: id) }
        focusedWindowElement = nil
        focusedWindowId = nil
    }

    private func bindFocusedWindowNotifications(notifiedWindow: AXUIElement? = nil) -> AccessibilityObserverHealth {
        guard observer != nil, let applicationElement, observedPid > 0 else {
            return .degraded(
                pid: observedPid > 0 ? observedPid : nil,
                generation: generation, reason: "ax_observer_not_attached")
        }

        removeWindowNotifications()
        windowGeneration &+= 1

        var rawFocused: CFTypeRef?
        let focusedError: AXError
        if let notifiedWindow {
            rawFocused = notifiedWindow
            focusedError = .success
        } else {
            // Some app-level focus notifications carry the application rather
            // than its window. Only that representation needs a focused read.
            focusedError = AXUIElementCopyAttributeValue(
                applicationElement, kAXFocusedWindowAttribute as CFString, &rawFocused)
        }
        if focusedError == .noValue
            || (focusedError == .success && rawFocused == nil) {
            // No focused window is valid (desktop, closing transition, or an
            // app with no standard windows). App-level focus observation is
            // still healthy and will bind the next focus immediately. Some
            // apps report success+nil during that same closing transition;
            // every non-success error other than noValue degrades below.
            return AccessibilityObserverHealth(
                ready: true, pid: observedPid, generation: generation,
                windowNotificationsReady: false, degradedReason: nil)
        }
        guard focusedError == .success, let rawFocused,
              CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return .degraded(
                pid: observedPid, generation: generation,
                reason: "ax_focused_window_read_failed:\(focusedError.rawValue)")
        }
        let focused = unsafeDowncast(rawFocused, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(focused, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else {
            return .degraded(pid: observedPid, generation: generation, reason: "ax_timeout_configuration_failed")
        }
        guard let identity = liveProjectionAXWindowIdentity(focused), identity.pid == observedPid else {
            return .degraded(pid: observedPid, generation: generation, reason: "ax_focused_window_identity_unavailable")
        }
        if let reason = registerWindow(focused) {
            return .degraded(pid: observedPid, generation: generation, reason: reason)
        }
        focusedWindowElement = focused
        focusedWindowId = Int64(identity.windowId)
        return AccessibilityObserverHealth(
            ready: true, pid: observedPid, generation: generation,
            windowNotificationsReady: true, degradedReason: nil)
    }
}
