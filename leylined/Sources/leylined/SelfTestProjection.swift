// self-test projection — the border projection's pure half over a RECORDED
// revision stream. Hermetic by construction: it drives
// `BorderProjection.plan` and `BorderPalette`, touches no window server, no
// AX, no world. Renderer lifecycle is driven through its hermetic output
// surface, leaving the AppKit panels themselves outside this suite.
import Foundation
import LeylineModel

@MainActor
private final class RecordingBorderRenderSurface: BorderRenderSurface {
    private(set) var renderedPlans: [BorderPlan] = []
    private(set) var clearCount = 0

    func replace(
        plan: BorderPlan,
        store: JSONValue?
    ) -> BorderRenderSurfaceResult {
        renderedPlans.append(plan)
        return .rendered
    }

    func clear() {
        clearCount += 1
    }
}

private func focusWorld(_ wid: Int64, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                        mode: String? = nil, tiled: Bool? = nil,
                        framework: Bool? = nil) -> JSONValue {
    var focus: JSONObject = [:]
    focus["window_id"] = .int(wid)
    focus["managed"] = .bool(tiled != false && framework != true)
    focus["eligible"] = .bool(framework != true)
    focus["space_enabled"] = .bool(true)
    focus["space_visible"] = .bool(true)
    focus["space_key"] = .string("space:fixture-A")
    focus["display_id"] = .string("display:fixture-primary")
    focus["observer_generation"] = .int(1)
    focus["frame"] = .object(["x": .double(x), "y": .double(y), "w": .double(w), "h": .double(h)])
    if let tiled { focus["tiled"] = .bool(tiled) }
    if let framework { focus["framework"] = .bool(framework) }
    var world: JSONObject = [:]
    world["focus"] = .object(focus)
    world["observer_generation"] = .int(1)
    if mode != nil {
        world["mode_context_window_id"] = .int(wid)
        world["mode_context_space_key"] = .string("space:fixture-A")
    }
    if let mode { world["mode"] = .string(mode) }
    return .object(world)
}

