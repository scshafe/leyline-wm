#!/usr/bin/env python3
"""Verify experimental native insertion against frozen D15 geometry and both engines.

Inputs: committed fixtures; --core-bin selects an undeployed model binary.
Side effects: temporary fixture files only. Repeatable; never contacts a daemon.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "tests/oracles/fixtures/largest-first"
JQ_AUTHOR = '''import "arrangement" as AR;
AR::bridge_arrangement_native_adopt(.store; .newcomers; .ndid; .focused;
                                   .topology; .insertion_policy; (.newcomer_minimums // {}))'''
JQ_SUMMARY = '''import "arrangement" as AR; import "parcel" as P;
. as $s | P::norm_topology($topo) as $T |
{valid: AR::valid_md($s.segments; $T).ok,
 frames: [AR::cells_md($s.segments; $T)[] |
          [$s.bindings[AR::_anchor_key(.)].window_id,
           .frame.x, .frame.y, .frame.w, .frame.h]] | sort_by(.[0])}'''


def run(command: list[str], payload: dict | None = None) -> object:
    """Run a hermetic model command; failures retain stderr and exit status."""
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True,
                            env={**os.environ, "LEYLINE_FRAME_TOL": "4"})
    return json.loads(result.stdout)


def jq(expression: str, payload: dict, *extra: str) -> object:
    return run(["jq", "-L", str(REPO / "tests/oracles/jq"), *extra, expression], payload)


def seed_store(scene: dict) -> dict:
    """Map fixture seed cells to existing canonical anchors; no insertion policy here."""
    topo = {"displays": scene["displays"], "gap": scene.get("gap", 0)}
    store = {"segments": scene.get("segments", []), "bindings": {},
             "off_top": [], "promotions": []}
    cells = jq('import "arrangement" as AR; import "parcel" as P; '
               '[AR::cells_md(.store.segments; P::norm_topology(.topology))[] | '
               '{key: AR::_anchor_key(.), frame: .frame}]', {"store": store, "topology": topo})
    for wid, x, y, w, h in scene["seed"]:
        match = next(c for c in cells if c["frame"] == dict(x=x, y=y, w=w, h=h))
        store["bindings"][match["key"]] = {"window_id": wid, "frame": match["frame"], **scene.get("binding_fields", {})}
    return store


def author(engine: str, core_bin: Path, fixture: dict, directory: Path) -> object:
    if engine == "jq":
        return jq(JQ_AUTHOR, fixture)
    path = directory / "input.json"
    path.write_text(json.dumps(fixture))
    return run([str(core_bin), "model", "adopt", "--fixture", str(path)])


def check_frames(store: dict, scene: dict, expected: list, label: str) -> None:
    summary = jq(JQ_SUMMARY, store, "--argjson", "topo",
                 json.dumps({"displays": scene["displays"], "gap": scene.get("gap", 0)}))
    assert summary["valid"] and summary["frames"] == sorted(expected), (label, summary, expected)


def validate_expected(scene: dict, frames: list) -> None:
    """Check frozen fixture coverage/overlap independently of either engine."""
    assert len({row[0] for row in frames}) == len(frames)
    gap = scene.get("gap", 0)
    for display in scene["displays"]:
        x, y, w, h = display.get("usable", display["frame"])
        x, y, w, h = x + gap, y + gap, w - 2 * gap, h - 2 * gap
        members = [r for r in frames if x <= r[1] and y <= r[2]
                   and r[1] + r[3] <= x + w and r[2] + r[4] <= y + h]
        assert sum(r[3] * r[4] for r in members) == w * h
        for i, a in enumerate(members):
            assert a[3] > 0 and a[4] > 0
            for b in members[i + 1:]:
                assert min(a[1] + a[3], b[1] + b[3]) <= max(a[1], b[1]) or \
                    min(a[2] + a[4], b[2] + b[4]) <= max(a[2], b[2])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-fixtures", action="store_true")
    parser.add_argument("--core-bin", type=Path, default=REPO / "leylined/.build/release/leylined")
    args = parser.parse_args()
    scenes = [(p.stem, json.loads(p.read_text())) for p in sorted(FIXTURES.glob("*.json"))]
    assert len(scenes) >= 10, "fixture corpus absent/incomplete"
    rows = 0
    with tempfile.TemporaryDirectory(prefix="leyline-largest-first-") as temp:
        directory = Path(temp)
        for name, scene in scenes:
            seed = seed_store(scene)
            validate_expected(scene, scene["seed"])
            check_frames(seed, scene, scene["seed"], name + "/seed")
            for step in scene.get("steps", []):
                expected = step["expect"]
                validate_expected(scene, expected)
                assert {row[0] for row in expected} >= set(step["newcomers"])
            if args.validate_fixtures:
                rows += 1
                continue
            topo = {"displays": scene["displays"], "gap": scene.get("gap", 0)}
            if "cases" in scene:
                for case in scene["cases"]:
                    store = json.loads(json.dumps(seed))
                    for binding in store["bindings"].values():
                        binding.update(case.get("binding_fields", {}))
                    store.update(case.get("store_fields", {}))
                    fx = dict(store=store, topology=topo, newcomers=case["newcomers"],
                              ndid=case.get("ndid", 1), focused="w:1",
                              insertion_policy=case.get("insertion_policy", "largest_first"))
                    for engine in ["jq", "core"]:
                        assert author(engine, args.core_bin, fx, directory) is None, (name, case, engine)
                        rows += 1
                continue
            for focus in [None, "w:1", "w:8", "w:999", "w:20"]:
                stores = {"jq": seed, "core": seed}
                for step in scene["steps"]:
                    for engine in stores:
                        fx = dict(store=stores[engine], newcomers=step["newcomers"],
                                  topology=topo, ndid=1, focused=focus, insertion_policy="largest_first",
                                  newcomer_minimums=scene.get("newcomer_minimums", {}))
                        stores[engine] = author(engine, args.core_bin, fx, directory)
                        assert stores[engine] is not None, (name, focus, engine)
                        check_frames(stores[engine], scene, step["expect"], name)
                        rows += 1
                    assert stores["jq"] == stores["core"], (name, "engine parity")
                if "expect_batch" in scene:
                    for engine in stores:
                        fx = dict(store=seed, newcomers=list(range(2, 9)), topology=topo,
                                  ndid=1, focused=focus, insertion_policy="largest_first",
                                  newcomer_minimums=scene.get("newcomer_minimums", {}))
                        batch = author(engine, args.core_bin, fx, directory)
                        assert batch == stores[engine], (name, engine, "batch/single mismatch")
                        rows += 1
    print(f"largest-first: {rows} checks passed" + (" (fixtures only)" if args.validate_fixtures else ""))


if __name__ == "__main__":
    main()
