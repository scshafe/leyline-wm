import Foundation
import LeylineModel

/// Frozen expected rectangles cover stroke, shared spacing and OS canvas policy.
func runBorderSpacingScenarios(test: inout SelfTest) {
    let path = SelfTestFixtures.path("projection/border-spacing.json")
    guard let data = FileManager.default.contents(atPath: path), let fixture = try? JSONValue.parse(data),
          let cases = fixture.at(path: "cases")?.arrayValue, cases.count == 5,
          let screens = fixture.at(path: "screens")?.arrayValue, screens.count == 4 else {
        test.check(false, "border-spacing/independent-fixture-load"); return
    }
    test.check(BorderPalette.thickness == 1
        && BorderPalette.configurationDefaults.keys.sorted() == ["border_radius", "colors"],
        "border-spacing/width-is-fixed-and-absent-from-seeded-configuration")
    for scenario in cases {
        let width = scenario.at(path: "width")!.intValue!
        let topology = scenario.at(path: "topology")!
        let bridge = Arrangement.bridgeArrangementNative(store: scenario.at(path: "arrangement")!, topo: topology)
        let targets = Arrangement.arrangementTargetsRec(bridge: bridge, topo: topology)
        let left = Frame.from(targets.at(path: "1.frame")), right = Frame.from(targets.at(path: "2.frame"))
        test.check(left == Frame.from(scenario.at(path: "expected_left")) && right == Frame.from(scenario.at(path: "expected_right")),
            "border-spacing/width-\(width)-outer-reservation-and-single-shared-gutter")
        if width == Int64(BorderPalette.thickness), let left, let right {
            let thickness = Double(BorderPalette.thickness)
            test.check(BorderRing(windowId: 1, frame: left, role: .focus).envelope(thickness: thickness)
                == Frame.from(scenario.at(path: "expected_outer_left"))
                && BorderRing(windowId: 2, frame: right, role: .focus).envelope(thickness: thickness)
                == Frame.from(scenario.at(path: "expected_outer_right"))
                && right.x - left.maxX == thickness,
                "border-spacing/width-\(width)-actual-render-envelope-fills-display-and-shared-buffer")
        }
    }
    let nested = fixture.at(path: "nested")!
    let rounding = fixture.at(path: "edge_rounding")!
    let aligned = Frame.from(rounding.at(path: "frame"))!.roundedEdges()
    test.check(aligned == Frame.from(rounding.at(path: "expected"))
        && aligned.maxY + rounding.at(path: "border_width")!.numberValue! == rounding.at(path: "expected_bottom")!.numberValue!,
        "border-spacing/last-tile-rounds-shared-edges-without-clipping-bottom-stroke")
    let negative = fixture.at(path: "negative_edge_rounding")!
    let negativeLeft = Frame.from(negative.at(path: "left"))!.roundedEdges()
    let negativeRight = Frame.from(negative.at(path: "right"))!.roundedEdges()
    test.check(negativeLeft == Frame.from(negative.at(path: "expected_left"))
        && negativeRight == Frame.from(negative.at(path: "expected_right"))
        && negativeRight.x - negativeLeft.maxX == negative.at(path: "expected_gap")!.numberValue!,
        "border-spacing/negative-monitor-rounding-preserves-one-shared-border-width")
    let bridge = Arrangement.bridgeArrangementNative(store: nested.at(path: "arrangement")!, topo: nested.at(path: "topology")!)
    let targets = Arrangement.arrangementTargetsRec(bridge: bridge, topo: nested.at(path: "topology")!)
    test.check((nested.at(path: "expected_frames")!.objectValue!).allSatisfy { id, expected in
        Frame.from(targets.at(path: "\(id).frame")) == Frame.from(expected)
    }, "border-spacing/nested-edge-is-not-reserved-twice")
    for scenario in screens {
        let actual = coreTilingDisplayFrame(screen: Frame.from(scenario.at(path: "screen"))!,
            visible: Frame.from(scenario.at(path: "visible"))!, safeAreaTop: scenario.at(path: "safe_top")!.numberValue!,
            primaryHeight: scenario.at(path: "primary_height")!.numberValue!)
        test.check(actual == Frame.from(scenario.at(path: "expected")),
            "border-spacing/\(scenario.requiredString("name"))-fills-display-below-menu-and-notch")
    }
}
