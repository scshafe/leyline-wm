import Foundation
import LeylineModel

/// The port holds real production-barrier acknowledgments. Replaying an old
/// callback models duplicate transport delivery without modeling barrier state.
private final class InputStopBarrierTestPort: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []
    private var recordedEvents: [String] = []
    private var overflows = 0

    func stop(_ acknowledge: @escaping @Sendable () -> Void) {
        lock.withLock { callbacks.append(acknowledge) }
    }
    func acknowledge(_ index: Int) -> Bool {
        let callback = lock.withLock { callbacks.indices.contains(index) ? callbacks[index] : nil }
        guard let callback else { return false }
        callback()
        return true
    }
    func record(_ event: String) { lock.withLock { recordedEvents.append(event) } }
    func overflow() { lock.withLock { overflows += 1 } }
    var snapshot: (calls: Int, events: [String], overflows: Int) {
        lock.withLock { (callbacks.count, recordedEvents, overflows) }
    }
}

/// Deterministic source-backed lifecycle ordering checks. Every scenario drives
/// ResidentInputStopBarrier itself through an injected port and serial queue.
func runInputStopBarrierSelfTest() -> Int32 {
    var test = SelfTest()
    let path = responsivenessRepositoryRoot() + "/leylined/Fixtures/lifecycle/input-stop-barrier.json"
    guard let data = FileManager.default.contents(atPath: path),
          let fixture = try? JSONValue.parse(data),
          let stopEvent = fixture.at(path: "stop_event")?.stringValue,
          let scenarios = fixture.at(path: "scenarios")?.arrayValue,
          scenarios.count == 7,
          Set(scenarios.compactMap { $0.at(path: "name")?.stringValue }).count == scenarios.count else {
        test.check(false, "input-stop-barrier/nonempty-unique-seven-scenario-fixture")
        return test.finish("input-stop-barrier")
    }
    test.check(true, "input-stop-barrier/nonempty-unique-seven-scenario-fixture")
    for scenario in scenarios {
        guard let name = scenario.at(path: "name")?.stringValue,
              let steps = scenario.at(path: "steps")?.arrayValue, !steps.isEmpty else {
            test.check(false, "input-stop-barrier/scenario-fixture-invalid")
            continue
        }
        let queue = DispatchQueue(label: "leylined.test.input-stop-barrier.\(name)")
        let port = InputStopBarrierTestPort()
        let barrier = ResidentInputStopBarrier(queue: queue, stopPort: { port.stop($0) },
            didStop: { port.record(stopEvent) }, overflow: { port.overflow() })
        for (index, step) in steps.enumerated() {
            let label = "input-stop-barrier/\(name)/step-\(index)"
            guard let operation = step.at(path: "op")?.stringValue else {
                test.check(false, label + "/operation-missing")
                continue
            }
            switch operation {
            case "stop": barrier.stop()
            case "resume":
                guard let event = step.at(path: "event")?.stringValue else {
                    test.check(false, label + "/resume-event-missing"); continue
                }
                barrier.stop(resume: { port.record(event) })
            case "when_stopped":
                guard let event = step.at(path: "event")?.stringValue else {
                    test.check(false, label + "/ack-event-missing"); continue
                }
                barrier.whenStopped { port.record(event) }
            case "ack":
                guard let callback = step.at(path: "callback")?.intValue, callback >= 0,
                      port.acknowledge(Int(callback)) else {
                    test.check(false, label + "/port-callback-missing"); continue
                }
            default:
                test.check(false, label + "/unknown-operation"); continue
            }
            queue.sync {}
            guard let expected = step.at(path: "expect"),
                  let calls = expected.at(path: "stop_calls")?.intValue,
                  let events = expected.at(path: "events")?.arrayValue?.compactMap(\.stringValue),
                  let overflows = expected.at(path: "overflows")?.intValue else {
                test.check(false, label + "/expected-observation-missing"); continue
            }
            let actual = port.snapshot
            test.check(actual.calls == Int(calls), label + "/bounded-stop-port-calls")
            test.check(actual.events == events, label + "/exact-resume-and-maintenance-order")
            test.check(actual.overflows == Int(overflows), label + "/explicit-overflow-count")
        }
    }
    return test.finish("input-stop-barrier")
}
