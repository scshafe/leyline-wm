#!/usr/bin/env python3
"""Mutation checks for crash measurement boundaries; no resident is killed."""
from __future__ import annotations
import copy
import importlib.util
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest

import acceptance_scenarios as frozen

spec = importlib.util.spec_from_file_location("crash_measurement", Path(__file__).with_name("measure-crash-recovery.py"))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


def ready_snapshot() -> dict:
    frame = {"x": 0, "y": 38, "w": 500, "h": 400}
    return {"world": {"resident_running": True, "management_enabled": True,
        "observation": {"world_complete": True}, "observer_epoch": "epoch",
        "last_result": {"status": "accepted"}, "windows": [{"window_id": 10, "frame": frame}],
        "startup_readiness": {"readiness_verified": True, "reconciliation_result": {
            "reconciliation_ready": True, "reconciliation_verified_scope": {"observer_epoch": "epoch"},
            "requested_frames": {"10": dict(frame)}}}},
        "health": {"resident": {"effects": {"in_flight": None, "pending_count": 0},
            "input": {"tap_installed": True, "accepting_claims": True, "claims_allowed": True}}}}


class CrashMeasurementTests(unittest.TestCase):
    def test_verified_current_startup_and_claims_are_required(self):
        baseline = ready_snapshot()
        self.assertTrue(measurement.converged(baseline))
        for path in [("world", "resident_running"), ("world", "startup_readiness", "readiness_verified"),
                     ("health", "resident", "input", "claims_allowed")]:
            changed = copy.deepcopy(baseline); target = changed
            for key in path[:-1]: target = target[key]
            target[path[-1]] = False
            self.assertFalse(measurement.converged(changed), path)

    def test_quiet_failed_or_unproven_startup_cannot_pass(self):
        changed = ready_snapshot(); changed["world"]["last_result"]["status"] = "failed"
        self.assertFalse(measurement.converged(changed))
        changed = ready_snapshot(); del changed["world"]["startup_readiness"]
        self.assertFalse(measurement.converged(changed))

    def test_old_epoch_and_unlanded_geometry_cannot_pass(self):
        changed = ready_snapshot(); changed["world"]["observer_epoch"] = "replacement"
        self.assertFalse(measurement.converged(changed))
        changed = copy.deepcopy(ready_snapshot()); changed["world"]["windows"][0]["frame"]["x"] = 40
        self.assertFalse(measurement.converged(changed))

    def test_nearest_rank_statistics_keep_absolute_endpoints(self):
        self.assertEqual(measurement.distribution(list(range(1, 21))),
                         {"p50_ms": 10, "p95_ms": 19, "p99_ms": 20, "max_ms": 20})

    def test_measurer_ceilings_match_frozen_scenarios(self):
        scenarios = frozen.load_frozen_scenarios()
        budgets = {row["id"]: row for row in scenarios["budgets"]}
        self.assertEqual(measurement.ceilings(scenarios), {
            "serving_p95_ms": budgets["crash_serving"]["p95_ms"], "convergence_p95_ms": budgets["serving_converged"]["p95_ms"],
            "minimum_trials": 20, "window_counts": [1, 6, 12, 20]})
        # The ceilings the measurer enforced before it read them from the frozen file.
        self.assertEqual((budgets["crash_serving"]["p95_ms"], budgets["serving_converged"]["p95_ms"]), (3000, 2000))
        relaxed = copy.deepcopy(scenarios); relaxed["budgets"][0]["p95_ms"] += 1
        self.assertEqual(frozen.scenario_digest(scenarios), frozen.SCENARIOS_SHA256)
        self.assertNotEqual(frozen.scenario_digest(relaxed), frozen.SCENARIOS_SHA256)

    def test_rpc_dribbling_cannot_extend_one_total_deadline(self):
        with tempfile.TemporaryDirectory(prefix="crpc-") as directory:
            path = Path(directory) / "s"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path)); listener.listen(1)
                def dribble():
                    with listener.accept()[0] as peer:
                        peer.recv(1024)
                        try:
                            peer.sendall(struct.pack(">I", 1000))
                            for _ in range(12):
                                peer.sendall(b" "); time.sleep(0.04)
                        except OSError: pass
                worker = threading.Thread(target=dribble); worker.start()
                started = time.monotonic()
                with self.assertRaises((TimeoutError, socket.timeout)):
                    measurement.rpc(path, "hello")
                elapsed = time.monotonic() - started
                worker.join(timeout=1)
                self.assertLess(elapsed, 0.45)


if __name__ == "__main__": unittest.main()
