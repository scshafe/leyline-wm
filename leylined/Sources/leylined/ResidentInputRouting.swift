// Keyboard routing is process-local. KeyDecode and ModeFSM remain the canonical
// frozen model; this boundary owns immutable claim tables and bounded delivery.
import Foundation
import LeylineModel

enum ResidentInputConstants {
    static let modeIndexMask: UInt64 = 0x7fff_ffff
    static let pendingModeRelease: UInt64 = 0x8000_0000
    static let spaceToggleActionID = "space.management.toggle"
    static let maximumQueuedEvents = 64
    static let watchdogCadenceMilliseconds = 25
    static let releaseBudgetMilliseconds = 200
    static let releaseCeilingMilliseconds = 250
    static let releaseReasons = ["none", "callback_deadline", "tap_run_loop_deadline",
        "authority_deadline", "action_deadline", "mailbox_contention", "mailbox_overflow",
        "pending_action_overflow", "global_stop", "external_context_invalidated",
        "committed_interaction_context_invalidated", "world_or_focused_space_unavailable",
        "world_unavailable", "settings-failure", "unknown_release"]
}

enum ResidentInputPhase: String, Sendable { case keyDown = "key_down", keyUp = "key_up", cancel }

struct ResidentInputAction: Sendable {
    let actionId: String
    let phase: ResidentInputPhase
    let mode: String
    let generation: UInt64
    let receiptUptimeNs: UInt64
    let spaceContextGeneration: UInt64

    init(actionId: String, phase: ResidentInputPhase, mode: String, generation: UInt64,
         receiptUptimeNs: UInt64, spaceContextGeneration: UInt64 = 0) {
        self.actionId = actionId; self.phase = phase; self.mode = mode; self.generation = generation
        self.receiptUptimeNs = receiptUptimeNs; self.spaceContextGeneration = spaceContextGeneration
    }
}

enum ResidentInputAdmission: String, Sendable {
    case claimed, passedThrough = "passed_through", queueFull = "queue_full"
    case contentionReleased = "contention_released"
}

typealias ResidentInputActionDispatch = @Sendable (
    ResidentInputAction, @escaping @Sendable (Int) -> Void
) -> Void

struct ResidentInputRoute: Sendable {
    let actionId: String
    let predicate: ExitPredicate?
    let enteringModeIndex: Int?
    let exitsImmediately: Bool
}

struct ResidentInputConfiguration: Sendable {
    let decode: KeyDecode
    let fsm: ModeFSM
    let modeNames: [String]
    let routes: [[String: ResidentInputRoute]]
    let unsupportedActionIds: Set<String>

    init(decode: KeyDecode, fsm: ModeFSM, globalData: Data, supportedActionIds: Set<String>) throws {
        guard let global = try JSONValue.parse(globalData).objectValue,
              let bindings = global["bindings"]?.arrayValue else {
            throw ResidentInputError(code: "INPUT.KEYMAP_INVALID", message: "Global keymap bindings are unavailable")
        }
        let names = ["default"] + fsm.modes.keys.sorted()
        var tables = Array(repeating: [String: ResidentInputRoute](), count: names.count)
        var unsupported: Set<String> = []
        for binding in bindings {
            guard let row = binding.objectValue,
                  let chord = row["chord"]?.stringValue,
                  let id = row["action_id"]?.stringValue else {
                throw ResidentInputError(code: "INPUT.KEYMAP_INVALID", message: "Global keymap contains an invalid binding")
            }
            guard supportedActionIds.contains(id) else { unsupported.insert(id); continue }
            let route = ResidentInputRoute(actionId: id, predicate: nil, enteringModeIndex: nil, exitsImmediately: false)
            for index in tables.indices { tables[index][chord] = route }
        }
        for (index, name) in names.enumerated() where index > 0 {
            guard let mode = fsm.modes[name] else { continue }
            if !supportedActionIds.contains(mode.enterActionId) {
                unsupported.insert(mode.enterActionId)
                unsupported.formUnion(mode.bindings.map(\.actionId))
                continue
            }
            tables[0][mode.enterChord] = ResidentInputRoute(
                actionId: mode.enterActionId, predicate: mode.enterOnDone,
                enteringModeIndex: index, exitsImmediately: false)
            for binding in mode.bindings {
                guard supportedActionIds.contains(binding.actionId) else {
                    unsupported.insert(binding.actionId)
                    // An unsupported modal binding must not inherit a global
                    // action with a different meaning in the same mode.
                    tables[index].removeValue(forKey: binding.key)
                    continue
                }
                tables[index][binding.key] = ResidentInputRoute(
                    actionId: binding.actionId, predicate: binding.onDone,
                    enteringModeIndex: nil,
                    exitsImmediately: binding.onDone == .unconditionalExit || binding.key == "0x35")
            }
            for key in mode.exitKeys {
                tables[index][key] = ResidentInputRoute(
                    actionId: "mode.cancel", predicate: .unconditionalExit,
                    enteringModeIndex: nil, exitsImmediately: true)
            }
        }
        self.decode = decode
        self.fsm = fsm
        self.modeNames = names
        self.routes = tables
        self.unsupportedActionIds = unsupported
    }
}

