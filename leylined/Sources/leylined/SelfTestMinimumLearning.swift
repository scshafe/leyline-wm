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

private final class MinimumTestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[ResidentMinimumEvidence]] = []
    func append(_ evidence: [ResidentMinimumEvidence]) { lock.lock(); values.append(evidence); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private final class MinimumTestOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResidentEffectOutcome] = []
    func append(_ value: ResidentEffectOutcome) { lock.lock(); values.append(value); lock.unlock() }
    var last: ResidentEffectOutcome? { lock.lock(); defer { lock.unlock() }; return values.last }
}

func runMinimumLearningScenarios(test: inout SelfTest) {
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/effector/minimum_evidence.json"
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data),
          let before = Frame.from(fixture.at(path: "before")), let target = Frame.from(fixture.at(path: "target")),
          let clamp = Frame.from(fixture.at(path: "clamp")) else { test.check(false, "minimum/fixture-load"); return }
    func text(_ key: String) -> String { fixture.at(path: key)!.stringValue! }
    func number(_ key: String) -> UInt64 { UInt64(fixture.at(path: key)!.intValue!) }
    let id = text("window_id")
    let context = ResidentEffectContext(revision: 3, observerGeneration: number("generation"), activeSpaceKey: text("space"),
        topologyRevision: number("topology_revision"), trusted: true, complete: true, spaceEnabled: true)
    var request = ResidentEffectRequest(requestID: text("request_id"), actionID: "resize.adjust.west", windowID: id,
        expectedRevision: 3, observerGeneration: context.observerGeneration, activeSpaceKey: text("space"),
        topologyRevision: context.topologyRevision, receiptNanos: number("receipt"), frame: target)
    request.windowPids = [id: Int64(number("pid"))]; request.windowGenerations = [id: number("lifetime")]
    request.windowSpaceKeys = [id: text("space")]; request.windowDisplayIDs = [id: text("display")]
    request.windowApplicationKeys = [id: text("app")]; request.observerEpoch = text("epoch")
    func evidence(pid: Int64? = nil, lifetime: UInt64? = nil, epoch: String? = nil, space: String? = nil,
                  display: String? = nil, topology: UInt64? = nil, writeStamp: UInt64? = nil,
                  readStamp: UInt64? = nil, frame: Frame? = nil, prior: Frame? = nil,
                  confirmation: Frame? = nil, confirmationGeneration: UInt64? = nil,
                  confirmationStamp: UInt64? = nil, requestID: String? = nil,
                  axes: Set<ResidentMinimumAxis> = [.width]) -> ResidentMinimumEvidence {
        .init(write: .init(requestID: requestID ?? request.requestID, windowID: id, ownerPID: pid ?? Int64(number("pid")),
            windowGeneration: lifetime ?? number("lifetime"), observerEpoch: epoch ?? text("epoch"),
            observerGeneration: number("generation"), spaceKey: space ?? text("space"), displayID: display ?? text("display"),
            topologyRevision: topology ?? number("topology_revision"), before: prior ?? before, requested: target,
            axes: axes, completedNanos: writeStamp ?? number("write")), observed: frame ?? target,
            observedGeneration: number("generation"), readCompletedNanos: readStamp ?? number("read"),
            confirmationFrame: confirmation, confirmationGeneration: confirmation.map { _ in confirmationGeneration ?? number("generation") },
            confirmationCompletedNanos: confirmation.map { _ in confirmationStamp ?? number("confirmation") })
    }
    func refusal(_ proof: ResidentMinimumEvidence) -> String? {
        ResidentMinimumLearning.refusal(proof, request: request, currentGeneration: context.observerGeneration,
            issuedNanos: number("issue"), now: number("now"))
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
        && refusal(evidence(frame: clamp, confirmation: clamp, confirmationStamp: number("read"))) == "minimum_clamp_unproven",
        "minimum/motion-unchanged-cache-wrong-generation-and-reused-read-refuse-clamp-learning")
    let topology: JSONValue = .object(["displays": .array([.object(["id": .int(1), "frame": Frame(x: 0,y: 0,w: 1600,h: 900).json])])])
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
        let clock = ResidentAtomic<UInt64>(number("issue")), port = MinimumTestPort(), sink = MinimumTestSink()
        let effector = ResidentEffector(context: context, journal: journal, port: port,
            now: { clock.load(ordering: .acquiring) }, onMinimumEvidence: { _, evidence in sink.append(evidence) })
        _ = effector.submit(request); let acknowledged = port.acknowledge(); clock.store(number("now"), ordering: .releasing)
        test.check(acknowledged && sink.count == 0 && effector.observeMinimumEvidence(proof) && sink.count == 0,
            "minimum/actual-effector-retains-provenance-until-independent-whole-effect-verification")
        _ = effector.observe(requestID: request.requestID, windowID: id, frame: target, generation: context.observerGeneration,
            windowGeneration: number("lifetime"), timestampNanos: number("read"))
        test.check(sink.count == 1 && !effector.observeMinimumEvidence(proof),
            "minimum/actual-effector-publishes-eligible-evidence-once-and-retires-replays")
        let partialPort = MinimumTestPort(), partialSink = MinimumTestSink(), outcomes = MinimumTestOutcomes()
        clock.store(number("issue"), ordering: .releasing)
        let partial = ResidentEffector(context: context, journal: journal, port: partialPort,
            now: { clock.load(ordering: .acquiring) }, onMinimumEvidence: { _, evidence in partialSink.append(evidence) },
            onOutcome: { outcomes.append($0) })
        _ = partial.submit(request); let partialAck = partialPort.acknowledge(); clock.store(number("now"), ordering: .releasing)
        test.check(partialAck && partial.observeMinimumEvidence(settledClamp)
            && outcomes.last?.status == .failed && outcomes.last?.reason == "minimum_constraint"
            && outcomes.last?.verifiedNanos == nil && outcomes.last?.desiredStateCommittedRevision != nil
            && outcomes.last?.landedFrame == clamp && partialSink.count == 1
            && !partial.observeMinimumEvidence(settledClamp),
            "minimum/confirmed-clamp-completes-original-honestly-failed-with-once-only-learning-and-no-verified-stamp")
    } catch { test.check(false, "minimum/production-effector-provenance-fixture: \(error)") }
}
