#!/usr/bin/env python3
"""Measure SIGKILL -> ordinary launchd serving/convergence; never kickstart.

Only the canonical signed resident named by its private socket and launchd job
is killed. All attempts and raw observations are retained. This measures OS and
socket boundaries, not keyboard input or compositor presentation.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import time

from acceptance_scenarios import load_frozen_scenarios, nearest_rank


def rpc(path: Path, operation: str) -> dict:
    deadline = time.monotonic() + 0.25
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(0.25)
        peer.connect(str(path))
        payload = json.dumps({"op": operation}).encode()
        peer.sendall(struct.pack(">I", len(payload)) + payload)
        def receive(count: int) -> bytes:
            data = bytearray()
            while len(data) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("RECOVERY.RPC_DEADLINE")
                peer.settimeout(remaining)
                chunk = peer.recv(count - len(data))
                if not chunk:
                    raise RuntimeError("RECOVERY.RPC_EOF")
                data.extend(chunk)
            return bytes(data)
        count = struct.unpack(">I", receive(4))[0]
        if not 0 < count < 64 * 1024 * 1024:
            raise RuntimeError("RECOVERY.RPC_BOUND")
        reply = json.loads(receive(count))
        if reply.get("ok") is not True:
            raise RuntimeError("RECOVERY.RPC_REFUSED")
        return reply


def process_path(pid: int) -> Path:
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise RuntimeError("RECOVERY.PROCESS_PATH_UNKNOWN")
    return Path(os.fsdecode(buffer.value)).resolve()


def converged(snapshot: dict) -> bool:
    world = snapshot.get("world", {})
    resident = snapshot.get("health", {}).get("resident", {})
    proof = world.get("startup_readiness", {})
    reconciliation = proof.get("reconciliation_result", {})
    observed = {str(w.get("window_id")): w for w in world.get("windows", [])}
    requested = reconciliation.get("requested_frames", {})
    landed = all(key in observed and all(abs(observed[key].get("frame", {}).get(axis, float("inf")) - target[axis]) <= 0.5
                 for axis in ("x", "y", "w", "h")) for key, target in requested.items())
    return (world.get("resident_running") is True
            and proof.get("readiness_verified") is True
            and reconciliation.get("reconciliation_ready") is True
            and reconciliation.get("reconciliation_verified_scope", {}).get("observer_epoch") == world.get("observer_epoch")
            and landed
            and world.get("observation", {}).get("world_complete") is True
            and world.get("management_enabled") is True
            and world.get("resident_unavailable_reason") is None
            and world.get("persistence_available") is not False
            and world.get("geometry_available") is not False
            and world.get("last_result", {}).get("status") in ("accepted", "noop")
            and resident.get("effects", {}).get("in_flight") is None
            and resident.get("effects", {}).get("pending_count") == 0
            and resident.get("input", {}).get("tap_installed") is True
            and resident.get("input", {}).get("accepting_claims") is True
            and resident.get("input", {}).get("claims_allowed") is True)


def distribution(values: list[float]) -> dict:
    return {f"p{rank}_ms": nearest_rank(values, rank) for rank in (50, 95, 99)} | {"max_ms": max(values)} if values else {}


def ceilings(scenarios: dict) -> dict:
    """The crash budgets and scene inventory the frozen scenarios own; no number here is local."""
    budgets = {row["id"]: row for row in scenarios["budgets"]}
    serving, converged = budgets["crash_serving"], budgets["serving_converged"]
    return {"serving_p95_ms": serving["p95_ms"], "convergence_p95_ms": converged["p95_ms"],
            "minimum_trials": max(serving["minimum_samples"], converged["minimum_samples"]),
            "window_counts": list(scenarios["window_counts"])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--build-binding", type=Path, required=True)
    parser.add_argument("--trials", type=int, help="attempts; default is the frozen minimum population")
    parser.add_argument("--label", default="org.leyline.leylined")
    args = parser.parse_args()
    limits = ceilings(load_frozen_scenarios())
    if args.trials is None:
        args.trials = limits["minimum_trials"]
    if not 1 <= args.trials <= 200 or args.output.exists():
        parser.error("trials must be1..200 and output must be new")
    binary = args.binary.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    source_root = Path(__file__).resolve().parents[2]
    head = subprocess.run(["/usr/bin/git", "-C", str(source_root), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()
    binding = json.loads(args.build_binding.read_text())
    sources = sorted((source_root / "leylined/Sources").rglob("*.swift")) + [source_root / "leylined/Package.swift"]
    actual_sources = {str(p.relative_to(source_root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    dirty = subprocess.run(["/usr/bin/git", "-C", str(source_root), "diff", "--quiet", "HEAD", "--",
                            "leylined/Sources", "leylined/Package.swift"], check=False).returncode
    if (args.source_commit != head or binding.get("source_commit") != head or dirty
            or binding.get("binary_sha256") != binary_hash or binding.get("source_files") != actual_sources
            or binding.get("source_drift") != []):
        raise RuntimeError("RECOVERY.BUILD_SOURCE_BINDING_INVALID")
    args.output.mkdir(mode=0o700)
    attempts = []
    window_count = None
    for trial in range(args.trials):
        initial = rpc(args.socket, "snapshot")
        pid = initial["pid"]
        count = sum(w.get("eligible") is True and w.get("space_visible") is True
                    and w.get("space_enabled") is True and w.get("minimized") is not True
                    and w.get("destroyed") is not True for w in initial.get("world", {}).get("windows", []))
        if window_count is None: window_count = count
        if count != window_count:
            raise RuntimeError("RECOVERY.SCENE_CHANGED")
        if not converged(initial) or process_path(pid) != binary:
            raise RuntimeError("RECOVERY.PRECONDITION_NOT_CONVERGED_CANONICAL_OWNER")
        job = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{args.label}"],
                             check=True, text=True, capture_output=True).stdout
        if f"pid = {pid}\n" not in job or hashlib.sha256(binary.read_bytes()).hexdigest() != binary_hash:
            raise RuntimeError("RECOVERY.OWNER_OR_BINARY_CHANGED")
        row = {"trial": trial + 1, "old_pid": pid, "initial_revision": initial["revision"],
               "origin": "process_fault", "synthetic": False, "observations": []}
        (args.output / f"initial-{trial + 1}.json").write_text(json.dumps(initial))
        receipt = time.monotonic_ns()
        os.kill(pid, signal.SIGKILL)
        row["receipt_ns"] = receipt
        row["receipt_provenance"] = "independent_sigkill_dispatch"
        deadline = receipt + 15_000_000_000
        while time.monotonic_ns() < deadline:
            try:
                hello = rpc(args.socket, "hello")
                observed = time.monotonic_ns()
                row["observations"].append({"uptime_ns": observed, "hello": hello})
                if hello["pid"] != pid and hello.get("ready") is True:
                    if row.get("replacement_pid") and (hello["pid"] != row["replacement_pid"] or hello.get("epoch_ms") != row["replacement_epoch_ms"]):
                        row["fatal_error"] = "RECOVERY.EXTRA_PROCESS_REPLACEMENT"; break
                    row.setdefault("replacement_pid", hello["pid"])
                    row.setdefault("replacement_epoch_ms", hello.get("epoch_ms"))
                    if process_path(hello["pid"]) != binary:
                        row["fatal_error"] = "RECOVERY.REPLACEMENT_BINARY_MISMATCH"; break
                    if row.get("new_pid") and (hello["pid"] != row["new_pid"] or hello.get("epoch_ms") != row["new_epoch_ms"]):
                        row["fatal_error"] = "RECOVERY.EXTRA_PROCESS_REPLACEMENT"; break
                    snapshot = rpc(args.socket, "snapshot")
                    snapshot_observed = time.monotonic_ns()
                    row["observations"].append({"uptime_ns": snapshot_observed, "snapshot": snapshot})
                    input_state = snapshot.get("health", {}).get("resident", {}).get("input", {})
                    if (snapshot["pid"] == hello["pid"]
                            and snapshot.get("world", {}).get("observation", {}).get("world_complete") is True
                            and input_state.get("accepting_claims") is True
                            and input_state.get("claims_allowed") is True):
                        row.setdefault("serving_ns", snapshot_observed)
                        row["new_pid"] = hello["pid"]; row["new_epoch_ms"] = hello.get("epoch_ms")
                    if snapshot["pid"] == hello["pid"] and converged(snapshot):
                        row["converged_ns"] = snapshot_observed
                        row["convergence_observed_in_serving_probe"] = row["serving_ns"] == snapshot_observed
                        row["final_revision"] = snapshot["revision"]
                        break
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                row["observations"].append({"uptime_ns": time.monotonic_ns(), "error": str(error)})
            time.sleep(0.02)
        row["correctness"] = bool(not row.get("fatal_error") and row.get("serving_ns")
                                  and row.get("converged_ns") and row.get("final_revision", -1) > initial["revision"])
        attempts.append(row)
        (args.output / f"trial-{trial + 1}.json").write_text(json.dumps(row))
        print(json.dumps({k: v for k, v in row.items() if k != "observations"}), flush=True)
        if not row.get("converged_ns"):
            break
    serving = distribution([(r["serving_ns"] - r["receipt_ns"]) / 1e6 for r in attempts if r.get("serving_ns")])
    convergence = distribution([(r["converged_ns"] - r["serving_ns"]) / 1e6 for r in attempts if r.get("converged_ns")])
    checks_passed = (len(attempts) == args.trials and all(r["correctness"] for r in attempts)
              and serving.get("p95_ms", float("inf")) <= limits["serving_p95_ms"]
              and convergence.get("p95_ms", float("inf")) <= limits["convergence_p95_ms"])
    sufficient = args.trials >= limits["minimum_trials"] and window_count in limits["window_counts"]
    passed = checks_passed and sufficient
    report = {"schema": "leyline/native-crash-recovery/v1", "binary_sha256": binary_hash,
              "source_commit": args.source_commit, "requested_trials": args.trials,
              "attempts": len(attempts), "serving": serving, "convergence": convergence,
              "checks_passed": checks_passed, "window_count": window_count, "ceilings": limits,
              "population_sufficient": sufficient, "full_product_certified": False,
              "passed": passed, "physical_evidence": False, "kickstart_count": 0,
              "receipt_boundary": "pre-SIGKILL conservative lower-bound; observed exit time not substituted",
              "serving_latency_is_sampled_upper_bound": True,
              "convergence_boundary": "independent snapshot observation; same probe uses the same timestamp"}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