func runProjectionSelfTest(sampleDirectory: String? = nil) -> Int32 {
    var test = SelfTest()
    func check(_ name: String, _ ok: Bool) { test.check(ok, name) }

    // ── a recorded focus-follow stream: the S1 drill set in miniature ──
    // click → same-app focus → Cmd-Tab → close (focus gone) → refocus.
    let stream: [(name: String, world: JSONValue, expect: BorderRing?)] = [
        ("click focuses a tiled window",
         focusWorld(101, 0, 38, 960, 1205, tiled: true),
         BorderRing(windowId: 101, frame: Frame(x: 0, y: 38, w: 960, h: 1205), role: .focus)),
        ("same-app focus moves the ring, same role",
         focusWorld(102, 960, 38, 960, 1205, tiled: true),
         BorderRing(windowId: 102, frame: Frame(x: 960, y: 38, w: 960, h: 1205), role: .focus)),
        ("unmanaged window has no border",
         focusWorld(103, 200, 200, 700, 500, tiled: false),
         nil),
        ("focus lost (window closed) → NO ring, never a stale one",
         .object([:]),
         nil),
        ("refocus after the close",
         focusWorld(101, 0, 38, 960, 1205, tiled: true),
         BorderRing(windowId: 101, frame: Frame(x: 0, y: 38, w: 960, h: 1205), role: .focus)),
    ]
    for step in stream {
        let plan = BorderProjection.plan(world: step.world)
        if let want = step.expect {
            check(step.name, plan.rings.count == 1 && plan.rings[0] == want)
        } else {
            check(step.name, plan.rings.isEmpty)
        }
    }

    // ── role derivation, including mode precedence ──
    check("resize mode overrides tiled → resizing",
          BorderProjection.plan(world: focusWorld(1, 0, 0, 10, 10, mode: "resize", tiled: true))
            .rings.first?.role == .resizing)
    check("move mode never decorates an unmanaged window",
          BorderProjection.plan(world: focusWorld(1, 0, 0, 10, 10, mode: "move", tiled: false))
            .rings.isEmpty)
    check("framework windows are ignored",
          BorderProjection.plan(world: focusWorld(1, 0, 0, 10, 10, tiled: false, framework: true))
            .rings.isEmpty)

    // ── degenerate input draws NOTHING (the filter lives in the pure half) ──
    check("zero-width frame → no ring",
          BorderProjection.plan(world: focusWorld(1, 0, 0, 0, 100)).rings.isEmpty)
    check("zero-height frame → no ring",
          BorderProjection.plan(world: focusWorld(1, 0, 0, 100, 0)).rings.isEmpty)
    check("focus without a frame → no ring",
          BorderProjection.plan(world: .object(["focus": .object(["window_id": .int(9)])])).rings.isEmpty)
    check("empty world → no ring",
          BorderProjection.plan(world: .object([:])).rings.isEmpty)
    runMovePreviewProjectionScenarios(sampleDirectory: sampleDirectory, check: check)

    // ── palette: defaults, override precedence, malformed-override rejection ──
    check("default focus colour",
          BorderPalette.color(.focus, store: nil) == "0xff39ff14")
    let override = JSONValue.object(["colors": .object(["focus": .string("0xff010203")])])
    check("user override wins over the default",
          BorderPalette.color(.focus, store: override) == "0xff010203")
    let malformed = JSONValue.object(["colors": .object(["focus": .string("lime")])])
    check("malformed override is IGNORED, not drawn as garbage",
          BorderPalette.color(.focus, store: malformed) == "0xff39ff14")
    check("every role resolves to a well-formed colour",
          BorderRole.allCases.allSatisfy { BorderPalette.isWellFormedColor(BorderPalette.color($0, store: nil)) })
    check("fixed thickness and configurable corner radius",
          BorderPalette.thickness == 1 && BorderPalette.radius(store: nil) == 12
            && BorderPalette.radius(store: .object(["border_radius": .int(5)])) == 5)
    check("menu status icon drawing", runResidentStatusIconSelfTest(sampleDirectory: sampleDirectory))

    let rendererFacts = MainActor.assumeIsolated { () -> (
        CoreProjectionHealth, CoreProjectionHealth, CoreProjectionHealth,
        CoreProjectionHealth
    ) in
        let healthy = BorderRenderer(
            store: nil, screenHeightProvider: { nil })
        _ = healthy.mount()
        let mounted = healthy.health
        _ = healthy.render(plan: .empty, revision: 1)

        let faulted = BorderRenderer(
            store: nil, screenHeightProvider: { nil })
        _ = faulted.mount()
        let plan = BorderPlan(rings: [BorderRing(
            windowId: 9, frame: Frame(x: 0, y: 0, w: 100, h: 100),
            role: .focus)])
        _ = faulted.render(plan: plan, revision: 2)
        let degraded = faulted.health
        _ = faulted.mount()
        return (
            mounted, healthy.health, degraded, faulted.health)
    }
    check("renderer health distinguishes mount from accepted render",
          rendererFacts.0.required == true && rendererFacts.0.mounted && !rendererFacts.0.degraded
            && rendererFacts.0.lastRenderedRevision == nil && rendererFacts.1.lastRenderedRevision == 1)
    check("renderer degradation is factual and explicit remount recovers",
          rendererFacts.2.required == true && !rendererFacts.2.mounted && rendererFacts.2.degraded
            && rendererFacts.2.degradedReason == "no_screen_available"
            && rendererFacts.2.lastRenderedRevision == nil && rendererFacts.3.mounted
            && !rendererFacts.3.degraded && rendererFacts.3.degradedReason == nil)

    let remountFacts = MainActor.assumeIsolated { () -> (
        firstRendered: Bool,
        beforeUnmount: CoreProjectionHealth,
        afterUnmount: CoreProjectionHealth,
        afterRemount: CoreProjectionHealth,
        currentRevisionRendered: Bool,
        finalHealth: CoreProjectionHealth,
        renderedPlans: [BorderPlan],
        clearCount: Int
    ) in
        let surface = RecordingBorderRenderSurface()
        let renderer = BorderRenderer(store: nil, surface: surface)
        let plan = BorderPlan(rings: [BorderRing(
            windowId: 77, frame: Frame(x: 10, y: 20, w: 300, h: 200),
            role: .focus)])
        _ = renderer.mount()
        let firstRendered = renderer.render(plan: plan, revision: 9)
        let beforeUnmount = renderer.health
        renderer.unmount()
        let afterUnmount = renderer.health
        _ = renderer.mount()
        let afterRemount = renderer.health
        // The immutable core snapshot is still revision 9. Teardown must have
        // invalidated the renderer's old evidence so revision 9 can rebuild.
        let currentRevisionRendered = renderer.render(plan: plan, revision: 9)
        return (
            firstRendered,
            beforeUnmount,
            afterUnmount,
            afterRemount,
            currentRevisionRendered,
            renderer.health,
            surface.renderedPlans,
            surface.clearCount)
    }
    check("renderer remount invalidates revision evidence and rebuilds current output",
          remountFacts.firstRendered
            && remountFacts.beforeUnmount.lastRenderedRevision == 9
            && !remountFacts.afterUnmount.mounted
            && remountFacts.afterUnmount.lastRenderedRevision == nil
            && remountFacts.afterRemount.mounted
            && remountFacts.afterRemount.lastRenderedRevision == nil
            && remountFacts.currentRevisionRendered
            && remountFacts.finalHealth.lastRenderedRevision == 9
            && remountFacts.renderedPlans.count == 2
            && remountFacts.renderedPlans[0] == remountFacts.renderedPlans[1]
            && remountFacts.clearCount == 1)


    return test.finish("projection")
}
