#!/usr/bin/env python3
"""Verify native largest-first insertion against frozen D15 geometry.

Inputs: committed fixtures; --core-bin selects the developer model runner.
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


def run(command: list[str], payload: dict | None = None) -> object:
    """Run a hermetic model command; failures retain stderr and exit status."""
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True,
                            env={**os.environ, "LEYLINE_FRAME_TOL": "4"})
    return json.loads(result.stdout)


def model(core_bin: Path, directory: Path, command: str, fixture: dict) -> object:
    path = directory / "input.json"
    path.write_text(json.dumps(fixture))
    return run([str(core_bin), "model", command, "--fixture", str(path)])


def anchored_cells(core_bin: Path, directory: Path, segments: list, topo: dict) -> list:
    cells = model(core_bin, directory, "fn", {"fn": "cells_md", "arr": {"segments": segments}, "topology": topo})
    return [{"key": f"{c['display_id']}:{c['i0']}:{c['j0']}", "frame": c["frame"]} for c in cells]


def seed_store(core_bin: Path, directory: Path, scene: dict) -> dict:
    """Map fixture seed cells to existing canonical anchors."""
    topo = {"displays": scene["displays"], "gap": scene.get("gap", 0)}
    store = {"segments": scene.get("segments", []), "bindings": {}, "off_top": []}
    cells = anchored_cells(core_bin, directory, store["segments"], topo)
    for wid, x, y, w, h in scene["seed"]:
        match = next(c for c in cells if c["frame"] == dict(x=x, y=y, w=w, h=h))
        store["bindings"][match["key"]] = {"window_id": wid, "frame": match["frame"], **scene.get("binding_fields", {})}
    return store


def mutated(seed: dict, case: dict) -> dict:
    """Apply a case's binding/store overrides to a copy of the seed store."""
    store = json.loads(json.dumps(seed))
    for binding in store["bindings"].values():
        binding.update(case.get("binding_fields", {}))
    store.update(case.get("store_fields", {}))
    return store


def members(store: dict) -> list:
    """Every managed identity in a flat store: each binding's top and stacked members."""
    return [m["window_id"] for b in store["bindings"].values() for m in b.get("contents", [b])]


def check_accepted(result: dict | None, store: dict, case: dict) -> None:
    """Managed overload keeps every identity; infeasible newcomers stay hidden behind the top."""
    label = case["name"]
    assert result is not None, label
    assert sorted(members(result)) == sorted(set(members(store)) | set(case["newcomers"])), (label, result)
    stacks = [[m["window_id"] for m in b.get("contents", [b])] for b in result["bindings"].values()]
    if case.get("expect_hidden_newcomer"):
        home = result["bindings"]["1:0:0"]
        assert stacks == [[1] + case["newcomers"]] and home["stack_source"] == "overload", (label, result)
        assert all(m["presented"] is False for m in home["contents"][1:]), (label, result)
    if "expect_existing_stack" in case:
        assert sorted(stacks) == sorted([case["expect_existing_stack"], case["newcomers"]]), (label, result)


def check_frames(core_bin: Path, directory: Path, store: dict, scene: dict, expected: list, label: str) -> None:
    topo = {"displays": scene["displays"], "gap": scene.get("gap", 0)}
    valid = model(core_bin, directory, "fn", {"fn": "valid_md", "arr": {"segments": store["segments"]}, "topology": topo})
    frames = sorted([store["bindings"][c["key"]]["window_id"], c["frame"]["x"], c["frame"]["y"], c["frame"]["w"], c["frame"]["h"]]
                    for c in anchored_cells(core_bin, directory, store["segments"], topo))
    assert valid["ok"] and frames == sorted(expected), (label, valid, frames, expected)


def validate_expected(scene: dict, frames: list) -> None:
    """Check frozen fixture coverage/overlap independently of the model."""
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
    parser.add_argument("--core-bin", type=Path, default=REPO / "bin/leylined-tests")
    args = parser.parse_args()
    scenes = [(p.stem, json.loads(p.read_text())) for p in sorted(FIXTURES.glob("*.json"))]
    assert len(scenes) >= 10, "fixture corpus absent/incomplete"
    rows = 0
    with tempfile.TemporaryDirectory(prefix="leyline-largest-first-") as temp:
        directory = Path(temp)
        for name, scene in scenes:
            validate_expected(scene, scene["seed"])
            for step in scene.get("steps", []):
                validate_expected(scene, step["expect"])
                assert {row[0] for row in step["expect"]} >= set(step["newcomers"])
            if args.validate_fixtures:
                rows += 1
                continue
            seed = seed_store(args.core_bin, directory, scene)
            check_frames(args.core_bin, directory, seed, scene, scene["seed"], name + "/seed")
            topo = {"displays": scene["displays"], "gap": scene.get("gap", 0)}
            if "cases" in scene or "accepted_cases" in scene:
                for case in scene.get("cases", []) + scene.get("accepted_cases", []):
                    store = mutated(seed, case)
                    fx = dict(store=store, topology=topo, newcomers=case["newcomers"],
                              ndid=case.get("ndid", 1), focused="w:1")
                    result = model(args.core_bin, directory, "adopt", fx)
                    if case in scene.get("cases", []):
                        assert result is None, (name, case)
                    else:
                        check_accepted(result, store, case)
                    rows += 1
                continue
            for focus in [None, "w:1", "w:8", "w:999", "w:20"]:
                store = seed
                for step in scene["steps"]:
                    fx = dict(store=store, newcomers=step["newcomers"], topology=topo, ndid=1, focused=focus,
                              newcomer_minimums=scene.get("newcomer_minimums", {}))
                    store = model(args.core_bin, directory, "adopt", fx)
                    assert store is not None, (name, focus)
                    check_frames(args.core_bin, directory, store, scene, step["expect"], name)
                    rows += 1
                if "expect_batch" in scene:
                    fx = dict(store=seed, newcomers=list(range(2, 9)), topology=topo, ndid=1, focused=focus,
                              newcomer_minimums=scene.get("newcomer_minimums", {}))
                    assert model(args.core_bin, directory, "adopt", fx) == store, (name, "batch/single mismatch")
                    rows += 1
    print(f"largest-first: {rows} checks passed" + (" (fixtures only)" if args.validate_fixtures else ""))


if __name__ == "__main__":
    main()