struct ResidentInputError: Error, Sendable {
    let code: String
    let message: String
}

/// @canonical resident_input_routing -- the tap and hermetic injection use this
/// claim lookup. Atomic mode/generation changes never need AppKit/timeline locks.
final class ResidentInputRouting: @unchecked Sendable {
    private enum Delivery: Sendable {
        case mode(String, UInt64)
        case action(ResidentInputAction, ResidentInputRoute, Int, UInt64)
    }
    let configuration: ResidentInputConfiguration
    let inputEpoch = UUID().uuidString
    private let packedMode = ResidentAtomic<UInt64>(0)
    private let releaseDeliveryScheduled = ResidentAtomic<Bool>(false)
    private var lastDeliveredModeGeneration: UInt64 = 0 // deliveryQueue only
    private let accepting = ResidentAtomic<Bool>(true)
    private let claimEligibility = ResidentAtomic<UInt64>(3)
    private let spaceContextEpoch = ResidentAtomic<UInt64>(0)
    private let queuedCount = ResidentAtomic<Int>(0)
    private let peakCount = ResidentAtomic<Int>(0)
    private let releasedCount = ResidentAtomic<Int>(0)
    private let releaseReasonCode = ResidentAtomic<Int>(0)
    private let pendingActionCount = ResidentAtomic<Int>(0)
    private let pendingSpaceControlCount = ResidentAtomic<Int>(0)
    // One atomic binds generation to the oldest unfinished action's progress.
    // Its original receipt remains the ordering/identity key. Millisecond
    // truncation adds <1 ms to a 200+25 ms deadline, within the 250 ms ceiling.
    // UInt32 modular subtraction preserves the clock through 49-day rollover.
    private let pendingActionDeadline = ResidentAtomic<UInt64>(0)
    private let pendingSpaceControlDeadline = ResidentAtomic<UInt64>(0)
    // Completion bookkeeping never runs in the tap callback. The watchdog
    // reads only the published atomic oldest stamp, independent of this lock.
    private let pendingActionsLock = NSLock()
    private struct PendingAction {
        let receiptUptimeNs: UInt64
        let generation: UInt64
        let spaceControl: Bool
        let spaceContextGeneration: UInt64
        var lastProgressUptimeNs: UInt64
    }
    private var pendingActions: [UInt64: PendingAction] = [:]
    private var nextActionSequence: UInt64 = 0 // deliveryQueue only
    private let actionDispatch: ResidentInputActionDispatch
    private let onModeChanged: @Sendable (String, UInt64, Bool) -> Bool
    private let uptimeProvider: @Sendable () -> UInt64
    private let faultMailbox: ResidentInputFaultMailbox
    // This lock protects only bounded array operations, never action dispatch,
    // AppKit, timeline, health, filesystem I/O, or completion callbacks. The
    // tap uses try(), so even a halted mailbox consumer cannot hold a key.
    private let mailboxLock = NSLock()
    private var mailbox: [Delivery] = []
    private var drainScheduled = false
    private let deliveryQueue = DispatchQueue(label: "leyline.resident.input.delivery", qos: .userInteractive)

