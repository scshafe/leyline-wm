import ApplicationServices
import Foundation
import LeylineModel

private final class ResidentAXLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var initialFrames: [String: Frame] = [:]
    private var minimumEvidence: [String: ResidentMinimumEvidence] = [:]
    var timer: DispatchSourceTimer?
    var repairTimer: DispatchSourceTimer?
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func remember(_ frames: [String: Frame]) { lock.lock(); initialFrames = frames; lock.unlock() }
    func initialFrame(_ id: String) -> Frame? { lock.lock(); defer { lock.unlock() }; return initialFrames[id] }
    func rememberMinimum(_ id: String, _ evidence: ResidentMinimumEvidence) { lock.lock(); minimumEvidence[id] = evidence; lock.unlock() }
    func minimum(_ id: String) -> ResidentMinimumEvidence? { lock.lock(); defer { lock.unlock() }; return minimumEvidence[id] }
}

/// A settled frame mismatch is only a repair candidate. Progress or external
/// geometry drift cannot authorize replay, and no candidate establishes a minimum.
func residentFrameRepairCandidate(initial: Frame?, current: Frame, target: Frame) -> Bool {
    guard let initial, Geometry.frameEq(initial, current, tol: 1) else { return false }
    return !Geometry.frameEq(current, target, tol: 2)
}

/// The sole live setter adapter. One worker and one pending launch bound IO
/// across cancellation; every write rechecks the canonical lifetime/authority.
final class ResidentAXPort: ResidentMinimumEvidencePort, @unchecked Sendable {
    private struct Launch: Sendable {
        let request: ResidentEffectRequest
        let frame: Frame
        let lease: ResidentAXLease
        let completion: @Sendable (String?) -> Void
        var repairing = false
    }
    private struct Readback: Sendable {
        let handle: ProjectionWindowHandle
        let observation: TargetedWindowObservation
        let generation: UInt64
        let completedNanos: UInt64
    }
    private struct FocusReadback: Sendable {
        let generation: UInt64
        let completedNanos: UInt64
    }
    private let queue = DispatchQueue(label: "leylined.ax.effects", qos: .userInitiated)
    private let deadlines = DispatchQueue(label: "leylined.ax.evidence.deadlines")
    private let observationQueue: DispatchQueue
    private let snapshots: TargetedProjectionSnapshot
    private let lock = NSLock()
    private var leases: [String: ResidentAXLease] = [:]
    private var pending: Launch?
    private var workerScheduled = false
    private var idleCallbacks: [@Sendable () -> Void] = []
    var isRequestActive: (@Sendable (ResidentEffectRequest) -> Bool)?
    /// Controller proves current epoch, PID, lifetime, Space/display and topology continuity.
    /// A request's original admission generation is retained evidence, never resolver authority.
    var currentObservationGeneration: (@Sendable (ResidentEffectRequest) -> UInt64?)?
    var onFrame: (@Sendable (String, String, Frame, UInt64, UInt64) -> Void)?
    var onMinimumEvidence: (@Sendable (ResidentMinimumEvidence) -> Void)?
    var onFocus: (@Sendable (String, String, UInt64, UInt64) -> Void)?
    var onFocusIssue: (@Sendable (String, UInt64) -> Void)?
    var onDeadline: (@Sendable (UInt64) -> Void)?

    init(snapshots: TargetedProjectionSnapshot, observationQueue: DispatchQueue) {
        self.snapshots = snapshots; self.observationQueue = observationQueue
    }

    func cancel(requestID: String) { finish(requestID: requestID) }
    func cancelAll() {
        lock.lock(); let current = Array(leases.values); leases.removeAll(); lock.unlock()
        for lease in current { lease.cancel(); lease.timer?.cancel(); lease.repairTimer?.cancel() }
    }
    func finish(requestID: String) {
        lock.lock(); let lease = leases.removeValue(forKey: requestID); lock.unlock()
        lease?.cancel(); lease?.timer?.cancel(); lease?.repairTimer?.cancel()
    }
    @discardableResult
    func whenIdle(_ callback: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard idleCallbacks.count < 8 else { lock.unlock(); return false }
        if !workerScheduled && pending == nil { lock.unlock(); callback(); return true }
        idleCallbacks.append(callback)
        lock.unlock()
        return true
    }

