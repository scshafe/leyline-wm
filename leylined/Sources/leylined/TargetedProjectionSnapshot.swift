// @canonical targeted_projection_observation -- notification identity, frame,
// structural eligibility, and independently observed per-display Space context.
// Related: AccessibilityFocusObserver and ProjectionInputFeed. No AX setters,
// external processes, normal-state file reads, or ordinary window enumeration.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LeylineModel

/// A serial observation lane owns this object. Every ordinary event reads its
/// exact target. A complete cache additionally requires all-app lifecycle
/// registration and an independently observed Space for every eligible window.
final class TargetedProjectionSnapshot: @unchecked Sendable {
    static let effectRefreshMessageBudgetNs: UInt64 = 100_000_000
    static let effectRefreshTotalBudgetNs: UInt64 = 200_000_000
    static let axMessageBudgetNs: UInt64 = 100_000_000
    /// The per-message cap in the unit the AX messaging timeout takes.
    static let axReadTimeoutSeconds = Float(Double(axMessageBudgetNs) / 1e9)
    static let axTotalReadBudgetNs: UInt64 = 200_000_000
    /// A cached frame that still matches the live window within a point is the same window.
    static let frameContinuityTolerance = 1.0
    private let trusted: @Sendable () -> Bool
    private let sessionAvailable: @Sendable () -> Bool
    private let sessionGeneration: @Sendable () -> UInt64
    private let reader: any TargetedProjectionWindowReading
    private let spaces: any ProjectionSpaceObserving
    private let spaceEnabled: @Sendable (String) -> Bool
    private let displayTopologyReader: ProjectionDisplayTopologyRead
    private let identityIsCurrent: @Sendable (ProjectionWindowHandle) -> Bool
    private let identityProof: @Sendable (ProjectionWindowHandle) -> Result<Bool, ProjectionObservationFailure>
    private let elementsMatch: @Sendable (AXUIElement, AXUIElement) -> Bool
    private let worldObserver: (any ProjectionWorldObserving)?
    var onWorldEvent: (@Sendable (AccessibilityFocusEvent) -> Void)? {
        didSet {
            worldEventLock.lock()
            worldEventDelivery = onWorldEvent
            worldEventLock.unlock()
            worldObserver?.onEvent = { [weak self] in self?.forwardWorldEvent($0) }
        }
    }
    // Lifecycle sources survive foreground/Space feed rebindings. The lock is
    // only the callback-to-serial-lane bridge; window authority stays on that lane.
    private let worldEventLock = NSLock()
    private var worldEventDelivery: (@Sendable (AccessibilityFocusEvent) -> Void)?
    private var worldObserverGeneration: UInt64 = 0
    private var worldFeedGeneration: UInt64 = 0
    private var worldObservationActive = false
    private var handles: [Int64: ProjectionWindowHandle] = [:]
    private var cachedWindows: [Int64: JSONObject] = [:]
    private var ownerPids: Set<pid_t> = []
    private var observedOwnerPids: Set<pid_t> = []
    private var coveredWindowIds: Set<Int64> = []
    private var cachedTopology: [JSONValue] = []
    private var usableDisplayFrames: [String: Frame] = [:]
    private var focusId: Int64?
    private struct WindowLifetime {
        let pid: pid_t
        let generation: UInt64
    }
    private var windowLifetimes: [Int64: WindowLifetime] = [:]
    private var nextWindowLifetime: UInt64 = 0
    private var latestTargetObservation: JSONObject = [:]
    private var observerGeneration: UInt64 = 0
    private var worldComplete = false
    private var worldFailure: ProjectionObservationFailure? = .init(code: "world_not_seeded")
    private var count: Int64 = 0
    private var fullEnumerations: Int64 = 0
    private var targetedReads: Int64 = 0
    private var failures: Int64 = 0
    private var spaceBaselines: Int64 = 0
    private var displayEnumerations: Int64 = 0
    private var effectHandleRefreshes: Int64 = 0
    private let auditLock = NSLock()
    private var auditActivityRevision: UInt64 = 0
    private var auditEnumerations: Int64 = 0
    private var auditReads: Int64 = 0
    private var auditDisplays: Int64 = 0
    private func markAuditActivity() { auditLock.lock(); auditActivityRevision &+= 1; auditLock.unlock() }
    private var currentAuditRevision: UInt64 { auditLock.lock(); defer { auditLock.unlock() }; return auditActivityRevision }