    init(configuration: ResidentInputConfiguration,
         dispatchAction: @escaping ResidentInputActionDispatch,
         onModeChanged: @escaping @Sendable (String, UInt64, Bool) -> Bool,
         onFaultRelease: @escaping @Sendable (ResidentInputFaultRelease) -> Void = { _ in },
         uptimeProvider: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.configuration = configuration
        self.actionDispatch = dispatchAction
        self.onModeChanged = onModeChanged
        self.uptimeProvider = uptimeProvider
        self.faultMailbox = ResidentInputFaultMailbox(inputEpoch: inputEpoch, deliver: onFaultRelease)
    }

    var mode: String { configuration.modeNames[modeIndex] }
    var modeIndex: Int { Int(packedMode.load(ordering: .acquiring) & ResidentInputConstants.modeIndexMask) }
    var generation: UInt64 { packedMode.load(ordering: .acquiring) >> 32 }
    var isAccepting: Bool { accepting.load(ordering: .acquiring) }
    var spaceContextGeneration: UInt64 { spaceContextEpoch.load(ordering: .acquiring) }
    var hasPendingSpaceControl: Bool { oldestPendingSpaceControlUptimeNs > 0 }
    var oldestPendingActionUptimeNs: UInt64 { decodeDeadline(pendingActionDeadline.load(ordering: .acquiring), generation: generation) }
    var oldestPendingSpaceControlUptimeNs: UInt64 {
        decodeDeadline(pendingSpaceControlDeadline.load(ordering: .acquiring), generation: spaceContextGeneration)
    }
    var oldestPendingInputUptimeNs: UInt64 {
        [oldestPendingActionUptimeNs, oldestPendingSpaceControlUptimeNs].filter { $0 > 0 }.min() ?? 0
    }
    private func decodeDeadline(_ value: UInt64, generation: UInt64) -> UInt64 {
        guard value != 0, value >> 32 == generation else { return 0 }
        let now = uptimeProvider()
        let currentMilliseconds = UInt32(truncatingIfNeeded: now / 1_000_000)
        let receiptMilliseconds = UInt32(truncatingIfNeeded: value)
        let age = UInt64(currentMilliseconds &- receiptMilliseconds) * 1_000_000
        return age <= now ? now - age : 0
    }

    func setAccepting(_ value: Bool) { accepting.store(value, ordering: .releasing) }
    func setClaimEligibility(management: Bool, spaceControl: Bool) {
        claimEligibility.store((management ? 1 : 0) | (spaceControl ? 2 : 0), ordering: .releasing)
    }

    func invalidateSpaceContext() {
        spaceContextEpoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        pendingSpaceControlDeadline.store(0, ordering: .releasing)
        pendingSpaceControlCount.store(0, ordering: .releasing)
    }
    private func actionAllowed(_ actionID: String) -> Bool {
        let bit: UInt64 = actionID == ResidentInputConstants.spaceToggleActionID ? 2 : 1
        return isAccepting && claimEligibility.load(ordering: .acquiring) & bit != 0
    }
    private func allowedRoute(at index: Int, chord: String) -> ResidentInputRoute? {
        guard let route = configuration.routes[index][chord], actionAllowed(route.actionId) else { return nil }
        return route
    }

    /// Advance one unfinished action's deadline from genuine effect progress.
    /// The receipt/generation remain immutable. Duplicate, stale, ambiguous or
    /// future stamps cannot refresh this action or any other pending action.
    @discardableResult
    func noteActionProgress(receiptUptimeNs: UInt64, generation: UInt64, progressUptimeNs: UInt64) -> Bool {
        pendingActionsLock.lock()
        defer { pendingActionsLock.unlock() }
        guard generation == self.generation, receiptUptimeNs > 0,
              progressUptimeNs > receiptUptimeNs, progressUptimeNs <= uptimeProvider() else { return false }
        let matches = pendingActions.filter { $0.value.generation == generation && $0.value.receiptUptimeNs == receiptUptimeNs }
        guard matches.count == 1, let sequence = matches.keys.first,
              var action = pendingActions[sequence], progressUptimeNs > action.lastProgressUptimeNs,
              generation == self.generation else { return false }
        action.lastProgressUptimeNs = progressUptimeNs
        pendingActions[sequence] = action
        publishPendingActionsLocked()
        return generation == self.generation
    }