    private func allowed(_ launch: Launch) -> Bool {
        !launch.lease.isCancelled && isRequestActive?(launch.request) == true
    }

    private func authorizedGeneration(_ launch: Launch) -> UInt64? {
        guard allowed(launch), let generation = currentObservationGeneration?(launch.request), generation > 0 else { return nil }
        return generation
    }

    private func resolve(_ launch: Launch, windowID: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        observationQueue.sync {
            guard let generation = authorizedGeneration(launch) else {
                return .failure(.init(code: "effect_observation_generation_unavailable"))
            }
            return snapshots.resolveWindow(windowId: windowID, observerGeneration: generation,
                                           expectedWindowGeneration: launch.request.windowGenerations[String(windowID)])
        }
    }

    /// Both resolver and targeted read run at the same canonical observation-queue generation.
    /// The timestamp/generation travel with the result even if another healthy rebind follows it.
    private func read(_ launch: Launch, windowID: Int64) -> Result<Readback, ProjectionObservationFailure> {
        observationQueue.sync {
            guard let generation = authorizedGeneration(launch) else {
                return .failure(.init(code: "effect_observation_generation_unavailable"))
            }
            let lifetime = launch.request.windowGenerations[String(windowID)]
            switch snapshots.readWindowWithHandle(windowId: windowID, observerGeneration: generation,
                                                expectedWindowGeneration: lifetime) {
            case .failure(let failure): return .failure(failure)
            case .success(let observed):
                return .success(Readback(handle: observed.handle, observation: observed.observation,
                    generation: observed.observerGeneration, completedNanos: observed.completedUptimeNs))
            }
        }
    }

    private func refresh(_ launch: Launch, windowID: Int64) -> Result<ProjectionWindowHandle, ProjectionObservationFailure> {
        observationQueue.sync {
            guard let generation = authorizedGeneration(launch) else {
                return .failure(.init(code: "effect_observation_generation_unavailable"))
            }
            guard let lifetime = launch.request.windowGenerations[String(windowID)] else {
                return .failure(.init(code: "window_lifetime_unavailable"))
            }
            return snapshots.refreshEffectWindow(windowId: windowID, observerGeneration: generation,
                expectedWindowGeneration: lifetime)
        }
    }

