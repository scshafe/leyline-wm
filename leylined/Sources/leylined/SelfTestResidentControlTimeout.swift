import Foundation
import LeylineModel

/// Actual timeout callback/store and held lifecycle queues. No AppKit, AX,
/// tap, journal, live timer or runtime mutation; capability ports are atomic.
func runResidentControlTimeoutScenarios(home: String, test: inout SelfTest) {
    let path = home + "/leylined/Fixtures/resident/control-timeout-ownership.json"
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data),
          let timed = fixture.at(path: "timed")?.objectValue, let next = fixture.at(path: "next")?.objectValue,
          let stop = fixture.at(path: "new_stop")?.objectValue,
          let reused = fixture.at(path: "reused")?.objectValue,
          let evictionCount = fixture.at(path: "eviction_count")?.intValue, evictionCount == 64,
          let evictionPrefix = fixture.at(path: "eviction_request_prefix")?.stringValue, !evictionPrefix.isEmpty,
          let rawRevision = fixture.at(path: "revision")?.intValue, rawRevision >= 0,
          let rawGeneration = fixture.at(path: "generation")?.intValue, rawGeneration > 0 else {
        test.check(false, "control-timeout/fixture-load"); return
    }
    let revision = UInt64(rawRevision), initialGeneration = UInt64(rawGeneration)
    test.check(Set([timed, next, stop].compactMap { $0["request_id"]?.stringValue }).count == 3
        && fixture.at(path: "scope.readiness_verified")?.boolValue == false,
        "control-timeout/nonvacuous-three-control-fixture-and-explicit-off-readiness")

    // A's stop continuation is queued on the actual held lifecycle lane. B is
    // admitted after A's timeout, but deliberately does not begin before drain.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let queue = DispatchQueue(label: "fixture.control.timeout.held-lifecycle")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); _ = release.wait(timeout: .now() + .seconds(2)) }
        let held = entered.wait(timeout: .now() + .seconds(1)) == .success
        let terminals = ResidentAtomic<UInt64>(0), releases = ResidentAtomic<UInt64>(0)
        let cancellations = ResidentAtomic<UInt64>(0), stops = ResidentAtomic<UInt64>(0)
        let first = requests.admit(timed, revision: revision)
        ResidentControlTimeout.expire(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, revision: revision, requests: requests,
            lifecycleGeneration: generation, capabilityGate: ResidentControlTimeout.CapabilityGate(),
            onTerminal: { terminals.wrappingAdd(1, ordering: .acquiringAndReleasing) },
            releaseClaims: { releases.wrappingAdd(1, ordering: .acquiringAndReleasing) },
            cancelMaintenance: { cancellations.wrappingAdd(1, ordering: .acquiringAndReleasing) },
            enqueue: { queue.async(execute: $0) }, continueStopping: { _ in stops.wrappingAdd(1, ordering: .acquiringAndReleasing) })
        test.check(held && requests.result(requestID: first.intent!.requestID, revision: revision).at(path: "reason")?.stringValue == "resident_control_timeout"
            && terminals.load(ordering: .acquiring) == 1 && releases.load(ordering: .acquiring) == 1
            && cancellations.load(ordering: .acquiring) == 1 && stops.load(ordering: .acquiring) == 0
            && generation.load(ordering: .acquiring) == initialGeneration + 1,
            "control-timeout/own-timeout-terminalizes-fences-releases-claims-and-cancels-maintenance-before-held-lane-drains")
        let newer = requests.admit(next, revision: revision)
        test.check(newer.intent != nil && newer.intent!.admissionSequence > first.intent!.admissionSequence
            && generation.load(ordering: .acquiring) == initialGeneration + 1,
            "control-timeout/new-admission-retires-old-timeout-before-new-lifecycle-begins")
        queue.async { drained.signal() }; release.signal()
        test.check(drained.wait(timeout: .now() + .seconds(1)) == .success && stops.load(ordering: .acquiring) == 0
            && requests.result(requestID: newer.intent!.requestID, revision: revision).at(path: "phase")?.stringValue == "queued"
            && generation.load(ordering: .acquiring) == initialGeneration + 1,
            "control-timeout/reordered-old-continuation-cannot-stop-supersede-publish-or-advance-new-control")
        let began = requests.begin(requestID: newer.intent!.requestID, expectedAdmissionSequence: newer.intent!.admissionSequence) { generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1 }
        let result = requests.complete(requestID: newer.intent!.requestID, expectedAdmissionSequence: newer.intent!.admissionSequence, status: .accepted, revision: revision,
            reason: nil, details: fixture.at(path: "scope")!.objectValue!)
        test.check(began == initialGeneration + 2 && result?.at(path: "status")?.stringValue == "accepted"
            && requests.begin(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, allocateGeneration: { initialGeneration + 3 }) == nil,
            "control-timeout/new-control-begins-once-and-old-timed-control-cannot-reacquire-fence")
    }

    // An owning timeout still stops once after an actual queued delay. Repeated
    // expiration never allocates a second epoch or repeats capability release.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let queue = DispatchQueue(label: "fixture.control.timeout.own-lifecycle")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); _ = release.wait(timeout: .now() + .seconds(2)) }
        let held = entered.wait(timeout: .now() + .seconds(1)) == .success
        let callbacks = ResidentAtomic<UInt64>(0), releases = ResidentAtomic<UInt64>(0), cancellations = ResidentAtomic<UInt64>(0)
        let first = requests.admit(timed, revision: revision)
        let expire: @Sendable () -> Void = {
            ResidentControlTimeout.expire(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, revision: revision, requests: requests,
                lifecycleGeneration: generation, capabilityGate: ResidentControlTimeout.CapabilityGate(),
                onTerminal: { callbacks.wrappingAdd(1, ordering: .acquiringAndReleasing) },
                releaseClaims: { releases.wrappingAdd(1, ordering: .acquiringAndReleasing) },
                cancelMaintenance: { cancellations.wrappingAdd(1, ordering: .acquiringAndReleasing) },
                enqueue: { queue.async(execute: $0) }, continueStopping: { timeout in
                    if ResidentControlTimeout.isCurrent(timeout, requests: requests, lifecycleGeneration: generation) {
                        callbacks.wrappingAdd(8, ordering: .acquiringAndReleasing)
                    }
                    stopped.signal()
                })
        }
        // Refusal and replay do not change the current admission sequence.
        let refused = requests.admit(next, revision: revision), replay = requests.admit(timed, revision: revision)
        test.check(refused.intent == nil && replay.intent == nil && replay.result == first.result,
            "control-timeout/refused-or-duplicate-admission-cannot-retire-current-timeout")
        expire(); expire(); release.signal()
        test.check(held && stopped.wait(timeout: .now() + .seconds(1)) == .success
            && callbacks.load(ordering: .acquiring) == 9 && releases.load(ordering: .acquiring) == 1
            && cancellations.load(ordering: .acquiring) == 1 && generation.load(ordering: .acquiring) == initialGeneration + 1,
            "control-timeout/normal-own-timeout-stops-once-with-existing-fence-and-no-double-release")
    }

    // A later stop already owns admission. A's stale deadline may terminalize A
    // but cannot advance B's generation, release its capabilities or enqueue IO.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let callbacks = ResidentAtomic<UInt64>(0)
        let first = requests.admit(timed, revision: revision), newer = requests.admit(stop, revision: revision)
        ResidentControlTimeout.expire(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, revision: revision, requests: requests,
            lifecycleGeneration: generation, capabilityGate: ResidentControlTimeout.CapabilityGate(),
            onTerminal: { callbacks.wrappingAdd(1, ordering: .acquiringAndReleasing) },
            releaseClaims: { callbacks.wrappingAdd(2, ordering: .acquiringAndReleasing) },
            cancelMaintenance: { callbacks.wrappingAdd(4, ordering: .acquiringAndReleasing) },
            enqueue: { job in callbacks.wrappingAdd(8, ordering: .acquiringAndReleasing); job() },
            continueStopping: { _ in callbacks.wrappingAdd(16, ordering: .acquiringAndReleasing) })
        test.check(newer.intent != nil && callbacks.load(ordering: .acquiring) == 1
            && generation.load(ordering: .acquiring) == initialGeneration
            && requests.result(requestID: newer.intent!.requestID, revision: revision).at(path: "phase")?.stringValue == "queued",
            "control-timeout/already-newer-admission-terminalizes-only-old-record-without-capability-or-epoch-effects")
    }

    // Actual store lock ordering: admission cannot reopen during the timeout's
    // injected atomic-fence boundary. This gate is a fixture-only deliberate stall.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let first = requests.admit(timed, revision: revision)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let expired = DispatchSemaphore(value: 0), attempted = DispatchSemaphore(value: 0), admitted = DispatchSemaphore(value: 0)
        let outcome = ResidentAtomic<UInt64>(0)
        DispatchQueue(label: "fixture.control.timeout.atomic-fence").async {
            _ = requests.expire(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, revision: revision, allocateGeneration: {
                entered.signal(); _ = release.wait(timeout: .now() + .seconds(2))
                return generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
            }); expired.signal()
        }
        let held = entered.wait(timeout: .now() + .seconds(1)) == .success
        DispatchQueue(label: "fixture.control.timeout.atomic-admission").async {
            attempted.signal()
            if let intent = requests.admit(next, revision: revision).intent,
               intent.admissionSequence > first.intent!.admissionSequence,
               generation.load(ordering: .acquiring) == initialGeneration + 1 { outcome.store(1, ordering: .releasing) }
            admitted.signal()
        }
        let tried = attempted.wait(timeout: .now() + .seconds(1)) == .success
        let reopenedEarly = admitted.wait(timeout: .now()) == .success
        release.signal()
        test.check(held && tried && !reopenedEarly && expired.wait(timeout: .now() + .seconds(1)) == .success
            && admitted.wait(timeout: .now() + .seconds(1)) == .success && outcome.load(ordering: .acquiring) == 1,
            "control-timeout/atomic-fence-precedes-terminal-record-and-concurrent-new-admission")
    }

    // Force the former check/mutation gap: A is inside claim release while B
    // is admitted and begins. The real shared gate keeps B's capability start
    // behind A; once B enables, A cannot publish/stop or disable B afterward.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let capabilityGate = ResidentControlTimeout.CapabilityGate()
        let claims = ResidentAtomic<Bool>(true), stops = ResidentAtomic<UInt64>(0), cancellations = ResidentAtomic<UInt64>(0)
        let first = requests.admit(timed, revision: revision)
        let releasing = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let expired = DispatchSemaphore(value: 0), starting = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        DispatchQueue(label: "fixture.control.timeout.release-gap").async {
            ResidentControlTimeout.expire(requestID: first.intent!.requestID, expectedAdmissionSequence: first.intent!.admissionSequence, revision: revision, requests: requests,
                lifecycleGeneration: generation, capabilityGate: capabilityGate, onTerminal: {}, releaseClaims: {
                    releasing.signal(); _ = release.wait(timeout: .now() + .seconds(2))
                    claims.store(false, ordering: .releasing)
                }, cancelMaintenance: { cancellations.wrappingAdd(1, ordering: .acquiringAndReleasing) },
                enqueue: { $0() }, continueStopping: { _ in stops.wrappingAdd(1, ordering: .acquiringAndReleasing) })
            expired.signal()
        }
        let held = releasing.wait(timeout: .now() + .seconds(1)) == .success
        let newer = requests.admit(next, revision: revision)
        let began = requests.begin(requestID: newer.intent!.requestID, expectedAdmissionSequence: newer.intent!.admissionSequence) { generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1 }
        DispatchQueue(label: "fixture.control.timeout.new-input-start").async {
            starting.signal()
            capabilityGate.perform { claims.store(true, ordering: .releasing) }
            started.signal()
        }
        let tried = starting.wait(timeout: .now() + .seconds(1)) == .success
        let startedBeforeOldRelease = started.wait(timeout: .now()) == .success
        release.signal()
        test.check(held && tried && !startedBeforeOldRelease && began == initialGeneration + 2
            && expired.wait(timeout: .now() + .seconds(1)) == .success && started.wait(timeout: .now() + .seconds(1)) == .success
            && claims.load(ordering: .acquiring) && cancellations.load(ordering: .acquiring) == 0
            && stops.load(ordering: .acquiring) == 0 && generation.load(ordering: .acquiring) == initialGeneration + 2,
            "control-timeout/forced-release-gap-cannot-disable-completed-new-input-or-cancel-new-maintenance")
    }

    // No unbounded tombstone: retire A from the real 64-record cache, admit B
    // under the same string ID, then run each actual late A callback boundary.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let callbacks = ResidentAtomic<UInt64>(0), capabilityGate = ResidentControlTimeout.CapabilityGate()
        let old = requests.admit(timed, revision: revision).intent!
        let oldDeadline: @Sendable () -> Void = {
            ResidentControlTimeout.expire(requestID: old.requestID, expectedAdmissionSequence: old.admissionSequence,
                revision: revision, requests: requests, lifecycleGeneration: generation, capabilityGate: capabilityGate,
                onTerminal: { callbacks.wrappingAdd(1, ordering: .acquiringAndReleasing) },
                releaseClaims: { callbacks.wrappingAdd(2, ordering: .acquiringAndReleasing) },
                cancelMaintenance: { callbacks.wrappingAdd(4, ordering: .acquiringAndReleasing) },
                enqueue: { job in callbacks.wrappingAdd(8, ordering: .acquiringAndReleasing); job() },
                continueStopping: { _ in callbacks.wrappingAdd(16, ordering: .acquiringAndReleasing) })
        }
        _ = requests.complete(requestID: old.requestID, expectedAdmissionSequence: old.admissionSequence,
            status: .accepted, revision: revision, reason: nil)
        for index in 0..<Int(evictionCount) {
            var entry = stop; entry["request_id"] = .string(evictionPrefix + String(index))
            let intent = requests.admit(entry, revision: revision).intent!
            _ = requests.complete(requestID: intent.requestID, expectedAdmissionSequence: intent.admissionSequence,
                status: .accepted, revision: revision, reason: nil)
        }
        let evicted = requests.result(requestID: old.requestID, revision: revision).at(path: "reason")?.stringValue == "control_request_unknown"
        let newer = requests.admit(reused, revision: revision)
        test.check(evicted && newer.intent?.requestID == old.requestID && newer.intent!.admissionSequence > old.admissionSequence
            && newer.result.at(path: "control_admission_sequence")?.intValue == Int64(newer.intent!.admissionSequence),
            "control-timeout/terminal-eviction-reuses-ID-with-distinct-captured-admission-token")
        oldDeadline()
        test.check(callbacks.load(ordering: .acquiring) == 0 && generation.load(ordering: .acquiring) == initialGeneration
            && requests.result(requestID: old.requestID, revision: revision) == newer.result,
            "control-timeout/evicted-old-deadline-cannot-terminalize-release-or-fence-reused-ID")
        let oldBegin = requests.begin(requestID: old.requestID, expectedAdmissionSequence: old.admissionSequence) {
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
        }
        test.check(oldBegin == nil && generation.load(ordering: .acquiring) == initialGeneration
            && requests.result(requestID: old.requestID, revision: revision) == newer.result,
            "control-timeout/evicted-old-queued-action-cannot-begin-new-record-with-old-intent")
        let oldComplete = requests.complete(requestID: old.requestID, expectedAdmissionSequence: old.admissionSequence,
            status: .failed, revision: revision, reason: "old_callback")
        test.check(oldComplete == nil && requests.result(requestID: old.requestID, revision: revision) == newer.result,
            "control-timeout/evicted-old-completion-cannot-complete-or-overwrite-reused-ID")
        let began = requests.begin(requestID: newer.intent!.requestID, expectedAdmissionSequence: newer.intent!.admissionSequence) {
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
        }
        let completed = requests.complete(requestID: newer.intent!.requestID, expectedAdmissionSequence: newer.intent!.admissionSequence,
            status: .accepted, revision: revision, reason: nil)
        test.check(began == initialGeneration + 1 && completed?.at(path: "status")?.stringValue == "accepted"
            && completed?.at(path: "control_admission_sequence")?.intValue == Int64(newer.intent!.admissionSequence),
            "control-timeout/reused-ID-current-action-still-begins-and-completes-nonvacuously")
    }

    // A later accepted stop owns the next lifecycle operation even before begin;
    // an older queued start must not supersede that stop when the lane resumes.
    do {
        let requests = ResidentControlRequests(), generation = ResidentAtomic<UInt64>(initialGeneration)
        let old = requests.admit(timed, revision: revision).intent!, newer = requests.admit(stop, revision: revision).intent!
        let oldBegin = requests.begin(requestID: old.requestID, expectedAdmissionSequence: old.admissionSequence) {
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
        }
        let newBegin = requests.begin(requestID: newer.requestID, expectedAdmissionSequence: newer.admissionSequence) {
            generation.wrappingAdd(1, ordering: .acquiringAndReleasing) + 1
        }
        test.check(oldBegin == nil && newBegin == initialGeneration + 1
            && requests.result(requestID: newer.requestID, revision: revision).at(path: "phase")?.stringValue == "queued",
            "control-timeout/new-stop-admission-dominates-old-queued-lifecycle-before-epoch-allocation")
    }
}
