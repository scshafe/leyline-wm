import Foundation
import LeylineModel

func runSettledFrameRepairScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.url("feed/settled-frame-repair.json")
    guard let data = try? Data(contentsOf: path), let fixture = try? JSONValue.parse(data),
          let target = Frame.from(fixture.at(path: "target")),
          let scenarios = fixture.at(path: "scenarios")?.arrayValue, scenarios.count == 7 else {
        test.check(false, "settled-frame-repair/nonempty-fixture-load"); return
    }
    for row in scenarios {
        test.check(residentFrameRepairCandidate(initial: Frame.from(row.at(path: "initial")),
            current: Frame.from(row.at(path: "current"))!, target: target) == row.at(path: "candidate")!.boolValue!,
            "settled-frame-repair/" + row.requiredString("name"))
    }
    // An app one point off its target (e.g. a 960-wide floor asked for 959) has
    // landed for the effector; the repair pass must not call it drift.
    let onePoint = Frame(x: target.x, y: target.y, w: target.w + 1, h: target.h)
    let twoPoints = Frame(x: target.x, y: target.y, w: target.w + 2, h: target.h)
    test.check(residentFrameRepairLanded(current: onePoint, target: target)
        && !residentFrameRepairCandidate(initial: onePoint, current: onePoint, target: target)
        && !residentFrameRepairLanded(current: twoPoints, target: target),
        "settled-frame-repair/one-point-app-rounding-has-landed-not-drifted")
}
