import Foundation
import LeylineModel

/// Actual bootstrap/server and startup seed gate, with held capture and delayed
/// reconciliation completion. No AppKit, AX, input, timers or live sockets.
func runResidentStartupSeedGateScenarios(check: (String, Bool) -> Void) {
    let folder = SelfTestFixtures.url("startup")
    do {
        let fixture = try JSONValue.parse(Data(contentsOf: folder.appendingPathComponent("native-seed-order.json")))
        guard let rawGeneration = fixture.at(path: "generation")?.intValue, rawGeneration > 0,
              let id = fixture.at(path: "request_id")?.stringValue, !id.isEmpty,
              let seed = fixture.at(path: "seed")?.objectValue,
              seed["windows"]?.arrayValue?.count == 2,
              let partial = fixture.at(path: "partial_seed")?.objectValue,
              let starting = fixture.at(path: "starting_delta")?.objectValue,
              let off = fixture.at(path: "initial_off")?.objectValue,
              let recoveryEvent = fixture.at(path: "recovery_event")?.stringValue else {
            check("native-startup/fixture-shape", false); return
        }
        let generation = ResidentAtomic<UInt64>(UInt64(rawGeneration))
        let server = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/native-startup-unused.sock")
        _ = server.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
        _ = server.applyWorldDelta(starting)
        let gate = ResidentStartupSeedGate(), continuation = Recorded<ResidentStartupSeedGate.Scope>()
        let token = gate.arm(generation: generation.load(ordering: .acquiring), observationEpoch: server.observationEpoch)!
        server.setCommittedSnapshotHandler { snapshot in
            if let admitted = gate.observe(snapshot, generation: generation.load(ordering: .acquiring), observationEpoch: server.observationEpoch) {
                continuation.append(admitted)
            }
        }
        let bootstrap = CoreStartupBootstrap(server: server)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        bootstrap.schedule(execute: { DispatchQueue(label: "fixture.native-startup.capture").async(execute: $0) }, capture: {
            entered.signal(); _ = release.wait(timeout: .now() + .seconds(2))
            _ = server.applyWorldDelta(seed, requiredObservationEpoch: bootstrap.requiredObservationEpoch)
            returned.signal()
        }, discard: {})
        let held = entered.wait(timeout: .now() + .seconds(1)) == .success
        check("native-startup/pending-held-capture-keeps-Starting-and-claims-OFF-without-reconciliation-or-global-stop",
            held && continuation.count == 0 && gate.blocksClaims && !server.worldSeedReady
            && server.worldState.at(path: "management_enabled")?.boolValue != false
            && server.worldState.at(path: "resident_status")?.stringValue == "Starting")
        check("native-startup/health-remains-readable-while-capture-is-held",
            server.committedSnapshot.world.at(path: "observation.world_failure_code")?.stringValue == "bootstrap_pending"
                && server.currentRevision >= 2)
        release.signal()
        let captured = returned.wait(timeout: .now() + .seconds(1)) == .success
        check("native-startup/genuine-complete-seed-admits-one-reconciliation-but-not-input-readiness",
            captured && continuation.count == 1 && continuation.last == token && gate.blocksClaims && server.worldSeedReady)
        _ = server.applyWorldDelta(seed)
        check("native-startup/duplicate-seed-cannot-queue-a-second-startup-reconciliation", continuation.count == 1 && gate.blocksClaims)
        let baseline = server.committedSnapshot
        let result: JSONValue = .object(["request_id": .string(id), "phase": .string("completed"),
            "action_id": .string("world.reconcile"), "origin": .string("internal_reconcile"), "status": .string("accepted"),
            "revision": .int(Int64(clamping: baseline.revision)), "reconciliation_ready": .bool(true),
            "reconciliation_verified_scope": ResidentActionController.reconciliationScope(baseline.world)])
        let proof = CoreRuntimeServices.startupReconciliationMatches(result, requestID: id, baselineRevision: baseline.revision, world: baseline.world)
        check("native-startup/accepted-current-partition-proof-completes-startup-gate",
            proof && gate.finish(token, generation: generation.load(ordering: .acquiring), observationEpoch: server.observationEpoch) && !gate.blocksClaims)
        check("native-startup/final-publication-guard-accepts-current-proof",
            CoreRuntimeServices.startupPublicationRefusal(result, requestID: id, baselineRevision: baseline.revision, world: baseline.world,
                partitions: baseline.world.at(path: "model_state.space_partitions"), generation: token.generation,
                currentGeneration: token.generation) == nil)
        var changed = baseline.world.objectValue ?? [:]
        changed["observer_epoch"] = .string("fixture_new_epoch")
        check("native-startup/final-publication-refuses-stale-epoch-or-lifecycle-before-readiness-can-be-authored",
            CoreRuntimeServices.startupPublicationRefusal(result, requestID: id, baselineRevision: baseline.revision, world: .object(changed),
                partitions: baseline.world.at(path: "model_state.space_partitions"), generation: token.generation, currentGeneration: token.generation) != nil
            && CoreRuntimeServices.startupPublicationRefusal(result, requestID: id, baselineRevision: baseline.revision, world: baseline.world,
                partitions: baseline.world.at(path: "model_state.space_partitions"), generation: token.generation, currentGeneration: token.generation + 1) != nil)

        let partialGate = ResidentStartupSeedGate()
        let partialToken = partialGate.arm(generation: token.generation, observationEpoch: server.observationEpoch)!
        _ = server.applyWorldDelta(partial)
        check("native-startup/partial-seed-cannot-begin-reconciliation-or-become-OFF",
            partialGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: server.observationEpoch) == nil
            && partialGate.blocksClaims && server.worldState.at(path: "management_enabled")?.boolValue != false)
        var recovered = seed; recovered["event"] = .string(recoveryEvent)
        _ = server.applyWorldDelta(recovered)
        let recovery = partialGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: server.observationEpoch)
        check("native-startup/distinct-complete-recovery-baseline-unblocks-initial-partial-seed",
            recovery == partialToken && partialGate.blocksClaims)
        let paused = partialGate.waitForRecovery(partialToken, generation: token.generation, observationEpoch: server.observationEpoch)
        var telemetry = recovered; telemetry["event"] = .string("action_result")
        _ = server.applyWorldDelta(telemetry)
        check("native-startup/failed-reconciliation-does-not-rearm-from-its-own-result-or-cached-health",
            paused && partialGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: server.observationEpoch) == nil
            && partialGate.blocksClaims)
        _ = server.applyWorldDelta(recovered)
        check("native-startup/later-external-recovery-can-rearm-once-after-source-loss",
            partialGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: server.observationEpoch) == partialToken)

        let stopped = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/native-startup-off-unused.sock")
        _ = stopped.applyWorldDelta(off)
        _ = stopped.applyWorldDelta(seed)
        let offGate = ResidentStartupSeedGate()
        let offToken = offGate.arm(generation: token.generation, observationEpoch: stopped.observationEpoch)!
        check("native-startup/initial-OFF-never-admits-complete-seed-or-starts-input",
            offGate.observe(stopped.committedSnapshot,
                generation: token.generation, observationEpoch: stopped.observationEpoch) == nil && offGate.blocksClaims)
        _ = stopped.applyWorldDelta(off)
        check("native-startup/retired-observation-epoch-refuses-queued-seed-and-reconciliation-completion",
            offGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: stopped.observationEpoch) == nil
                && !offGate.finish(offToken, generation: token.generation, observationEpoch: stopped.observationEpoch))
        offGate.cancel()
        check("native-startup/explicit-lifecycle-cancels-boot-continuation-without-resurrecting-old-token",
            !offGate.isCurrent(offToken, generation: token.generation, observationEpoch: offToken.observationEpoch)
                && offGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: offToken.observationEpoch) == nil)

        let heldServer = CoreServer(socketPath: "/tmp/leyline-tests-\(getpid())/native-startup-stop-unused.sock")
        _ = heldServer.applyWorldDelta(CoreStartupBootstrap.pendingDelta)
        let heldGate = ResidentStartupSeedGate()
        _ = heldGate.arm(generation: token.generation, observationEpoch: heldServer.observationEpoch)
        let heldBootstrap = CoreStartupBootstrap(server: heldServer)
        let captureEntered = DispatchSemaphore(value: 0), releaseCapture = DispatchSemaphore(value: 0), captureReturned = DispatchSemaphore(value: 0)
        let staleRefused = ResidentAtomic<Bool>(false)
        heldBootstrap.schedule(execute: { DispatchQueue(label: "fixture.native-startup.stop-capture").async(execute: $0) }, capture: {
            captureEntered.signal(); _ = releaseCapture.wait(timeout: .now() + .seconds(2))
            let landed = heldServer.applyWorldDelta(seed, requiredObservationEpoch: heldBootstrap.requiredObservationEpoch)
            staleRefused.store(landed.status == .refused, ordering: .releasing)
            captureReturned.signal()
        }, discard: {})
        let captureHeld = captureEntered.wait(timeout: .now() + .seconds(1)) == .success
        heldGate.cancel()
        let stoppedWhileHeld = heldServer.applyWorldDelta(off)
        releaseCapture.signal()
        check("native-startup/stop-completes-during-held-capture-and-returning-stale-seed-cannot-resume",
            captureHeld && stoppedWhileHeld.status == .accepted
                && captureReturned.wait(timeout: .now() + .seconds(1)) == .success && staleRefused.load(ordering: .acquiring)
                && !heldServer.worldSeedReady && heldServer.worldState.at(path: "management_enabled")?.boolValue == false
                && heldGate.observe(server.committedSnapshot, generation: token.generation, observationEpoch: heldServer.observationEpoch) == nil)
    } catch { check("native-startup/fixture-error: \(error)", false) }
}