    func route(for chord: String) -> ResidentInputRoute? {
        allowedRoute(at: modeIndex, chord: chord)
    }

    @discardableResult
    func admit(chord: String, phase: ResidentInputPhase = .keyDown,
               receiptUptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds, isRepeat: Bool = false,
               spaceContextGeneration expectedSpaceContext: UInt64? = nil) -> ResidentInputAdmission {
        let spaceContext = expectedSpaceContext ?? spaceContextGeneration
        let previous = packedMode.load(ordering: .acquiring)
        let index = Int(previous & ResidentInputConstants.modeIndexMask)
        guard let route = allowedRoute(at: index, chord: chord) else { return .passedThrough }
        if route.actionId == ResidentInputConstants.spaceToggleActionID {
            guard spaceContext == spaceContextGeneration else { return .passedThrough }
            if isRepeat { return .claimed }
        }
        // Native held-key ownership consumes release edges. Only directional resize
        // needs a delivered key-up marker; mode/global/service releases have no action.
        if phase == .keyUp, !route.actionId.hasPrefix("resize.adjust.") { return .claimed }
        guard mailboxLock.try() else {
            release(reason: "mailbox_contention")
            return .contentionReleased
        }
        let priority = phase == .keyUp || phase == .cancel || route.exitsImmediately
        let cancelling = phase == .cancel || route.exitsImmediately
        if cancelling {
            // A genuine cancel supersedes queued work. Key-up only ends future
            // repetition; every already admitted displacement remains FIFO.
            mailbox.removeAll { delivery in
                if case .action(let action, _, _, _) = delivery {
                    return action.actionId != ResidentInputConstants.spaceToggleActionID
                        && action.generation == previous >> 32 && action.phase == .keyDown
                        && (action.actionId.hasPrefix("resize.adjust.") || route.exitsImmediately)
                }
                return false
            }
        }
        guard mailbox.count < ResidentInputConstants.maximumQueuedEvents - 1 else {
            mailboxLock.unlock()
            release(reason: "mailbox_overflow")
            return .queueFull
        }
        var updated = previous
        if phase == .keyDown, let entering = route.enteringModeIndex {
            updated = ((previous >> 32) + 1) << 32 | UInt64(entering) | (previous & ResidentInputConstants.pendingModeRelease)
        } else if route.exitsImmediately {
            // Escape's move.cancel may unstage and restore move mode (rc3).
            // Generic/unconditional exits have no such retained transaction.
            let hardExit = route.actionId != "move.cancel" ? ResidentInputConstants.pendingModeRelease : 0
            updated = ((previous >> 32) + 1) << 32 | (previous & ResidentInputConstants.pendingModeRelease) | hardExit
        }
        if updated != previous {
            let transition = packedMode.compareExchange(expected: previous, desired: updated,
                ordering: .acquiringAndReleasing)
            if !transition.exchanged {
                // Delivery may consume only the release bit, without changing
                // claim authority. Retry that bookkeeping race once; a genuine
                // generation/mode change still retires this admission.
                let current = transition.original
                guard (current & ~ResidentInputConstants.pendingModeRelease)
                    == (previous & ~ResidentInputConstants.pendingModeRelease) else {
                    mailboxLock.unlock(); return .passedThrough
                }
                updated = (updated & ~ResidentInputConstants.pendingModeRelease)
                    | (current & ResidentInputConstants.pendingModeRelease)
                guard packedMode.compareExchange(expected: current, desired: updated,
                    ordering: .acquiringAndReleasing).exchanged else {
                    mailboxLock.unlock(); return .passedThrough
                }
            }
            clearPendingDeadline(preserveSpaceControls: true)
            mailbox.append(.mode(configuration.modeNames[Int(updated & ResidentInputConstants.modeIndexMask)], updated >> 32))
        }
        let action = ResidentInputAction(
            actionId: route.actionId, phase: priority ? (phase == .keyUp ? .keyUp : .cancel) : phase,
            mode: configuration.modeNames[route.enteringModeIndex ?? index],
            generation: updated >> 32, receiptUptimeNs: receiptUptimeNs, spaceContextGeneration: spaceContext)
        let delivery = Delivery.action(action, route, route.enteringModeIndex ?? index, updated & ~ResidentInputConstants.pendingModeRelease)
        // Mode delivery stays first. A cancellation is otherwise the next item.
        if cancelling, updated == previous { mailbox.insert(delivery, at: 0) }
        else { mailbox.append(delivery) }
        queuedCount.store(mailbox.count, ordering: .relaxed)
        let peak = peakCount.load(ordering: .relaxed)
        if mailbox.count > peak { peakCount.store(mailbox.count, ordering: .relaxed) }
        let schedule = !drainScheduled
        drainScheduled = true
        mailboxLock.unlock()
        if schedule { deliveryQueue.async { [self] in drain() } }
        return .claimed
    }

