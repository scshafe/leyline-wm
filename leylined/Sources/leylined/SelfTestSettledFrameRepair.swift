import Foundation
import LeylineModel

func runSettledFrameRepairScenarios(test: inout SelfTest) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/feed/settled-frame-repair.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let target = Frame.from(fixture.at(path: "target")),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 7 else {
        test.check(false, "settled-frame-repair/nonempty-fixture-load"); return
    }
    for row in scenarios {
        test.check(residentFrameRepairCandidate(initial: Frame.from(row.at(path: "initial")),
            current: Frame.from(row.at(path: "current"))!, target: target) == row.at(path: "candidate")!.boolValue!,
            "settled-frame-repair/" + row.at(path: "name")!.stringValue!)
    }
}