    /// The canonical lane freezes one valid cohort; collection is strictly read-only and guarded
    /// before each backend call. An unsupported backend cannot certify a clean audit.
    func makeCacheAuditSeed(observerGeneration: UInt64, observationEpoch: UInt64) -> Result<ProjectionCacheAuditSeed, ProjectionObservationFailure> {
        guard sessionAvailable(), trusted(), worldComplete, worldObservationActive, self.observerGeneration == observerGeneration else {
            return .failure(.init(code: "cache_audit_authority_unavailable"))
        }
        guard reader.supportsCacheAudit, let spaceProbe = spaces.makeAuditProbe() else { return .failure(.init(code: "cache_audit_backend_unsupported")) }
        let revision = currentAuditRevision, session = sessionGeneration(), owners = ownerPids
        let observed = cachedWindows, retained = handles, reader = reader, matches = elementsMatch
        let topologyReader = displayTopologyReader, topology = cachedTopology, usable = usableDisplayFrames
        let ignored = retained.values.filter { handle in
            guard let record = observed[handle.windowId], let role = record["role"]?.stringValue, let subrole = record["subrole"]?.stringValue else { return false }
            return role != "AXWindow" || subrole != "AXStandardWindow"
        }
        let expected = Set(observed.filter { $0.value["eligible"]?.boolValue == true }.map(\.key))
        guard !expected.isEmpty else { return .failure(.init(code: "cache_audit_empty_cohort_unsupported")) }
        guard expected.allSatisfy({ id in
            guard let handle = retained[id], let lifetime = windowLifetimes[id], let record = observed[id] else { return false }
            return coveredWindowIds.contains(id) && lifetime.pid == handle.pid && lifetime.generation > 0
                && record["window_generation"]?.intValue == Int64(clamping: lifetime.generation)
        }) else { return .failure(.init(code: "cache_audit_lifetime_authority_unavailable")) }
        let alive: @Sendable () -> Bool = { [self] in
            currentAuditRevision == revision && sessionAvailable() && sessionGeneration() == session && trusted()
        }
        return .success(.init(observerGeneration: observerGeneration, sessionGeneration: session, observationEpoch: observationEpoch,
            activityRevision: revision, isCurrent: alive, collect: { beforeCall, recordCost in
                var enumerations: Int64 = 0, reads: Int64 = 0, displays: Int64 = 0
                func failed(_ failure: ProjectionObservationFailure) -> ProjectionCacheAuditProbe { .init(failure: failure, enumerations: enumerations, reads: reads, displayEnumerations: displays) }
                if let failure = beforeCall() { return failed(failure) }
                displays = 1; recordCost(enumerations, reads, displays)
                switch topologyReader(usable, beforeCall) {
                case .failure(let failure): return failed(failure)
                case .success(let current):
                    guard current == topology else { return failed(.init(code: "cache_audit_topology_changed")) }
                }
                enumerations = 1; recordCost(enumerations, reads, displays)
                let inventory: ProjectionWindowInventory
                switch reader.auditInventory(ignored: ignored, beforeExternalCall: beforeCall) {
                case .failure(let failure): return failed(failure)
                case .success(let value): inventory = value
                }
                guard inventory.ownerPids == owners else { return failed(.init(code: "cache_audit_owner_cohort_changed")) }
                var actual: Set<Int64> = []
                for handle in inventory.handles.sorted(by: { $0.windowId < $1.windowId }) where inventory.visibleWindowIds.contains(handle.windowId)
                    && !inventory.ignoredWindowIds.contains(handle.windowId) {
                    if let failure = beforeCall() { return failed(failure) }
                    reads += 1; recordCost(enumerations, reads, displays)
                    let window: TargetedWindowObservation
                    switch reader.auditRead(handle: handle, beforeExternalCall: beforeCall) {
                    case .failure(let failure): return failed(failure)
                    case .success(let value): window = value
                    }
                    guard window.windowId == handle.windowId, window.pid == handle.pid else { return failed(.init(code: "cache_audit_read_identity_changed")) }
                    let tileable: JSONValue = .object(["role": .string(window.role), "subrole": .string(window.subrole),
                        "resizable": .bool(window.resizable), "app": .string(window.appName), "title": .string(window.title)])
                    if !window.onscreen || window.minimized || !window.movable || !Autotile.tileable(tileable) { continue }
                    guard actual.insert(window.windowId).inserted, let prior = retained[window.windowId],
                          prior.pid == window.pid, matches(prior.element, handle.element), let record = observed[window.windowId] else {
                        return failed(.init(code: "cache_audit_new_or_changed_identity"))
                    }
                    switch spaceProbe(window.windowId, beforeCall) {
                    case .failure(let failure): return failed(failure)
                    case .success(let context):
                        guard context.visible, context.key == record["space_key"]?.stringValue,
                              context.displayId == record["display_id"]?.stringValue else { return failed(.init(code: "cache_audit_space_changed")) }
                    }
                    guard let priorFrame = Frame.from(record["frame"]), Geometry.frameEq(priorFrame, window.frame, tol: Self.frameContinuityTolerance) else {
                        return failed(.init(code: "cache_audit_frame_changed"))
                    }
                }
                if let failure = beforeCall() { return failed(failure) }
                guard actual == expected else { return failed(.init(code: "cache_audit_managed_cohort_changed")) }
                return .init(failure: nil, enumerations: enumerations, reads: reads, displayEnumerations: displays)
            }))
    }

    /// Observation-lane completion. A clean audit publishes evidence only; uncertain current
    /// evidence fences authority and requests the existing explicit recovery, never a layout replay.
    func finishCacheAudit(seed: ProjectionCacheAuditSeed, probe: ProjectionCacheAuditProbe) -> JSONObject {
        fullEnumerations += probe.enumerations; targetedReads += probe.reads
        auditEnumerations += probe.enumerations; auditReads += probe.reads
        displayEnumerations += probe.displayEnumerations; auditDisplays += probe.displayEnumerations
        let current = seed.isCurrent() && self.observerGeneration == seed.observerGeneration
        let superseded = !current || probe.failure?.code == "cache_audit_superseded"
        let status = superseded ? "superseded" : probe.failure == nil ? "clean" : "failed"
        var delta: JSONObject = ["event": .string("cache_audit_completed"), "cache_audit_requires_recovery": .bool(false), "cache_integrity": .object([
            "status": .string(status), "failure_code": probe.failure.map { .string($0.code) } ?? .null,
            "enumeration_count": .int(auditEnumerations), "targeted_read_count": .int(auditReads),
            "display_enumeration_count": .int(auditDisplays),
            "observer_generation": .int(Int64(clamping: seed.observerGeneration)), "session_generation": .int(Int64(clamping: seed.sessionGeneration)),
            "observation_epoch": .int(Int64(clamping: seed.observationEpoch)), "activity_revision": .int(Int64(clamping: seed.activityRevision))])]
        if !superseded, let failure = probe.failure {
            markAuditActivity(); revokeWorldObservation(failure, generation: seed.observerGeneration)
            delta["focus"] = .null
            delta["observation"] = .object(["world_complete": .bool(false), "failure_code": .string(failure.code), "world_failure_code": .string(failure.code),
                "session_generation": .int(Int64(clamping: sessionGeneration()))])
            delta["cache_audit_requires_recovery"] = .bool(true)
        }
        return delta
    }

    convenience init(trustedProvider: @escaping @Sendable () -> Bool,
                     spaceEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
                     sessionAvailable: @escaping @Sendable () -> Bool = { true },
                     sessionGeneration: @escaping @Sendable () -> UInt64 = { 0 }) {
        let spaces = IndependentProjectionSpaceObserver()
        self.init(trusted: trustedProvider,
                  reader: LiveTargetedProjectionWindowReader(sessionAvailable: sessionAvailable,
                      nonDesktopOnly: { [spaces] in spaces.nonDesktopOnlyWindowIds($0) }),
                  spaces: spaces, spaceEnabled: spaceEnabled,
                  worldObserver: AccessibilityWorldObserver(trustedProvider: { trustedProvider() && sessionAvailable() }),
                  sessionAvailable: sessionAvailable, sessionGeneration: sessionGeneration)
    }