    /// Restore default claims synchronously without waiting for any delivery.
    /// Notification is asynchronous; a stalled renderer cannot delay release.
    func release(reason: String, preserveSpaceControls: Bool = false) {
        if !preserveSpaceControls { invalidateSpaceContext() }
        // A completion can win the first CAS while the watchdog is releasing.
        // Retry the lock-free update rather than accidentally retaining mode.
        // Each generation has at most one successful completion transition;
        // stale acknowledgments cannot keep this safety lane in contention.
        var old = packedMode.load(ordering: .acquiring)
        let receipt = uptimeProvider()
        while true {
            let next = ((old >> 32) + 1) << 32 | ResidentInputConstants.pendingModeRelease
            let result = packedMode.compareExchange(expected: old, desired: next, ordering: .acquiringAndReleasing)
            if result.exchanged { break }
            old = result.original
        }
        scheduleReleaseDelivery()
        releasedCount.wrappingAdd(1, ordering: .relaxed)
        releaseReasonCode.store(ResidentInputConstants.releaseReasons.firstIndex(of: reason)
            ?? (ResidentInputConstants.releaseReasons.count - 1), ordering: .releasing)
        clearPendingDeadline(preserveSpaceControls: preserveSpaceControls)
        if let faultReason = ResidentInputFaultReason(rawValue: reason) {
            faultMailbox.submit(ResidentInputFaultRelease(inputEpoch: inputEpoch, reason: faultReason,
                originalGeneration: old >> 32, releasedGeneration: (old >> 32) + 1, receiptUptimeNs: receipt))
        }
        // Do not block the safety lane on the optional notification mailbox.
        guard mailboxLock.try() else { return }
        mailbox.removeAll { delivery in
            guard preserveSpaceControls, case .action(let action, _, _, _) = delivery,
                  action.actionId == ResidentInputConstants.spaceToggleActionID,
                  action.spaceContextGeneration == spaceContextGeneration else { return true }
            return false
        }
        queuedCount.store(mailbox.count, ordering: .relaxed)
        let schedule = !drainScheduled
        drainScheduled = true
        mailboxLock.unlock()
        if schedule { deliveryQueue.async { [self] in drain() } }
    }

    func health() -> JSONObject {
        ["mode": .string(mode), "generation": .int(Int64(generation)),
         "queued_events": .int(Int64(queuedCount.load(ordering: .relaxed))),
         "peak_queued_events": .int(Int64(peakCount.load(ordering: .relaxed))),
         "queue_capacity": .int(Int64(ResidentInputConstants.maximumQueuedEvents)),
         "release_count": .int(Int64(releasedCount.load(ordering: .relaxed))),
         "last_release_reason": .string(ResidentInputConstants.releaseReasons[releaseReasonCode.load(ordering: .acquiring)]),
         "accepting_claims": .bool(isAccepting),
         "active_action_ids": .array(Set(configuration.routes[modeIndex].keys.compactMap {
             allowedRoute(at: modeIndex, chord: $0)?.actionId
         }).sorted().map(JSONValue.string)),
         "pending_action_count": .int(Int64(pendingActionCount.load(ordering: .acquiring))),
         "fault_delivery": .object(faultMailbox.health),
         "unsupported_action_ids": .array(configuration.unsupportedActionIds.sorted().map(JSONValue.string)),
         "pending_mode_release": .bool(packedMode.load(ordering: .acquiring) & ResidentInputConstants.pendingModeRelease != 0),
         "normal_path_subprocesses": .int(0)]
    }

