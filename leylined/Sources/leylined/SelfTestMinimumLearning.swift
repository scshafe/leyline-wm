import Foundation
import LeylineModel

private final class MinimumTestPort: ResidentEffectorPort, @unchecked Sendable {
    private let condition = NSCondition()
    private var reply: (@Sendable (String?) -> Void)?
    func issue(request: ResidentEffectRequest, frame: Frame, completion: @escaping @Sendable (String?) -> Void) {
        condition.lock(); reply = completion; condition.broadcast(); condition.unlock()
    }
    func cancel(requestID: String) {}
    func acknowledge() -> Bool {
        condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while reply == nil { if !condition.wait(until: deadline) { condition.unlock(); return false } }
        let callback = reply; reply = nil; condition.unlock(); callback?(nil); return true
    }
}

func runMinimumLearningScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.path("effector/minimum_evidence.json")
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data),
          let before = Frame.from(fixture.at(path: "before")), let target = Frame.from(fixture.at(path: "target")),
          let clamp = Frame.from(fixture.at(path: "clamp")) else { test.check(false, "minimum/fixture-load"); return }
    let id = fixture.requiredString("window_id")
    let context = ResidentEffectContext(revision: 3, observerGeneration: fixture.requiredUInt64("generation"), activeSpaceKey: fixture.requiredString("space"),
        topologyRevision: fixture.requiredUInt64("topology_revision"), trusted: true, complete: true, spaceEnabled: true)
    var request = ResidentEffectRequest(requestID: fixture.requiredString("request_id"), actionID: "resize.adjust.west", windowID: id,
        expectedRevision: 3, observerGeneration: context.observerGeneration, activeSpaceKey: fixture.requiredString("space"),
        topologyRevision: context.topologyRevision, receiptNanos: fixture.requiredUInt64("receipt"), frame: target)
    request.windowPids = [id: Int64(fixture.requiredUInt64("pid"))]; request.windowGenerations = [id: fixture.requiredUInt64("lifetime")]
    request.windowSpaceKeys = [id: fixture.requiredString("space")]; request.windowDisplayIDs = [id: fixture.requiredString("display")]
    request.windowApplicationKeys = [id: fixture.requiredString("app")]; request.observerEpoch = fixture.requiredString("epoch")
    func evidence(pid: Int64? = nil, lifetime: UInt64? = nil, epoch: String? = nil, space: String? = nil,
                  display: String? = nil, topology: UInt64? = nil, writeStamp: UInt64? = nil,
                  readStamp: UInt64? = nil, frame: Frame? = nil, prior: Frame? = nil,
                  confirmation: Frame? = nil, confirmationGeneration: UInt64? = nil,
                  confirmationStamp: UInt64? = nil, requestID: String? = nil,
                  axes: Set<ResidentMinimumAxis> = [.width], rewriteRefused: Bool = false) -> ResidentMinimumEvidence {
        .init(write: .init(requestID: requestID ?? request.requestID, windowID: id, ownerPID: pid ?? Int64(fixture.requiredUInt64("pid")),
            windowGeneration: lifetime ?? fixture.requiredUInt64("lifetime"), observerEpoch: epoch ?? fixture.requiredString("epoch"),
            observerGeneration: fixture.requiredUInt64("generation"), spaceKey: space ?? fixture.requiredString("space"), displayID: display ?? fixture.requiredString("display"),
            topologyRevision: topology ?? fixture.requiredUInt64("topology_revision"), before: prior ?? before, requested: target,
            axes: axes, completedNanos: writeStamp ?? fixture.requiredUInt64("write")), observed: frame ?? target,
            observedGeneration: fixture.requiredUInt64("generation"), readCompletedNanos: readStamp ?? fixture.requiredUInt64("read"),
            confirmationFrame: confirmation, confirmationGeneration: confirmation.map { _ in confirmationGeneration ?? fixture.requiredUInt64("generation") },
            confirmationCompletedNanos: confirmation.map { _ in confirmationStamp ?? fixture.requiredUInt64("confirmation") },
            rewriteRefused: rewriteRefused)
    }
    func refusal(_ proof: ResidentMinimumEvidence) -> String? {
        ResidentMinimumLearning.refusal(proof, request: request, currentGeneration: context.observerGeneration,
            issuedNanos: fixture.requiredUInt64("issue"), now: fixture.requiredUInt64("now"))
    }
    let proof = evidence()
    test.check(refusal(proof) == nil, "minimum/exact-successful-issued-axis-and-fresh-matching-read-qualify")
    for (name, value) in [("pid", evidence(pid: 999)), ("lifetime", evidence(lifetime: 2)),
                          ("epoch", evidence(epoch: "other")), ("Space", evidence(space: "other")),
                          ("display", evidence(display: "other")), ("topology", evidence(topology: 99))] {
        test.check(refusal(value) == "minimum_write_identity_or_scope_changed", "minimum/rejects-wrong-" + name)
    }
    test.check(refusal(evidence(axes: [])) == "minimum_write_or_read_provenance_invalid"
        && refusal(evidence(prior: target)) == "minimum_write_or_read_provenance_invalid",
        "minimum/batch-ACK-and-preflight-noop-cannot-invent-written-axis")
    test.check(refusal(evidence(writeStamp: 99)) == "minimum_write_or_read_provenance_invalid"
        && refusal(evidence(readStamp: 109)) == "minimum_write_or_read_provenance_invalid"
        && refusal(evidence(readStamp: 131)) == "minimum_write_or_read_provenance_invalid",
        "minimum/rejects-preissue-preread-and-future-provenance")
    test.check(refusal(evidence(frame: clamp)) == "minimum_clamp_unproven"
        && refusal(evidence(frame: before)) == "minimum_clamp_unproven",
        "minimum/partial-progress-and-cached-unchanged-clamps-never-establish-new-floor")
    let settledClamp = evidence(frame: clamp, confirmation: clamp)
    test.check(refusal(settledClamp) == nil && ResidentMinimumLearning.settledClampAxes(settledClamp) == [.width],
        "minimum/separate-unchanged-postwrite-confirmation-proves-written-axis-shrink-clamp")
    var drifting = clamp; drifting.x += 8
    test.check(refusal(evidence(frame: clamp, confirmation: drifting)) == "minimum_clamp_unproven"
        && refusal(evidence(frame: before, confirmation: before)) == "minimum_clamp_unproven"
        && refusal(evidence(frame: clamp, confirmation: clamp, confirmationGeneration: 99)) == "minimum_clamp_unproven"
        && refusal(evidence(frame: clamp, confirmation: clamp, confirmationStamp: fixture.requiredUInt64("read"))) == "minimum_clamp_unproven",
        "minimum/motion-unchanged-cache-wrong-generation-and-reused-read-refuse-clamp-learning")
    // A window already at its floor: the first write and the repair pass's identical rewrite
    // both leave it unchanged at the requested position.
    let refusedTwice = ResidentMinimumLearning.repeatedRefusal(evidence(frame: before), rewriteRead: before,
        generation: fixture.requiredUInt64("generation"), completedNanos: fixture.requiredUInt64("confirmation"))
    test.check(refusedTwice?.rewriteRefused == true && refusedTwice.map(refusal) == .some(nil)
        && refusedTwice.flatMap(ResidentMinimumLearning.settledClampAxes) == [.width],
        "minimum/refused-identical-rewrite-at-requested-position-proves-floor-already-reached")
    test.check(ResidentMinimumLearning.repeatedRefusal(evidence(frame: before), rewriteRead: drifting,
            generation: fixture.requiredUInt64("generation"), completedNanos: fixture.requiredUInt64("confirmation")) == nil
        && ResidentMinimumLearning.repeatedRefusal(evidence(frame: before), rewriteRead: clamp,
            generation: fixture.requiredUInt64("generation"), completedNanos: fixture.requiredUInt64("confirmation")) == nil
        && ResidentMinimumLearning.repeatedRefusal(evidence(frame: before), rewriteRead: before,
            generation: fixture.requiredUInt64("generation"), completedNanos: fixture.requiredUInt64("read")) == nil,
        "minimum/moved-progressing-or-reused-rewrite-read-cannot-confirm-refusal")
    // An app floor can leave a second written axis one point short: that axis
    // landed by the effector's tolerance and cannot hide the other axis's floor.
    var nearlyLanded = before; nearlyLanded.h += 1
    let nearlyLandedRefusal = ResidentMinimumLearning.repeatedRefusal(
        evidence(frame: nearlyLanded, prior: nearlyLanded, axes: [.width, .height]), rewriteRead: nearlyLanded,
        generation: fixture.requiredUInt64("generation"), completedNanos: fixture.requiredUInt64("confirmation"))
    test.check(nearlyLandedRefusal.map(refusal) == .some(nil)
        && nearlyLandedRefusal.flatMap(ResidentMinimumLearning.settledClampAxes) == [.width]
        && nearlyLandedRefusal.map { ResidentMinimumLearning.learnedStore(evidence: [$0], request: request,
            store: .object([:]), topology: .object(["displays": .array([.object(["id": .int(1),
                "frame": Frame(x: 0, y: 0, w: 1600, h: 900).json])])])) } == .some(try! JSONValue.parse(Data(#"{"fixture.app":{"w":900}}"#.utf8))),
        "minimum/axis-within-landing-tolerance-does-not-hide-the-refused-axis-floor")
    var displaced = before; displaced.x += 8
    test.check(refusal(evidence(frame: displaced, confirmation: displaced, rewriteRefused: true)) == "minimum_clamp_unproven",
        "minimum/refused-rewrite-away-from-requested-position-cannot-learn")
    let topology: JSONValue = .object(["displays": .array([.object(["id": .int(1), "frame": Frame(x: 0,y: 0,w: 1600,h: 900).json])])])
    func stored(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }
    // Live shape 2026-10-16: the iOS Simulator's device window held 489x1047 against a
    // 511x641 tile, short on one axis and over on the other, through the identical rewrite.
    func rewritten(_ frame: Frame) -> ResidentMinimumEvidence? {
        ResidentMinimumLearning.repeatedRefusal(evidence(frame: frame, prior: frame, axes: [.width, .height]),
            rewriteRead: frame, generation: fixture.requiredUInt64("generation"),
            completedNanos: fixture.requiredUInt64("confirmation"))
    }
    let shape = Frame(x: target.x, y: target.y, w: target.w - 22, h: target.h + 406)
    let shapeRefusal = rewritten(shape)
    test.check(shapeRefusal.map(ResidentMinimumLearning.settledShapeRefusal) == true
        && shapeRefusal.flatMap(ResidentMinimumLearning.settledClampAxes) == nil
        && shapeRefusal.map(refusal) == .some(nil)
        && shapeRefusal.map { ResidentMinimumLearning.learnedStore(evidence: [$0], request: request,
            store: .object([:]), topology: topology) } == .object([:])
        && shapeRefusal.map { ResidentMinimumLearning.learnedFixedAspect(evidence: [$0], request: request,
            store: .array([.string("other.app")])) } == .array([.string("fixture.app"), .string("other.app")]),
        "minimum/refused-shape-learns-a-fixed-aspect-app-and-no-floor")
    test.check(rewritten(Frame(x: target.x, y: target.y, w: target.w - 7, h: target.h - 5)) == nil
        && rewritten(Frame(x: target.x, y: target.y, w: target.w - 22, h: target.h + 3)) == nil,
        "minimum/cell-rounding-short-on-both-axes-or-within-tolerance-is-no-shape-refusal")
    test.check(!ResidentMinimumLearning.settledShapeRefusal(evidence(frame: shape, prior: shape, confirmation: shape, axes: [.width, .height]))
        && !ResidentMinimumLearning.settledShapeRefusal(evidence(frame: shape, prior: shape, confirmation: shape, axes: [.height], rewriteRefused: true))
        && ResidentMinimumLearning.learnedFixedAspect(evidence: [evidence(frame: shape, prior: shape, confirmation: shape,
            axes: [.width, .height])], request: request, store: .array([])) == .array([]),
        "minimum/shape-refusal-needs-the-refused-rewrite-and-both-written-axes")
    if let refusedTwice {
        test.check(ResidentMinimumLearning.learnedStore(evidence: [refusedTwice], request: request, store: .object([:]), topology: topology)
                == stored(#"{"fixture.app":{"w":900}}"#)
            && ResidentMinimumLearning.learnedStore(evidence: [refusedTwice], request: request,
                store: fixture.at(path: "minimum_store")!, topology: topology)
                == stored(#"{"fixture.app":{"w":900,"h":900},"other.app":{"w":400}}"#),
            "minimum/refused-rewrite-learns-current-width-without-touching-unwritten-height")
    }
    let learned = ResidentMinimumLearning.learnedStore(evidence: [proof], request: request,
        store: fixture.at(path: "minimum_store")!, topology: topology)
    test.check(learned == fixture.at(path: "expected_store")!,
        "minimum/canonical-known-floor-self-heal-preserves-unwritten-axis-and-other-app")
    test.check((try? JSONValue.parse(Data(learned.canonical().utf8))) == learned,
        "minimum/canonical-learned-axis-survives-durable-JSON-roundtrip-with-exact-value-type")
    test.check(ResidentMinimumLearning.learnedStore(evidence: [proof], request: request, store: .object([:]), topology: topology) == .object([:]),
        "minimum/proven-target-fit-does-not-invent-unknown-upward-floor")
    test.check(ResidentMinimumLearning.learnedStore(evidence: [settledClamp], request: request,
        store: fixture.at(path: "minimum_store")!, topology: topology) == fixture.at(path: "expected_clamp_store")!
        && ResidentMinimumLearning.learnedStore(evidence: [settledClamp], request: request,
            store: .object([:]), topology: topology) == fixture.at(path: "expected_unknown_clamp_store")!,
        "minimum/confirmed-partial-shrink-learns-exact-floor-without-overwriting-unwritten-height")
    for value: JSONValue in [.array([]), .object(["app": .int(1)]), .object(["app": .object(["w": .int(0)])]),
                            .object(["app": .object(["h": .int(-1)])]), .object(["app": .object(["x": .int(2)])])] {
        test.check(!Minsize.validStore(value), "minimum/malformed-durable-table-is-not-empty-success")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minimum-proof-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ResidentEffectorFileJournal(path: directory.appendingPathComponent("journal.jsonl").path)
        let clock = ResidentAtomic<UInt64>(fixture.requiredUInt64("issue")), port = MinimumTestPort(), sink = Recorded<[ResidentMinimumEvidence]>()
        let effector = ResidentEffector(context: context, journal: journal, port: port,
            now: { clock.load(ordering: .acquiring) }, onMinimumEvidence: { _, evidence in sink.append(evidence) })
        _ = effector.submit(request); let acknowledged = port.acknowledge(); clock.store(fixture.requiredUInt64("now"), ordering: .releasing)
        test.check(acknowledged && sink.count == 0 && effector.observeMinimumEvidence(proof) && sink.count == 0,
            "minimum/actual-effector-retains-provenance-until-independent-whole-effect-verification")
        _ = effector.observe(requestID: request.requestID, windowID: id, frame: target, generation: context.observerGeneration,
            windowGeneration: fixture.requiredUInt64("lifetime"), timestampNanos: fixture.requiredUInt64("read"))
        test.check(sink.count == 1 && !effector.observeMinimumEvidence(proof),
            "minimum/actual-effector-publishes-eligible-evidence-once-and-retires-replays")
        let partialPort = MinimumTestPort(), partialSink = Recorded<[ResidentMinimumEvidence]>(), outcomes = Recorded<ResidentEffectOutcome>()
        clock.store(fixture.requiredUInt64("issue"), ordering: .releasing)
        let partial = ResidentEffector(context: context, journal: journal, port: partialPort,
            now: { clock.load(ordering: .acquiring) }, onMinimumEvidence: { _, evidence in partialSink.append(evidence) },
            onOutcome: { outcomes.append($0) })
        _ = partial.submit(request); let partialAck = partialPort.acknowledge(); clock.store(fixture.requiredUInt64("now"), ordering: .releasing)
        test.check(partialAck && partial.observeMinimumEvidence(settledClamp)
            && outcomes.last?.status == .failed && outcomes.last?.reason == "minimum_constraint"
            && outcomes.last?.verifiedNanos == nil && outcomes.last?.desiredStateCommittedRevision != nil
            && outcomes.last?.landedFrame == clamp && partialSink.count == 1
            && !partial.observeMinimumEvidence(settledClamp),
            "minimum/confirmed-clamp-completes-original-honestly-failed-with-once-only-learning-and-no-verified-stamp")
        if let shapeRefusal {
            let shapePort = MinimumTestPort(), shapeSink = Recorded<[ResidentMinimumEvidence]>(), shapeOutcomes = Recorded<ResidentEffectOutcome>()
            clock.store(fixture.requiredUInt64("issue"), ordering: .releasing)
            let shaped = ResidentEffector(context: context, journal: journal, port: shapePort,
                now: { clock.load(ordering: .acquiring) }, onMinimumEvidence: { _, evidence in shapeSink.append(evidence) },
                onOutcome: { shapeOutcomes.append($0) })
            _ = shaped.submit(request); let shapeAck = shapePort.acknowledge(); clock.store(fixture.requiredUInt64("now"), ordering: .releasing)
            test.check(shapeAck && shaped.observeMinimumEvidence(shapeRefusal)
                && shapeOutcomes.last?.status == .failed && shapeOutcomes.last?.reason == "fixed_aspect_constraint"
                && shapeOutcomes.last?.verifiedNanos == nil && shapeOutcomes.last?.desiredStateCommittedRevision != nil
                && shapeSink.count == 1 && shapeSink.last?.first.map(ResidentMinimumLearning.settledShapeRefusal) == true,
                "minimum/refused-shape-completes-failed-fixed-aspect-instead-of-evidence-timeout")
        }
    } catch { test.check(false, "minimum/production-effector-provenance-fixture: \(error)") }
}