    init(trusted: @escaping @Sendable () -> Bool,
         reader: any TargetedProjectionWindowReading,
         spaces: any ProjectionSpaceObserving,
         spaceEnabled: @escaping @Sendable (String) -> Bool = { _ in true },
         worldObserver: (any ProjectionWorldObserving)? = nil,
         identityIsCurrent: (@Sendable (ProjectionWindowHandle) -> Bool)? = nil,
         elementsMatch: @escaping @Sendable (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) },
         sessionAvailable: @escaping @Sendable () -> Bool = { true },
         sessionGeneration: @escaping @Sendable () -> UInt64 = { 0 },
         displayTopologyReader: @escaping ProjectionDisplayTopologyRead = projectionReadDisplayTopology) {
        self.trusted = trusted
        self.sessionAvailable = sessionAvailable
        self.sessionGeneration = sessionGeneration
        self.reader = reader
        self.spaces = spaces
        self.spaceEnabled = spaceEnabled
        self.displayTopologyReader = displayTopologyReader
        self.worldObserver = worldObserver
        let proof: @Sendable (ProjectionWindowHandle) -> Result<Bool, ProjectionObservationFailure>
        if let identityIsCurrent { proof = { .success(identityIsCurrent($0)) } }
        else { proof = { handle in
            liveProjectionAXWindowIdentityResult(handle.element).map {
                $0 == ProjectionAXWindowIdentity(windowId: CGWindowID(handle.windowId), pid: handle.pid)
            }
        } }
        self.identityProof = proof
        self.identityIsCurrent = { handle in
            if case .success(true) = proof(handle) { return true }
            return false
        }
        self.elementsMatch = elementsMatch
    }

    private func forwardWorldEvent(_ event: AccessibilityFocusEvent) {
        worldEventLock.lock()
        let delivery = worldEventDelivery
        let feedGeneration = worldFeedGeneration
        let admitted = worldObservationActive && event.generation == worldObserverGeneration
        worldEventLock.unlock()
        guard admitted, sessionAvailable() else { return }
        delivery?(AccessibilityFocusEvent(kind: event.kind, pid: event.pid, generation: feedGeneration,
            windowGeneration: event.windowGeneration, element: event.element, windowId: event.windowId,
            receiptUptimeNs: event.receiptUptimeNs, isWorldObservation: true, degradedReason: event.degradedReason,
            sourceObserverGeneration: event.generation))
    }

    private func updateWorldFeedGeneration(_ generation: UInt64) {
        worldEventLock.lock()
        worldFeedGeneration = generation
        worldEventLock.unlock()
    }

    /// A stopped source cannot distinguish a survivor from same-PID ID reuse.
    /// Retire its tokens before recovery, including windows absent from a cache.
    private func revokeWorldObservation(_ failure: ProjectionObservationFailure, generation: UInt64) {
        worldEventLock.lock()
        worldObservationActive = false
        worldFeedGeneration = generation
        worldEventLock.unlock()
        worldObserver?.stop(generation: worldObserverGeneration)
        worldComplete = false
        worldFailure = failure
        focusId = nil
        cachedWindows.removeAll()
        handles.removeAll()
        ownerPids.removeAll()
        observedOwnerPids.removeAll()
        coveredWindowIds.removeAll()
        windowLifetimes.removeAll()
    }

    /// Retire a window and record the failure that leaves the world incomplete.
    private func failWindow(_ id: Int64, _ failure: ProjectionObservationFailure) -> ProjectionObservationFailure {
        retireWindow(id)
        worldComplete = false
        worldFailure = failure
        return failure
    }

    /// The session-lock failure when the session changed or locked since `session`; nil while it is current.
    private func sessionFence(_ session: UInt64) -> ProjectionObservationFailure? {
        guard sessionAvailable(), sessionGeneration() == session else {
            sessionUnavailable()
            return .init(code: "session_locked")
        }
        return nil
    }

    private func retireWindow(_ id: Int64) {
        windowLifetimes.removeValue(forKey: id)
        handles.removeValue(forKey: id)
        cachedWindows.removeValue(forKey: id)
        coveredWindowIds.remove(id)
        if focusId == id { focusId = nil }
    }

    /// Resolves an already observed member without enumeration. Failure revokes
    /// authorization: no stale AX wrapper, recycled ID, or old context is used.
    var windowGenerations: [String: UInt64] {
        Dictionary(uniqueKeysWithValues: cachedWindows.keys.compactMap { id in
            windowLifetimes[id].map { (String(id), $0.generation) }
        })
    }

    func resolveWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        markAuditActivity()
        let session = sessionGeneration()
        guard sessionAvailable() else {
            sessionUnavailable()
            return .failure(.init(code: "session_locked"))
        }
        guard trusted() else {
            let failure = ProjectionObservationFailure(code: "ax_untrusted")
            revokeWorldObservation(failure, generation: observerGeneration)
            return .failure(failure)
        }
        guard observerGeneration == self.observerGeneration else {
            return .failure(.init(code: "window_resolver_generation_mismatch"))
        }
        if let expectedWindowGeneration, windowLifetimes[windowId]?.generation != expectedWindowGeneration {
            return .failure(.init(code: "window_resolver_lifetime_generation_mismatch"))
        }
        guard worldComplete, worldObservationActive, coveredWindowIds.contains(windowId), let handle = handles[windowId],
              let record = cachedWindows[windowId], record["eligible"]?.boolValue == true,
              record["space_visible"]?.boolValue == true,
              let key = record["space_key"]?.stringValue, spaceEnabled(key) else {
            return .failure(.init(code: "window_resolver_authority_unavailable"))
        }
        guard AXUIElementSetMessagingTimeout(handle.element, Self.axReadTimeoutSeconds) == .success else {
            return .failure(.init(code: "ax_timeout_configuration_failed"))
        }
        let identityFailure: ProjectionObservationFailure?
        switch identityProof(handle) {
        case .success(true): identityFailure = nil
        case .success(false): identityFailure = .init(code: "window_resolver_identity_changed")
        case .failure(let failure): identityFailure = failure
        }
        if let identityFailure { return .failure(failWindow(windowId, identityFailure)) }
        if let locked = sessionFence(session) { return .failure(locked) }
        switch spaces.context(windowId: windowId) {
        case .failure(let failure):
            return .failure(failWindow(windowId, failure))
        case .success(let context):
            guard context.key == key, context.displayId == record["display_id"]?.stringValue,
                  context.visible, spaceEnabled(context.key) else {
                return .failure(failWindow(windowId, .init(code: "window_resolver_space_changed")))
            }
        }
        if let locked = sessionFence(session) { return .failure(locked) }
        return .success(handle)
    }

    #if LEYLINE_BUILD_TESTS
    /// Developer checks read an observation without its handle; production
    /// effects go through `readWindowWithHandle` so the setter handle and the
    /// read pass one admission gate.
    func readWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<TargetedWindowObservation, ProjectionObservationFailure> {
        readWindowWithHandle(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration).map(\.observation)
    }
    #endif

    /// Canonical read/handle pairing. A caller that needs a setter handle must not resolve again
    /// around this read: the returned handle passed the same lifetime/session/Space admission gate.
    func readWindowWithHandle(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64? = nil)
        -> Result<ProjectionWindowReadback, ProjectionObservationFailure> {
        let session = sessionGeneration()
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle):
            targetedReads += 1
            let result = reader.read(element: handle.element, pid: handle.pid, expectedWindowId: windowId)
            if let locked = sessionFence(session) { return .failure(locked) }
            switch result {
            case .failure(let failure):
                return .failure(failWindow(windowId, failure))
            case .success(let window):
                guard window.windowId == windowId, window.pid == handle.pid else {
                    return .failure(failWindow(windowId, .init(code: "ax_notification_identity_mismatch")))
                }
                let request = ProjectionSnapshotRequest(reason: "effect_readback", application: nil,
                    observerGeneration: observerGeneration, accessibilityEvent: nil)
                switch windowObject(window, request: request, appName: cachedWindows[windowId]?["app"]?.stringValue ?? "") {
                case .success(let object): cachedWindows[windowId] = object
                case .failure(let failure):
                    return .failure(failWindow(windowId, failure))
                }
                return .success(.init(handle: handle, observation: window, observerGeneration: observerGeneration,
                                      completedUptimeNs: DispatchTime.now().uptimeNanoseconds))
            }
        }
    }

    /// A once-per-effect repair preserves its concrete lifecycle source and lifetime. This method
    /// never rebuilds the world or replaces an unequal AX element using only matching PID/CG IDs.
    func refreshEffectWindow(windowId: Int64, observerGeneration: UInt64, expectedWindowGeneration: UInt64)
        -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        let session = sessionGeneration()
        let retained: ProjectionWindowHandle
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle): retained = handle
        }
        guard expectedWindowGeneration > 0, let prior = cachedWindows[windowId] else {
            return .failure(.init(code: "effect_refresh_lifetime_unavailable"))
        }
        effectHandleRefreshes += 1
        let fresh: ProjectionWindowHandle
        switch reader.freshWindowHandle(pid: retained.pid, windowId: windowId) {
        case .failure(let failure): return .failure(failure)
        case .success(let handle): fresh = handle
        }
        guard fresh.pid == retained.pid, fresh.windowId == windowId,
              elementsMatch(retained.element, fresh.element) else {
            return .failure(.init(code: "effect_refresh_registered_identity_changed"))
        }
        switch identityProof(fresh) {
        case .failure(let failure): return .failure(failure)
        case .success(false): return .failure(.init(code: "effect_refresh_fresh_identity_changed"))
        case .success(true): break
        }
        targetedReads += 1
        let observed: TargetedWindowObservation
        switch reader.read(element: fresh.element, pid: fresh.pid, expectedWindowId: windowId) {
        case .failure(let failure): return .failure(failure)
        case .success(let window): observed = window
        }
        if let locked = sessionFence(session) { return .failure(locked) }
        guard observed.windowId == windowId, observed.pid == retained.pid else {
            return .failure(.init(code: "effect_refresh_read_identity_changed"))
        }
        switch resolveWindow(windowId: windowId, observerGeneration: observerGeneration,
                             expectedWindowGeneration: expectedWindowGeneration) {
        case .failure(let failure): return .failure(failure)
        case .success(let current):
            guard elementsMatch(current.element, retained.element) else {
                return .failure(.init(code: "effect_refresh_retained_identity_changed"))
            }
        }
        let request = ProjectionSnapshotRequest(reason: "effect_handle_refresh", application: nil,
            observerGeneration: observerGeneration, accessibilityEvent: nil)
        let object: JSONObject
        switch windowObject(observed, request: request, appName: prior["app"]?.stringValue ?? "") {
        case .failure(let failure): return .failure(failure)
        case .success(let value): object = value
        }
        guard trusted(), sessionAvailable(), sessionGeneration() == session,
              self.observerGeneration == observerGeneration,
              windowLifetimes[windowId]?.generation == expectedWindowGeneration,
              object["eligible"]?.boolValue == true, object["space_visible"]?.boolValue == true,
              object["space_enabled"]?.boolValue == true,
              object["space_key"] == prior["space_key"], object["display_id"] == prior["display_id"] else {
            return .failure(.init(code: "effect_refresh_context_changed"))
        }
        handles[windowId] = fresh; cachedWindows[windowId] = object
        return .success(fresh)
    }

    func stop() {
        markAuditActivity()
        revokeWorldObservation(.init(code: "world_observation_stopped"), generation: observerGeneration)
    }

    /// The observation lane retires every pre-lock lifetime even when unlock
    /// arrived before this queued revocation ran. Usable-frame configuration is
    /// retained; the next recovery obtains a new window/Space/display baseline.
    func sessionUnavailable() {
        markAuditActivity()
        revokeWorldObservation(.init(code: "session_locked"), generation: observerGeneration)
        cachedTopology.removeAll()
        latestTargetObservation = [:]
        count = 0
    }

    /// AppKit owns usable insets. The main-thread adapter supplies fresh CG
    /// coordinates on bootstrap/display changes; absence remains unavailable.
    func setUsableDisplayFrames(_ frames: [String: Frame]) {
        markAuditActivity()
        usableDisplayFrames = frames
        guard sessionAvailable() else { sessionUnavailable(); return }
        cachedTopology = captureDisplayTopology()
        if cachedTopology.isEmpty {
            revokeWorldObservation(.init(code: "world_display_topology_unavailable"), generation: observerGeneration)
        }
    }

    func capture(_ request: ProjectionSnapshotRequest) -> ProjectionWorldSnapshot {
        markAuditActivity()
        let started = DispatchTime.now().uptimeNanoseconds
        let session = sessionGeneration()
        latestTargetObservation = [:]
        updateWorldFeedGeneration(request.observerGeneration)
        var error: ProjectionObservationFailure?
        let isSweep = WorldEvent.sweep.contains(request.reason)
        var refreshedWorld = isSweep
        var activationRecovery = false
        if !sessionAvailable() {
            sessionUnavailable()
            error = worldFailure
        } else if !trusted() {
            revokeWorldObservation(.init(code: "ax_untrusted"), generation: request.observerGeneration)
            error = worldFailure
        } else {
            if isSweep {
                rebaselineWorld(request)
            } else if let terminated = request.lifecyclePid {
                cachedWindows = cachedWindows.filter { $0.value["pid"]?.intValue != Int64(terminated) }
                handles = handles.filter { $0.value.pid != terminated }
                ownerPids.remove(terminated)
                windowLifetimes = windowLifetimes.filter { $0.value.pid != terminated }
                refreshedWorld = true
                refreshWorld(request)
            } else if observerGeneration != request.observerGeneration, !handles.isEmpty || !ownerPids.isEmpty {
                rebindWorldObserver(generation: request.observerGeneration)
            }
            #if LEYLINE_BUILD_TESTS
            // Developer checks republish cached state to read counters; it supplies no receipt or read.
            let republishOnly = request.reason == "telemetry"
            #else
            let republishOnly = false
            #endif
            if request.reason == "app_activated", !worldComplete {
                // An activation is independent lifecycle evidence, not an AX
                // retry. Replace a partial cache with one complete observation;
                // every unvalidated prior handle keeps its retired lifetime.
                latestTargetObservation["world_recovery_reason"] = worldFailure.map { .string($0.code) } ?? .null
                activationRecovery = true
                refreshedWorld = true
                rebaselineWorld(request)
            }
            observerGeneration = request.observerGeneration
            if !worldObservationActive || (refreshedWorld && !worldComplete) {
                // A focused read cannot certify a failed inventory or restore
                // lifetime authority after its lifecycle source was stopped.
                error = worldFailure
            } else if let event = request.accessibilityEvent {
                latestTargetObservation = [
                    "source_observer_generation": (event.sourceObserverGeneration
                        ?? (event.isWorldObservation ? nil : event.generation)).map { .int(Int64(clamping: $0)) } ?? .null,
                    "admission_observer_generation": .int(Int64(clamping: request.observerGeneration)),
                    "source_receipt_uptime_ns": .int(Int64(clamping: event.receiptUptimeNs)),
                ]
                if let sourceGeneration = event.sourceObserverGeneration,
                   sourceGeneration != worldObserverGeneration || !worldObservationActive {
                    error = .init(code: "world_notification_source_generation_mismatch")
                } else if event.kind == .worldObserverDegraded {
                    revokeWorldObservation(.init(code: event.degradedReason ?? "ax_world_observer_degraded"),
                                           generation: request.observerGeneration)
                    error = worldFailure
                } else if event.kind == .focusedWindowDestroyed || event.kind == .focusedWindowMinimized {
                    if let id = event.windowId {
                        // A late destroyed/minimized callback must identify the
                        // retained concrete window, rather than only a reused ID.
                        if let prior = handles[id],
                           (prior.pid != event.pid || event.element == nil
                            || !elementsMatch(prior.element, event.element!)) {
                            error = .init(code: "lifecycle_notification_identity_mismatch")
                        } else if event.kind == .focusedWindowDestroyed {
                            retireWindow(id)
                        } else if var record = cachedWindows[id] {
                            record["minimized"] = .bool(true)
                            record["eligible"] = .bool(false)
                            record["managed"] = .bool(false)
                            cachedWindows[id] = record
                        }
                        if error == nil, focusId == id { focusId = nil }
                    } else {
                        worldComplete = false
                        worldFailure = .init(code: "lifecycle_notification_identity_missing")
                        focusId = nil
                        error = worldFailure
                    }
                } else if event.kind == .focusedWindowChanged, event.element == nil {
                    focusId = nil
                } else {
                    error = updateTarget(element: event.element, pid: event.pid,
                                         expectedId: event.windowId, request: request,
                                         becomesFocus: !event.isWorldObservation)
                }
            } else if republishOnly {
            } else if request.reason == "ax_observer_degraded" {
                focusId = nil
                error = .init(code: "ax_observer_degraded")
            } else if let application = request.application {
                switch reader.focusedElement(pid: application.pid) {
                case .failure(let failure): focusId = nil; error = failure
                case .success(let element):
                    if let element {
                        error = updateTarget(element: element, pid: application.pid, expectedId: nil,
                                             request: request, becomesFocus: true)
                    } else { focusId = nil }
                }
            } else { focusId = nil }
        }
        latestTargetObservation["inventory_is_cached"] = .bool(!refreshedWorld
            && latestTargetObservation["ignored_retained_cohort_validation_performed"]?.boolValue != true)
        if !sessionAvailable() || sessionGeneration() != session {
            sessionUnavailable()
            error = worldFailure
        }
        latestTargetObservation["world_recovered"] = .bool(activationRecovery && worldComplete && error == nil)
        if error != nil { failures += 1 }
        count = Int64(cachedWindows.values.filter { $0["onscreen"]?.boolValue == true && $0["minimized"]?.boolValue != true }.count)
        let focus = error == nil && worldComplete
            ? focusId.flatMap { cachedWindows[$0] }.map(JSONValue.object) ?? .null : .null
        return snapshot(request, focus: focus, error: error, started: started, session: session)
    }

    /// The window server reports a window joining or leaving a Space, including a
    /// Mission Control move that raises no AX or workspace event. A cached window
    /// now on another Space owes a sweep; one on no Space was destroyed, which the
    /// AX lifecycle reports.
    func windowChangedSpace(windowId: Int64) -> Bool {
        guard sessionAvailable(), trusted(), worldObservationActive, worldComplete,
              let row = cachedWindows[windowId], row["space_identity_available"]?.boolValue == true else { return false }
        switch spaces.context(windowId: windowId) {
        case .success(let context):
            return context.key != row["space_key"]?.stringValue || context.visible != row["space_visible"]?.boolValue
        case .failure:
            return spaces.occupiesSpace(windowId: windowId)
        }
    }

    private func refreshWorld(_ request: ProjectionSnapshotRequest) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        worldComplete = false
        worldFailure = nil
        let priorHandles = handles
        let priorSourceGeneration = worldObservationActive ? worldObserverGeneration : nil
        cachedWindows.removeAll()
        handles.removeAll()
        observerGeneration = request.observerGeneration
        fullEnumerations += 1
        switch reader.inventory(enrollOwners: { [self] owners in
            guard sessionAvailable() else { return .failure(.init(code: "session_locked")) }
            guard let worldObserver else { return .failure(.init(code: "world_lifecycle_observer_unavailable")) }
            if worldObservationActive, owners == observedOwnerPids { return .success(()) }
            revokeWorldObservation(.init(code: "world_observation_membership_changed"), generation: request.observerGeneration)
            worldFailure = nil
            worldEventLock.lock()
            worldObserverGeneration &+= 1
            worldObservationActive = true
            worldEventLock.unlock()
            let result = worldObserver.begin(ownerPids: owners, generation: worldObserverGeneration)
            if case .success = result { observedOwnerPids = owners }
            return result
        }) {
        case .failure(let failure):
            revokeWorldObservation(failure, generation: request.observerGeneration)
            return
        case .success(let inventory):
            let presentIds = Set(inventory.handles.map(\.windowId))
            // A recovery survivor needs an actual retained handle and uninterrupted
            // lifecycle coverage. Matching PID/ID alone never preserves a token.
            windowLifetimes = windowLifetimes.filter { id, lifetime in
                let fresh = inventory.handles.filter { $0.windowId == id }
                guard priorSourceGeneration == worldObserverGeneration, worldObservationActive,
                      presentIds.contains(id), let prior = priorHandles[id],
                      prior.pid == lifetime.pid, coveredWindowIds.contains(id), fresh.count == 1,
                      fresh[0].pid == lifetime.pid, elementsMatch(fresh[0].element, prior.element) else { return false }
                return identityIsCurrent(prior)
            }
            ownerPids = inventory.ownerPids
            for handle in inventory.handles {
                guard sessionAvailable() else { sessionUnavailable(); return }
                handles[handle.windowId] = handle
                targetedReads += 1
                let read = reader.read(element: handle.element, pid: handle.pid, expectedWindowId: handle.windowId)
                guard sessionAvailable() else { sessionUnavailable(); return }
                switch read {
                case .failure(let failure):
                    retireWindow(handle.windowId)
                    worldFailure = worldFailure ?? failure
                case .success(let window):
                    guard window.windowId == handle.windowId, window.pid == handle.pid else {
                        retireWindow(handle.windowId)
                        worldFailure = worldFailure ?? .init(code: "ax_inventory_identity_changed_during_read")
                        continue
                    }
                    switch windowObject(window, request: request, appName: "") {
                    case .failure(let failure):
                        retireWindow(handle.windowId)
                        worldFailure = worldFailure ?? failure
                    case .success(let object): cachedWindows[window.windowId] = object
                    }
                }
            }
            guard inventory.visibleWindowIds.subtracting(Set(cachedWindows.keys)).isEmpty else {
                worldFailure = worldFailure ?? .init(code: "world_visible_window_set_incomplete")
                return
            }
            rebindWorldObserver(generation: request.observerGeneration)
        }
        cachedTopology = captureDisplayTopology()
        if cachedTopology.isEmpty {
            revokeWorldObservation(.init(code: "world_display_topology_unavailable"), generation: request.observerGeneration)
        }
    }

    private func rebaselineWorld(_ request: ProjectionSnapshotRequest) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        spaceBaselines += 1
        switch spaces.rebaseline() {
        case .failure(let failure): revokeWorldObservation(failure, generation: request.observerGeneration)
        case .success: refreshWorld(request)
        }
    }

    private func rebindWorldObserver(generation: UInt64) {
        guard sessionAvailable() else { sessionUnavailable(); return }
        guard let worldObserver else {
            revokeWorldObservation(.init(code: "world_lifecycle_observer_unavailable"), generation: generation)
            return
        }
        if !worldObservationActive || ownerPids != observedOwnerPids {
            revokeWorldObservation(.init(code: "world_lifecycle_observer_authority_unavailable"), generation: generation)
            return
        }
        // Owner changes force the observer implementation to replace concrete
        // sources, ending continuity for every prior lifetime.
        let invalid = handles.keys.sorted().filter { id in handles[id].map { !identityIsCurrent($0) } ?? true }
        let onlyIgnored = !invalid.isEmpty && invalid.allSatisfy { id in
            guard let row = cachedWindows[id] else { return false }
            return row["eligible"]?.boolValue == false && row["managed"]?.boolValue == false
                && row["role"]?.stringValue == "AXWindow"
                && ["AXDialog", "AXSystemDialog", "AXHelpTag"].contains(row["subrole"]?.stringValue ?? "")
        }
        if invalid.contains(where: { id in
            guard let row = cachedWindows[id], row["role"]?.stringValue == "AXWindow" else { return true }
            return !["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXHelpTag"].contains(row["subrole"]?.stringValue ?? "")
        }) {
            revokeWorldObservation(.init(code: "ax_retained_unclassified_identity_unavailable"), generation: generation)
            return
        }
        if onlyIgnored {
            switch validateIgnoredRetirement(Set(invalid), generation: generation) {
            case .success:
                latestTargetObservation["ignored_retained_window_ids"] = .array(invalid.map(JSONValue.int))
                for id in invalid { retireWindow(id) }
            case .failure(let failure):
                latestTargetObservation["ignored_retained_validation_failure"] = .string(failure.code)
                revokeWorldObservation(failure, generation: generation)
                return
            }
        }
        var retiredIdentities: [JSONValue] = []
        for id in onlyIgnored ? [] : invalid {
            guard let prior = handles[id], let lifetime = windowLifetimes[id] else { continue }
            retiredIdentities.append(.object(["window_id": .int(id), "pid": .int(Int64(prior.pid)),
                "window_generation": .int(Int64(clamping: lifetime.generation))]))
            retireWindow(id)
            worldFailure = worldFailure ?? .init(code: "ax_retained_window_identity_unavailable:id=\(id),pid=\(prior.pid)")
        }
        if !retiredIdentities.isEmpty {
            latestTargetObservation["retired_window_identities"] = .array(retiredIdentities)
        }
        let inventory = ProjectionWindowInventory(handles: Array(handles.values),
            visibleWindowIds: Set(cachedWindows.values.filter { $0["onscreen"]?.boolValue == true }.compactMap { $0["window_id"]?.intValue }),
            ownerPids: ownerPids)
        switch worldObserver.replace(inventory: inventory, generation: worldObserverGeneration) {
        case .failure(let failure): revokeWorldObservation(failure, generation: generation)
        case .success:
            coveredWindowIds.formUnion(handles.keys)
            worldComplete = worldFailure == nil
        }
        for id in cachedWindows.keys {
            cachedWindows[id]?["observer_generation"] = .int(Int64(clamping: generation))
        }
        observerGeneration = generation
    }

    /// A dead positively ignored AX row may disappear without ending managed
    /// authority. Prove the current live cohort first; never infer identity from
    /// frame/z-order, refresh a managed wrapper, or carry a token through failure.
    private func validateIgnoredRetirement(_ retired: Set<Int64>, generation: UInt64) -> Result<Void, ProjectionObservationFailure> {
        let source = worldObserverGeneration, session = sessionGeneration(), started = DispatchTime.now().uptimeNanoseconds
        let topology = cachedTopology, usable = usableDisplayFrames
        let guardRead: ProjectionAuditGuard = { [self] in
            guard sessionAvailable(), sessionGeneration() == session, trusted(), worldObservationActive, worldObserverGeneration == source,
                  worldFeedGeneration == generation, cachedTopology == topology, usableDisplayFrames == usable,
                  worldComplete, worldFailure == nil else { return .init(code: "ignored_retained_authority_unavailable") }
            return projectionAXReadBudgetAllowsCall(started: started, now: DispatchTime.now().uptimeNanoseconds)
                ? nil : .init(code: "ignored_retained_validation_deadline")
        }
        fullEnumerations += 1
        latestTargetObservation["inventory_is_cached"] = .bool(false)
        latestTargetObservation["ignored_retained_cohort_validation_performed"] = .bool(true)
        let ignored = retired.compactMap { handles[$0] }
        let inventory: ProjectionWindowInventory
        switch reader.auditInventory(ignored: ignored, beforeExternalCall: guardRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): inventory = value
        }
        guard inventory.ownerPids == ownerPids, ownerPids == observedOwnerPids, retired.isDisjoint(with: inventory.visibleWindowIds),
              Set(inventory.handles.map(\.windowId)).count == inventory.handles.count,
              inventory.handles.allSatisfy({ $0.windowId > 0 && $0.pid > 0 && !retired.contains($0.windowId) }) else {
            return .failure(.init(code: "ignored_retained_inventory_owner_or_alias_changed"))
        }
        displayEnumerations += 1
        switch displayTopologyReader(usable, guardRead) {
        case .failure(let failure): return .failure(failure)
        case .success(let current):
            guard current == topology else { return .failure(.init(code: "ignored_retained_display_topology_changed")) }
        }
        let expected = Set(cachedWindows.filter { _, row in row["eligible"]?.boolValue == true
            && row["onscreen"]?.boolValue == true && row["space_visible"]?.boolValue == true }.keys)
        var actual: Set<Int64> = []
        var newIgnored: [(ProjectionWindowHandle, TargetedWindowObservation)] = []
        for fresh in inventory.handles {
            if let failure = guardRead() { return .failure(failure) }
            let window: TargetedWindowObservation
            targetedReads += 1
            switch reader.auditRead(handle: fresh, beforeExternalCall: guardRead) {
            case .failure(let failure): return .failure(failure)
            case .success(let value): window = value
            }
            guard window.windowId == fresh.windowId, window.pid == fresh.pid else {
                return .failure(.init(code: "ignored_retained_inventory_identity_changed"))
            }
            let knownIgnored = window.role == "AXWindow" && ["AXDialog", "AXSystemDialog", "AXHelpTag"].contains(window.subrole)
            guard window.role == "AXWindow", window.subrole == "AXStandardWindow" || knownIgnored else {
                return .failure(.init(code: "ignored_retained_inventory_classification_unknown"))
            }
            if let prior = handles[window.windowId] {
                if let failure = guardRead() { return .failure(failure) }
                guard prior.pid == fresh.pid, elementsMatch(prior.element, fresh.element), identityIsCurrent(prior) else {
                    return .failure(.init(code: "ignored_retained_inventory_alias_or_pid_changed"))
                }
            } else {
                guard knownIgnored, cachedWindows[window.windowId] == nil else {
                    return .failure(.init(code: "ignored_retained_inventory_new_managed_identity"))
                }
                newIgnored.append((fresh, window))
            }
            let facts = windowFacts(window, appName: cachedWindows[window.windowId]?["app"]?.stringValue ?? "")
            let eligible = window.movable && !window.minimized && window.onscreen && Autotile.tileable(.object(facts))
            guard eligible else { continue }
            let context: ProjectionSpaceContext
            if let failure = guardRead() { return .failure(failure) }
            switch spaces.context(windowId: window.windowId) {
            case .failure(let failure): return .failure(failure)
            case .success(let value): context = value
            }
            if let failure = guardRead() { return .failure(failure) }
            guard context.visible else { continue }
            actual.insert(window.windowId)
            guard expected.contains(window.windowId), inventory.visibleWindowIds.contains(window.windowId),
                  let prior = handles[window.windowId], let lifetime = windowLifetimes[window.windowId],
                  let row = cachedWindows[window.windowId], coveredWindowIds.contains(window.windowId),
                  prior.pid == fresh.pid, lifetime.pid == fresh.pid, elementsMatch(prior.element, fresh.element),
                  row["pid"]?.intValue == Int64(window.pid), row["window_generation"]?.intValue == Int64(clamping: lifetime.generation),
                  row["space_key"]?.stringValue == context.key, row["display_id"]?.stringValue == context.displayId,
                  row["space_enabled"]?.boolValue == spaceEnabled(context.key) else {
                return .failure(.init(code: "ignored_retained_managed_identity_or_scope_changed"))
            }
        }
        guard actual == expected, guardRead() == nil else {
            return .failure(.init(code: "ignored_retained_managed_cohort_incomplete"))
        }
        let request = ProjectionSnapshotRequest(reason: "app_activated", application: nil, observerGeneration: generation, accessibilityEvent: nil)
        for (handle, window) in newIgnored {
            if let failure = guardRead() { return .failure(failure) }
            switch windowObject(window, request: request, appName: "") {
            case .failure(let failure): return .failure(failure)
            case .success(let row): handles[handle.windowId] = handle; cachedWindows[handle.windowId] = row
            }
        }
        if let failure = guardRead() { return .failure(failure) }
        return .success(())
    }

    private func updateTarget(element: AXUIElement?, pid: pid_t, expectedId: Int64?,
                              request: ProjectionSnapshotRequest, becomesFocus: Bool) -> ProjectionObservationFailure? {
        guard sessionAvailable() else { sessionUnavailable(); return worldFailure }
        targetedReads += 1
        let read = reader.read(element: element, pid: pid, expectedWindowId: expectedId)
        guard sessionAvailable() else { sessionUnavailable(); return worldFailure }
        switch read {
        case .failure(let failure):
            if let expectedId { retireWindow(expectedId) }
            worldComplete = false
            worldFailure = failure
            if becomesFocus || focusId == expectedId { focusId = nil }
            return failure
        case .success(let window):
            guard window.pid == pid, expectedId == nil || expectedId == window.windowId else {
                if let expectedId { retireWindow(expectedId) }
                worldComplete = false
                worldFailure = .init(code: "ax_notification_identity_mismatch")
                focusId = nil
                return worldFailure
            }
            var retainedCanonical: ProjectionWindowHandle?
            if let prior = handles[window.windowId] {
                if request.accessibilityEvent?.isWorldObservation == true,
                   request.accessibilityEvent?.kind != .windowCreated,
                   (prior.pid != pid || element == nil || !elementsMatch(prior.element, element!)) {
                    return .init(code: "ax_notification_retained_handle_mismatch")
                }
                if !worldObservationActive || !coveredWindowIds.contains(window.windowId)
                    || prior.pid != pid || !identityIsCurrent(prior) {
                    windowLifetimes.removeValue(forKey: window.windowId)
                } else if request.accessibilityEvent?.kind != .windowCreated,
                          windowLifetimes[window.windowId]?.pid == pid,
                          let element, elementsMatch(prior.element, element) {
                    // A registered callback may carry the pre-repair equivalent wrapper. Its
                    // immutable capsule remains read evidence; the refreshed setter wrapper wins.
                    retainedCanonical = prior
                }
            } else { windowLifetimes.removeValue(forKey: window.windowId) }
            if let retainedCanonical { handles[window.windowId] = retainedCanonical }
            else if let element { handles[window.windowId] = .init(element: element, pid: pid, windowId: window.windowId) }
            switch windowObject(window, request: request, appName: request.application?.pid == pid ? request.application?.name ?? "" : "") {
            case .failure(let failure):
                retireWindow(window.windowId)
                worldComplete = false
                worldFailure = failure
                if becomesFocus || focusId == window.windowId { focusId = nil }
                return failure
            case .success(let object):
                cachedWindows[window.windowId] = object
                if let event = request.accessibilityEvent {
                    if event.isWorldObservation, event.kind == .windowCreated {
                        coveredWindowIds.insert(window.windowId)
                    }
                    latestTargetObservation.merge([
                        "target_window_id": .int(window.windowId), "target_pid": .int(Int64(window.pid)),
                        "target_receipt_uptime_ns": .int(Int64(clamping: event.receiptUptimeNs)),
                        "target_read_completed_uptime_ns": object["observed_uptime_ns"] ?? .null,
                        "target_read_performed": .bool(true), "target_kind": .string(event.kind.rawValue),
                        "target_registration_generation": .int(Int64(clamping: event.windowGeneration)),
                        "target_source_observer_generation": object["source_observer_generation"] ?? .null,
                        "target_window_generation": object["window_generation"] ?? .null,
                    ], uniquingKeysWith: { _, new in new })
                }
                if becomesFocus { focusId = window.windowId }
                return nil
            }
        }
    }

    private func windowObject(_ window: TargetedWindowObservation, request: ProjectionSnapshotRequest,
                              appName: String) -> Result<JSONObject, ProjectionObservationFailure> {
        let isCreation = request.accessibilityEvent?.kind == .windowCreated
        if isCreation || windowLifetimes[window.windowId]?.pid != window.pid {
            nextWindowLifetime &+= 1
            windowLifetimes[window.windowId] = WindowLifetime(pid: window.pid, generation: nextWindowLifetime)
        }
        var object = windowFacts(window, appName: appName)
        object["observer_generation"] = .int(Int64(request.observerGeneration))
        object["source_observer_generation"] = .int(Int64(clamping: request.accessibilityEvent?.sourceObserverGeneration
            ?? request.accessibilityEvent?.generation ?? worldObserverGeneration))
        object["window_generation"] = .int(Int64(clamping: windowLifetimes[window.windowId]!.generation))
        object["registration_generation"] = .int(Int64(clamping: request.accessibilityEvent?.windowGeneration ?? 0))
        let eligible = window.movable && !window.minimized && window.onscreen
            && Autotile.tileable(.object(object))
        object["eligible"] = .bool(eligible)
        object["managed"] = .bool(eligible)
        switch spaces.context(windowId: window.windowId) {
        case .failure(let failure):
            if eligible { return .failure(failure) }
            object["space_identity_available"] = .bool(false)
            object["space_identity_failure"] = .string(failure.code)
        case .success(let context):
            object["space_key"] = .string(context.key)
            object["display_id"] = .string(context.displayId)
            object["space_visible"] = .bool(context.visible)
            object["space_enabled"] = .bool(spaceEnabled(context.key))
            object["space_identity_source"] = .string("window_server_space_uuid")
            object["space_identity_available"] = .bool(true)
        }
        object["observed_uptime_ns"] = .int(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
        return .success(object)
    }

    private func windowFacts(_ window: TargetedWindowObservation, appName: String) -> JSONObject {
        [
            "window_id": .int(window.windowId), "pid": .int(Int64(window.pid)),
            "app": .string(window.appName.isEmpty ? appName : window.appName), "title": .string(window.title),
            "frame": .object(["x": .double(window.frame.x), "y": .double(window.frame.y),
                              "w": .double(window.frame.w), "h": .double(window.frame.h)]),
            "role": .string(window.role), "subrole": .string(window.subrole),
            "resizable": .bool(window.resizable), "movable": .bool(window.movable),
            "minimized": .bool(window.minimized), "destroyed": .bool(false), "onscreen": .bool(window.onscreen),
        ]
    }

    private func captureDisplayTopology() -> [JSONValue] {
        guard sessionAvailable() else { return [] }
        displayEnumerations += 1
        return (try? displayTopologyReader(usableDisplayFrames, { [self] in sessionAvailable() ? nil : .init(code: "session_locked") }).get()) ?? []
    }

    private func snapshot(_ request: ProjectionSnapshotRequest, focus suppliedFocus: JSONValue,
                          error suppliedError: ProjectionObservationFailure?, started: UInt64,
                          session: UInt64) -> ProjectionWorldSnapshot {
        var focus = suppliedFocus
        var error = suppliedError
        var contexts: [JSONValue] = []
        var activeContext: JSONValue = .null
        if sessionAvailable(), sessionGeneration() == session, trusted(), case .success(let current) = spaces.currentContexts() {
            contexts = current.map { context in
                .object(["space_key": .string(context.key), "display_id": .string(context.displayId),
                         "space_enabled": .bool(spaceEnabled(context.key)), "space_visible": .bool(context.visible),
                         "space_identity_available": .bool(true),
                         "space_identity_source": .string("window_server_space_uuid")])
            }
            if let display = focus.at(path: "display_id")?.stringValue {
                activeContext = contexts.first { $0.at(path: "display_id")?.stringValue == display } ?? .null
            } else if contexts.count == 1 { activeContext = contexts[0] }
        }
        if !sessionAvailable() || sessionGeneration() != session {
            sessionUnavailable()
            error = worldFailure
            focus = .null
            activeContext = .null
            contexts = []
        }
        var observation: JSONObject = [
            "ready": .bool(error == nil), "failure_code": error.map { .string($0.code) } ?? .null,
            "world_complete": .bool(worldComplete), "world_failure_code": worldFailure.map { .string($0.code) } ?? .null,
            "reason": .string(request.reason), "inventory_is_cached": .bool(request.reason != "world_seed"),
            "full_enumeration_count": .int(fullEnumerations), "targeted_read_count": .int(targetedReads),
            "effect_handle_refresh_count": .int(effectHandleRefreshes),
            "cache_audit_enumeration_count": .int(auditEnumerations), "cache_audit_targeted_read_count": .int(auditReads),
            "cache_audit_display_enumeration_count": .int(auditDisplays),
            "failure_count": .int(failures), "space_baseline_count": .int(spaceBaselines),
            "display_enumeration_count": .int(displayEnumerations),
            "session_generation": .int(Int64(clamping: session)),
            "read_started_uptime_ns": .int(Int64(clamping: started)),
            "read_completed_uptime_ns": .int(Int64(clamping: DispatchTime.now().uptimeNanoseconds)),
            "ax_call_timeout_ms": .int(Int64(Self.axMessageBudgetNs / 1_000_000)),
            "ax_total_read_budget_ms": .int(Int64(Self.axTotalReadBudgetNs / 1_000_000)),
            "world_source_observer_generation": worldObservationActive ? .int(Int64(clamping: worldObserverGeneration)) : .null,
            "admission_observer_generation": .int(Int64(clamping: request.observerGeneration)),
            "source_observer_generation": .null,
            "space_identity_source": .string("window_server_space_uuid"),
            "target_window_id": .null, "target_receipt_uptime_ns": .null,
            "target_read_completed_uptime_ns": .null, "target_read_performed": .bool(false), "target_kind": .null,
        ]
        for (key, value) in latestTargetObservation { observation[key] = value }
        return ProjectionWorldSnapshot(windowsOnscreen: count, focus: focus, observation: observation,
           windows: cachedWindows.keys.sorted().compactMap { cachedWindows[$0].map(JSONValue.object) },
           topology: cachedTopology, activeContext: activeContext, spaceContexts: contexts)
    }
}