    #if LEYLINE_BUILD_TESTS
    func flushForSelfTest() { deliveryQueue.sync {} }

    #endif

    private func drain() {
        while true {
            mailboxLock.lock()
            guard !mailbox.isEmpty else {
                drainScheduled = false
                mailboxLock.unlock()
                return
            }
            let delivery = mailbox.removeFirst()
            queuedCount.store(mailbox.count, ordering: .relaxed)
            mailboxLock.unlock()
            switch delivery {
            case .mode(let name, let generation):
                pendingActionsLock.lock()
                pendingActions = pendingActions.filter { pendingIsCurrent($0.value) }
                publishPendingActionsLocked()
                pendingActionsLock.unlock()
                deliverModeIfCurrent(name: name, generation: generation)
            case .action(let action, let route, let index, let expected):
                if action.actionId == "mode.cancel" { continue }
                if action.actionId == ResidentInputConstants.spaceToggleActionID {
                    guard action.spaceContextGeneration == spaceContextGeneration, actionAllowed(action.actionId) else { continue }
                } else {
                    guard action.phase == .keyUp || expected == (packedMode.load(ordering: .acquiring) & ~ResidentInputConstants.pendingModeRelease) else { continue }
                }
                nextActionSequence &+= 1
                let actionSequence = nextActionSequence
                pendingActionsLock.lock()
                guard pendingActions.count < ResidentInputConstants.maximumQueuedEvents else {
                    pendingActionsLock.unlock()
                    setAccepting(false)
                    release(reason: "pending_action_overflow")
                    continue
                }
                pendingActions[actionSequence] = PendingAction(receiptUptimeNs: action.receiptUptimeNs,
                    generation: action.generation, spaceControl: action.actionId == ResidentInputConstants.spaceToggleActionID,
                    spaceContextGeneration: action.spaceContextGeneration, lastProgressUptimeNs: action.receiptUptimeNs)
                publishPendingActionsLocked()
                pendingActionsLock.unlock()
                actionDispatch(action) { [weak self] rc in
                    guard let self else { return }
                    self.pendingActionsLock.lock()
                    let firstCompletion = self.pendingActions.removeValue(forKey: actionSequence) != nil
                    self.publishPendingActionsLocked()
                    self.pendingActionsLock.unlock()
                    guard firstCompletion, action.phase != .keyUp,
                          let predicate = route.predicate else { return }
                    let step = ModeFSM.step(mode: self.configuration.modeNames[index], predicate: predicate, rc: rc)
                    let nextIndex = step.exit ? 0 : index
                    guard nextIndex != Int(expected & ResidentInputConstants.modeIndexMask) else { return }
                    // A partial cancel (rc3) can restore the prior mode after
                    // its safety pre-release. Restoration is a fresh mode
                    // generation, so revision subscribers cannot drop it as a
                    // duplicate of the earlier default-mode notification.
                    let desired = ((expected >> 32) + 1) << 32 | UInt64(nextIndex)
                        | (step.exit ? ResidentInputConstants.pendingModeRelease : 0)
                    guard
                          self.packedMode.compareExchange(expected: expected, desired: desired,
                                                         ordering: .acquiringAndReleasing).exchanged else { return }
                    self.clearPendingDeadline(preserveSpaceControls: true)
                    self.enqueueModeNotification(name: step.nextMode, generation: desired >> 32)
                }
            }
        }
    }