    func issue(request: ResidentEffectRequest, frame: Frame,
               completion: @escaping @Sendable (String?) -> Void) {
        let lease = ResidentAXLease()
        let launch = Launch(request: request, frame: frame, lease: lease, completion: completion)
        let timer = DispatchSource.makeTimerSource(queue: deadlines)
        timer.schedule(deadline: .now() + .seconds(1))
        timer.setEventHandler { [weak self, weak lease] in
            guard lease?.isCancelled == false else { return }
            self?.onDeadline?(DispatchTime.now().uptimeNanoseconds)
        }
        lease.timer = timer
        let repairTimer: DispatchSourceTimer? = request.effectKind == .frame ? DispatchSource.makeTimerSource(queue: deadlines) : nil
        repairTimer?.schedule(deadline: .now() + .milliseconds(100))
        repairTimer?.setEventHandler { [weak self, weak lease] in
            guard let self, let lease, !lease.isCancelled else { return }
            var repair = Launch(request: request, frame: frame, lease: lease, completion: completion)
            repair.repairing = true
            lock.lock()
            guard leases[request.requestID] === lease, pending == nil else { lock.unlock(); return }
            pending = repair
            let schedule = !workerScheduled
            workerScheduled = true
            lock.unlock()
            if schedule { queue.async { [self] in drain() } }
        }
        lease.repairTimer = repairTimer
        lock.lock()
        if let pending, !pending.lease.isCancelled {
            lock.unlock(); timer.cancel(); timer.resume(); repairTimer?.cancel(); repairTimer?.resume(); completion("ax_launch_queue_full"); return
        }
        leases[request.requestID] = lease
        pending = launch
        let schedule = !workerScheduled
        workerScheduled = true
        lock.unlock()
        timer.resume()
        repairTimer?.resume()
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let launch = pending else {
                workerScheduled = false
                let callbacks = idleCallbacks; idleCallbacks.removeAll()
                lock.unlock()
                for callback in callbacks { callback() }
                return
            }
            pending = nil
            lock.unlock()
            perform(launch)
        }
    }

    private func perform(_ launch: Launch) {
        let request = launch.request
        func fail(_ reason: String) { finish(requestID: request.requestID); launch.completion(reason) }
        guard allowed(launch) else { fail("effect_cancelled"); return }
        let targets = request.frameTargets.isEmpty ? [request.windowID: launch.frame] : request.frameTargets
        var resolved: [String: ProjectionWindowHandle] = [:]
        for id in targets.keys.sorted() {
            guard allowed(launch), let windowID = Int64(id) else { fail("window_identity_invalid"); return }
            let result = resolve(launch, windowID: windowID)
            switch result {
            case .failure(let error): fail(error.code); return
            case .success(let handle): resolved[id] = handle
            }
        }
        if request.requiresFocus, resolved[request.windowID] == nil {
            guard let windowID = Int64(request.windowID) else { fail("window_identity_invalid"); return }
            switch resolve(launch, windowID: windowID) {
            case .failure(let failure): fail(failure.code); return
            case .success(let handle): resolved[request.windowID] = handle
            }
        }
        for id in request.stackTopWindowIDs where resolved[id] == nil {
            guard let windowID = Int64(id) else { fail("stack_front_identity_invalid"); return }
            switch resolve(launch, windowID: windowID) {
            case .failure(let failure): fail(failure.code); return
            case .success(let handle): resolved[id] = handle
            }
        }
        if request.effectKind == .focus {
            guard let handle = resolved[request.windowID], allowed(launch) else { fail("focus_target_invalidated"); return }
            switch raiseAndConfirmFocus(launch, handle: handle) {
            case .failure(let failure): fail(failure.code); return
            case .success(let observed):
                launch.completion(nil)
                if let observed, allowed(launch) {
                    onFocus?(request.requestID, request.windowID, observed.generation, observed.completedNanos)
                }
            }
        } else {
            var sizeWrites: [String: ResidentSizeWriteReceipt] = [:]
            for id in targets.keys.sorted() {
                guard let target = targets[id], let windowID = Int64(id), authorizedGeneration(launch) != nil else {
                    fail("effect_identity_invalidated"); return
                }
                var current: Readback
                switch read(launch, windowID: windowID) {
                case .failure(let failure): fail(failure.code); return
                case .success(let observed): current = observed
                }
                if Geometry.frameEq(current.observation.frame, target, tol: 0.5) { continue }
                let handle: ProjectionWindowHandle
                if launch.repairing {
                    if let first = launch.lease.minimum(id) {
                        let confirmed = ResidentMinimumEvidence(write: first.write, observed: first.observed,
                            observedGeneration: first.observedGeneration, readCompletedNanos: first.readCompletedNanos,
                            confirmationFrame: current.observation.frame, confirmationGeneration: current.generation,
                            confirmationCompletedNanos: current.completedNanos)
                        if ResidentMinimumLearning.settledClampAxes(confirmed) != nil {
                            onMinimumEvidence?(confirmed)
                            continue
                        }
                    }
                    guard residentFrameRepairCandidate(initial: launch.lease.initialFrame(id),
                                                       current: current.observation.frame, target: target) else {
                        fail("effect_repair_geometry_drift"); return
                    }
                    switch refresh(launch, windowID: windowID) {
                    case .failure(let failure): fail(failure.code); return
                    case .success:
                        switch read(launch, windowID: windowID) {
                        case .failure(let failure): fail(failure.code); return
                        case .success(let freshRead): current = freshRead
                        }
                        if Geometry.frameEq(current.observation.frame, target, tol: 0.5) { continue }
                        guard residentFrameRepairCandidate(initial: launch.lease.initialFrame(id),
                                                           current: current.observation.frame, target: target) else {
                            fail("effect_repair_geometry_drift"); return
                        }
                        handle = current.handle
                    }
                } else { handle = current.handle }
                guard let identity = liveProjectionAXWindowIdentity(handle.element),
                      identity.windowId == CGWindowID(handle.windowId), identity.pid == handle.pid else {
                    fail("effect_identity_invalidated"); return
                }
                let before = current.observation.frame
                var move = abs(before.x - target.x) > 0.5 || abs(before.y - target.y) > 0.5
                let resize = abs(before.w - target.w) > 0.5 || abs(before.h - target.h) > 0.5
                var position = CGPoint(x: abs(before.x - target.x) <= 0.5 ? before.x : target.x,
                                       y: abs(before.y - target.y) <= 0.5 ? before.y : target.y)
                var size = CGSize(width: abs(before.w - target.w) <= 0.5 ? before.w : target.w,
                                  height: abs(before.h - target.h) <= 0.5 ? before.h : target.h)
                guard let sizeValue = AXValueCreate(.cgSize, &size), let positionValue = AXValueCreate(.cgPoint, &position) else {
                    fail("ax_frame_value_creation_failed"); return
                }
                guard authorizedGeneration(launch) != nil else { fail("effect_observation_generation_unavailable"); return }
                var positionIssued = false
                func issuePosition() -> String? {
                    guard authorizedGeneration(launch) != nil else { return "effect_invalidated_between_frame_writes" }
                    guard let identity = liveProjectionAXWindowIdentity(current.handle.element),
                          identity.windowId == CGWindowID(handle.windowId), identity.pid == handle.pid else {
                        return "effect_identity_invalidated"
                    }
                    let issueStamp = DispatchTime.now().uptimeNanoseconds
                    let error = AXUIElementSetAttributeValue(current.handle.element, kAXPositionAttribute as CFString, positionValue)
                    guard error == .success else { return "ax_position_issue_failed:\(error.rawValue):window=\(id)" }
                    recordAXWrite(launch, windowID: id, operation: "set_position", timestamp: issueStamp)
                    positionIssued = true
                    // Read the moved rectangle before sizing: a growth
                    // using the old origin can be clamped at display edges.
                    switch read(launch, windowID: windowID) {
                    case .failure(let failure): return failure.code
                    case .success(let observed): current = observed
                    }
                    return nil
                }
                func issueSize() -> String? {
                    guard authorizedGeneration(launch) != nil else { return "effect_invalidated_between_frame_writes" }
                    guard let identity = liveProjectionAXWindowIdentity(current.handle.element),
                          identity.windowId == CGWindowID(handle.windowId), identity.pid == handle.pid else {
                        return "effect_identity_invalidated"
                    }
                    let issueStamp = DispatchTime.now().uptimeNanoseconds
                    let sizeError = AXUIElementSetAttributeValue(current.handle.element, kAXSizeAttribute as CFString, sizeValue)
                    guard sizeError == .success else { return "ax_size_issue_failed:\(sizeError.rawValue):window=\(id)" }
                    recordAXWrite(launch, windowID: id, operation: "set_size", timestamp: issueStamp)
                    if let generation = authorizedGeneration(launch),
                       let lifetime = request.windowGenerations[id], lifetime > 0,
                       let space = request.windowSpaceKeys[id], let display = request.windowDisplayIDs[id],
                       let epoch = request.observerEpoch, !epoch.isEmpty,
                       request.windowPids[id] == Int64(handle.pid) {
                        var axes: Set<ResidentMinimumAxis> = []
                        if abs(before.w - target.w) > 0.5 { axes.insert(.width) }
                        if abs(before.h - target.h) > 0.5 { axes.insert(.height) }
                        sizeWrites[id] = ResidentSizeWriteReceipt(requestID: request.requestID, windowID: id,
                            ownerPID: Int64(handle.pid), windowGeneration: lifetime, observerEpoch: epoch,
                            observerGeneration: generation, spaceKey: space, displayID: display,
                            topologyRevision: request.topologyRevision, before: before, requested: target,
                            axes: axes, completedNanos: DispatchTime.now().uptimeNanoseconds)
                    }
                    return nil
                }
                // Growth needs its legal anchor first. Shrink before moving;
                // then read the actual size/origin because AppKit may constrain
                // or re-anchor the window while applying the size change.
                if resize && move && target.w >= before.w && target.h >= before.h {
                    if let error = issuePosition() { fail(error); return }
                }
                if resize {
                    if let error = issueSize() { fail(error); return }
                    switch read(launch, windowID: windowID) {
                    case .failure(let failure): fail(failure.code); return
                    case .success(let observed):
                        current = observed
                        move = abs(observed.observation.frame.x - target.x) > 0.5
                            || abs(observed.observation.frame.y - target.y) > 0.5
                        ResidentPerformanceTrace.shared.record("size_readback", fields: [
                            "request_id": .string(request.requestID), "window_id": .string(id),
                            "before_frame": before.json, "observed_frame": observed.observation.frame.json,
                            "target_frame": target.json, "position_correction_required": .bool(move),
                            "observer_epoch": request.observerEpoch.map(JSONValue.string) ?? .null,
                            "observer_generation": .int(Int64(clamping: observed.generation)),
                            "boundary": .string("resident_scoped_ax_readback")], timestamp: observed.completedNanos)
                    }
                }
                guard authorizedGeneration(launch) != nil else { fail("effect_invalidated_between_frame_writes"); return }
                if move {
                    if let error = issuePosition() { fail(error); return }
                }
                // Cocoa AX position setters can replay their cached size. A
                // growth anchor still counts when readback says no final move
                // is needed: the earlier size may have used the old origin.
                if resize && positionIssued {
                    if let error = issueSize() { fail(error); return }
                }
            }
            var observed: [(String, Readback)] = []
            for id in targets.keys.sorted() {
                guard let windowID = Int64(id) else { fail("window_identity_invalid"); return }
                switch read(launch, windowID: windowID) {
                case .failure(let failure): fail(failure.code); return
                case .success(let readback): observed.append((id, readback))
                }
            }
            var focus: FocusReadback?
            for id in request.stackTopWindowIDs where !(request.requiresFocus && id == request.windowID) {
                guard let handle = resolved[id] else { fail("stack_front_identity_invalid"); return }
                switch raiseAndConfirmFocus(launch, handle: handle, finalFocus: false) {
                case .failure(let failure): fail(failure.code); return
                case .success: break
                }
            }
            if request.requiresFocus {
                guard let handle = resolved[request.windowID] else { fail("focus_target_invalidated"); return }
                switch raiseAndConfirmFocus(launch, handle: handle) {
                case .failure(let failure): fail(failure.code); return
                case .success(let observed): focus = observed
                }
            }
            launch.completion(nil)
            if !launch.repairing { launch.lease.remember(Dictionary(uniqueKeysWithValues: observed.map { ($0.0, $0.1.observation.frame) })) }
            for (id, readback) in observed {
                guard allowed(launch) else { return }
                if let write = sizeWrites[id], Int64(readback.handle.pid) == write.ownerPID {
                    let evidence = ResidentMinimumEvidence(write: write, observed: readback.observation.frame,
                        observedGeneration: readback.generation, readCompletedNanos: readback.completedNanos)
                    launch.lease.rememberMinimum(id, evidence)
                    onMinimumEvidence?(evidence)
                }
                onFrame?(request.requestID, id, readback.observation.frame, readback.generation, readback.completedNanos)
            }
            if let focus, allowed(launch) { onFocus?(request.requestID, request.windowID, focus.generation, focus.completedNanos) }
        }
    }

    /// The single focus-write path is shared by navigation and frame-plus-focus
    /// member selection. Readback is independent of the successful raise call.
    private func raiseAndConfirmFocus(_ launch: Launch, handle: ProjectionWindowHandle,
                                     finalFocus: Bool = true) -> Result<FocusReadback?, ProjectionObservationFailure> {
        guard allowed(launch) else { return .failure(.init(code: "focus_target_invalidated")) }
        if finalFocus { onFocusIssue?(launch.request.requestID, DispatchTime.now().uptimeNanoseconds) }
        let app = AXUIElementCreateApplication(handle.pid)
        let timeoutError = AXUIElementSetMessagingTimeout(app, TargetedProjectionSnapshot.axReadTimeoutSeconds)
        guard timeoutError == .success else { return .failure(.init(code: "ax_focus_timeout_configuration_failed:\(timeoutError.rawValue)")) }
        guard authorizedGeneration(launch) != nil else { return .failure(.init(code: "effect_observation_generation_unavailable")) }
        let frontmostStamp = DispatchTime.now().uptimeNanoseconds
        let frontmostError = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard frontmostError == .success else { return .failure(.init(code: "ax_frontmost_issue_failed:\(frontmostError.rawValue)")) }
        recordAXWrite(launch, windowID: launch.request.windowID, operation: "set_frontmost", timestamp: frontmostStamp)
        guard authorizedGeneration(launch) != nil else { return .failure(.init(code: "effect_invalidated_before_focus_raise")) }
        let raiseStamp = DispatchTime.now().uptimeNanoseconds
        let raiseError = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        guard raiseError == .success else { return .failure(.init(code: "ax_raise_issue_failed:\(raiseError.rawValue)")) }
        recordAXWrite(launch, windowID: launch.request.windowID, operation: "raise", timestamp: raiseStamp)
        return confirmFocus(launch, windowID: handle.windowId)
    }

    private func recordAXWrite(_ launch: Launch, windowID: String, operation: String, timestamp: UInt64) {
        let request = launch.request
        ResidentPerformanceTrace.shared.record("ax_write_issued", fields: ["request_id": .string(request.requestID),
            "action_id": .string(request.actionID), "operation": .string(operation),
            "boundary": .string("successful_actual_ax_call"), "window_id": .string(windowID),
            "pid": request.windowPids[windowID].map(JSONValue.int) ?? .null,
            "window_generation": request.windowGenerations[windowID].map { .int(Int64(clamping: $0)) } ?? .null,
            "observer_epoch": request.observerEpoch.map(JSONValue.string) ?? .null,
            "requested_observer_generation": .int(Int64(clamping: request.observerGeneration)),
            "observer_generation": authorizedGeneration(launch).map { .int(Int64(clamping: $0)) } ?? .null,
            "space_key": request.windowSpaceKeys[windowID].map(JSONValue.string) ?? .null,
            "display_id": request.windowDisplayIDs[windowID].map(JSONValue.string) ?? .null,
            "topology_revision": .int(Int64(clamping: request.topologyRevision))], timestamp: timestamp)
    }

    private func confirmFocus(_ launch: Launch, windowID: Int64) -> Result<FocusReadback?, ProjectionObservationFailure> {
        observationQueue.sync {
            let request = launch.request
            guard let generation = authorizedGeneration(launch) else {
                return .failure(.init(code: "effect_observation_generation_unavailable"))
            }
            let handle: ProjectionWindowHandle
            switch snapshots.resolveWindow(windowId: windowID, observerGeneration: generation,
                                           expectedWindowGeneration: request.windowGenerations[String(windowID)]) {
            case .failure(let failure): return .failure(failure)
            case .success(let resolved): handle = resolved
            }
            let system = AXUIElementCreateSystemWide()
            guard AXUIElementSetMessagingTimeout(system, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else { return .success(nil) }
            var rawApp: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &rawApp) == .success,
                  let rawApp, CFGetTypeID(rawApp) == AXUIElementGetTypeID() else { return .success(nil) }
            let app = unsafeDowncast(rawApp, to: AXUIElement.self)
            var pid: pid_t = 0
            guard AXUIElementGetPid(app, &pid) == .success, pid == handle.pid,
                  AXUIElementSetMessagingTimeout(app, TargetedProjectionSnapshot.axReadTimeoutSeconds) == .success else { return .success(nil) }
            var rawWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
                  let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
                  let identity = liveProjectionAXWindowIdentity(unsafeDowncast(rawWindow, to: AXUIElement.self)),
                  identity.windowId == CGWindowID(handle.windowId), identity.pid == handle.pid else { return .success(nil) }
            guard authorizedGeneration(launch) == generation else {
                return .failure(.init(code: "effect_observation_generation_changed_during_focus_read"))
            }
            return .success(FocusReadback(generation: generation, completedNanos: DispatchTime.now().uptimeNanoseconds))
        }
    }
}