    /// A forced release remains attached to the atomic generation until its
    /// current mode is delivered. A newer entry carries this reset obligation;
    /// an old callback can never restore claims or publish a stale mode.
    @discardableResult
    private func deliverModeIfCurrent(name: String, generation: UInt64) -> Bool {
        let current = packedMode.load(ordering: .acquiring)
        guard current >> 32 == generation,
              configuration.modeNames[Int(current & ResidentInputConstants.modeIndexMask)] == name,
              generation > lastDeliveredModeGeneration else { return false }
        let resetsInteraction = current & ResidentInputConstants.pendingModeRelease != 0
        // Authority may reject a callback superseded while it waited on a
        // transition. Only a successful commit can retire this reset; a newer
        // generation inherits the bit until its own current frame commits.
        guard onModeChanged(name, generation, resetsInteraction) else { return false }
        lastDeliveredModeGeneration = generation
        if resetsInteraction {
            _ = packedMode.compareExchange(expected: current,
                desired: current & ~ResidentInputConstants.pendingModeRelease,
                ordering: .acquiringAndReleasing)
        }
        return true
    }

    /// One pending delivery and one executing task; the tap never waits on the
    /// ordinary mailbox lock to publish its release obligation.
    private func scheduleReleaseDelivery() {
        guard releaseDeliveryScheduled.compareExchange(expected: false, desired: true,
            ordering: .acquiringAndReleasing).exchanged else { return }
        deliveryQueue.async { [self] in
            let current = packedMode.load(ordering: .acquiring)
            if current & ResidentInputConstants.pendingModeRelease != 0 {
                deliverModeIfCurrent(name: configuration.modeNames[Int(current & ResidentInputConstants.modeIndexMask)],
                    generation: current >> 32)
            }
            releaseDeliveryScheduled.store(false, ordering: .releasing)
            let latest = packedMode.load(ordering: .acquiring)
            if latest & ResidentInputConstants.pendingModeRelease != 0, latest >> 32 != current >> 32 {
                scheduleReleaseDelivery()
            }
        }
    }

    #if LEYLINE_BUILD_TESTS
    func withMailboxLockForSelfTest(_ operation: () -> Void) {
        mailboxLock.lock(); defer { mailboxLock.unlock() }; operation()
    }
    #endif

    private func enqueueModeNotification(name: String, generation: UInt64) {
        mailboxLock.lock()
        if mailbox.count >= ResidentInputConstants.maximumQueuedEvents { mailbox.removeFirst() }
        mailbox.append(.mode(name, generation))
        queuedCount.store(mailbox.count, ordering: .relaxed)
        let schedule = !drainScheduled
        drainScheduled = true
        mailboxLock.unlock()
        if schedule { deliveryQueue.async { [self] in drain() } }
    }

    private func pendingIsCurrent(_ action: PendingAction) -> Bool {
        action.spaceControl ? action.spaceContextGeneration == spaceContextGeneration : action.generation == generation
    }

    private func publishPendingActionsLocked() {
        let modeGeneration = generation, contextGeneration = spaceContextGeneration
        let current = pendingActions.filter {
            $0.value.spaceControl ? $0.value.spaceContextGeneration == contextGeneration : $0.value.generation == modeGeneration
        }
        let controls = current.values.filter(\.spaceControl)
        pendingActionCount.store(current.count, ordering: .releasing)
        pendingSpaceControlCount.store(controls.count, ordering: .releasing)
        func deadline(_ actions: [PendingAction], generation: UInt64) -> UInt64 {
            guard let oldest = actions.min(by: { $0.receiptUptimeNs < $1.receiptUptimeNs }) else { return 0 }
            return generation << 32 | UInt64(UInt32(truncatingIfNeeded: oldest.lastProgressUptimeNs / 1_000_000))
        }
        pendingActionDeadline.store(deadline(current.values.filter { !$0.spaceControl }, generation: modeGeneration), ordering: .releasing)
        pendingSpaceControlDeadline.store(deadline(controls, generation: contextGeneration), ordering: .releasing)
    }

    private func clearPendingDeadline(preserveSpaceControls: Bool = false) {
        pendingActionDeadline.store(0, ordering: .releasing)
        if !preserveSpaceControls {
            pendingSpaceControlDeadline.store(0, ordering: .releasing)
            pendingSpaceControlCount.store(0, ordering: .releasing)
        }
        pendingActionCount.store(preserveSpaceControls ? pendingSpaceControlCount.load(ordering: .acquiring) : 0, ordering: .releasing)
    }

}
