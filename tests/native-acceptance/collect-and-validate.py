#!/usr/bin/env python3
"""Read-only fixture IPC, independent pixel join and fail-closed acceptance gates.

Writes only explicitly selected result output. Never injects keys or changes apps.
@canonical native_acceptance_validation
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import socket
from pathlib import Path
import struct
import sys
import time
from typing import Any
import zlib

ROOT = Path(__file__).resolve().parent
SCENARIOS = ROOT / "scenarios.json"
SCENARIOS_SHA256 = "f5a7fbdb18e5b0c7cb2c6a744236e827a2caef2ef15bc040caae40e63dd12c0d"
IDENTITY_FIELDS = ("revision", "observer_generation", "input_generation", "observer_epoch",
                   "space_key", "topology_revision", "window_id", "pid", "lifetime")


class EvidenceError(ValueError):
    """Explicit missing, invalid or unsupported evidence; never a passing fallback."""


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    """Return nonempty object rows; malformed/empty input raises EvidenceError."""
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows or any(not isinstance(row, dict) for row in rows):
        raise EvidenceError("empty_or_nonobject_inventory")
    return rows


def integer(value: Any, name: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise EvidenceError("invalid_" + name)
    return value


def decode_png(path: Path) -> tuple[int, int, bytes]:
    """Decode bounded noninterlaced RGB/RGBA8 PNGs without external dependencies."""
    raw = path.read_bytes()
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise EvidenceError("invalid_png_signature")
    offset, payload, header = 8, bytearray(), None
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise EvidenceError("truncated_png_chunk")
        size = struct.unpack_from(">I", raw, offset)[0]
        kind = raw[offset + 4:offset + 8]
        data = raw[offset + 8:offset + 8 + size]
        if offset + size + 12 > len(raw):
            raise EvidenceError("truncated_png_chunk")
        crc = struct.unpack_from(">I", raw, offset + 8 + size)[0]
        if zlib.crc32(kind + data) & 0xffffffff != crc:
            raise EvidenceError("png_crc_mismatch")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT":
            payload.extend(data)
        elif kind == b"IEND":
            break
        offset += size + 12
    if header is None:
        raise EvidenceError("png_header_missing")
    width, height, depth, color, compression, filtering, interlace = header
    if depth != 8 or color not in (2, 6) or compression or filtering or interlace:
        raise EvidenceError("unsupported_png_encoding")
    if not (0 < width <= 16384 and 0 < height <= 16384 and width * height <= 40_000_000):
        raise EvidenceError("png_dimensions_exceed_budget")
    channels = 4 if color == 6 else 3
    stride = width * channels
    limit = (stride + 1) * height
    decompressor = zlib.decompressobj()
    decoded = decompressor.decompress(bytes(payload), limit + 1)
    if len(decoded) != limit or not decompressor.eof or decompressor.unconsumed_tail:
        raise EvidenceError("png_decompression_length_mismatch")
    result, previous = bytearray(), bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        filter_type = decoded[start]
        row = bytearray(decoded[start + 1:start + 1 + stride])
        if filter_type not in range(5):
            raise EvidenceError("unsupported_png_filter")
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                p = left + up - corner
                distances = (abs(p - left), abs(p - up), abs(p - corner))
                predictor = (left, up, corner)[distances.index(min(distances))]
            else:
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        if channels == 4:
            result.extend(row)
        else:
            for x in range(0, stride, 3):
                result.extend(row[x:x + 3]); result.append(255)
        previous = row
    return width, height, bytes(result)


class CaptureEvidence:
    """Read independent capture records; cache at most one decoded image."""
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.rows = read_jsonl(root / "capture-frames.jsonl")
        self.frames: dict[int, dict[str, Any]] = {}
        self.cache: tuple[int, tuple[int, int, bytes]] | None = None
        for row in self.rows:
            frame_id = integer(row.get("frame_id"), "frame_id")
            if frame_id in self.frames:
                raise EvidenceError("duplicate_frame_id")
            self.frames[frame_id] = row

    def frame(self, frame_id: int) -> tuple[dict[str, Any], tuple[int, int, bytes]]:
        row = self.frames.get(frame_id)
        if row is None:
            raise EvidenceError("capture_frame_missing")
        if row.get("provenance") != "screencapturekit_windowserver_composition":
            raise EvidenceError("capture_provenance_invalid")
        if row.get("gap_flags") != [] or row.get("status") != 0:
            raise EvidenceError("capture_frame_unobserved")
        if row.get("physical_scanout_proven") is not False:
            raise EvidenceError("physical_scanout_claim_unsupported")
        if not isinstance(row.get("refresh_hz"), (int, float)) or row["refresh_hz"] <= 0:
            raise EvidenceError("display_refresh_rate_unknown")
        ticks = integer(row.get("display_time_ticks"), "display_time_ticks", 1)
        ns = integer(row.get("display_time_ns"), "display_time_ns", 1)
        calibration = row.get("clock_calibration", {})
        numer = integer(calibration.get("numer"), "clock_numer", 1)
        denom = integer(calibration.get("denom"), "clock_denom", 1)
        if ticks * numer // denom != ns:
            raise EvidenceError("display_clock_conversion_mismatch")
        before = integer(calibration.get("uptime_before_ns"), "calibration_before", 1)
        after = integer(calibration.get("uptime_after_ns"), "calibration_after", 1)
        mach = integer(calibration.get("mach_ns"), "calibration_mach", 1)
        if not before <= mach <= after or after - before > 1_000_000:
            raise EvidenceError("display_clock_calibration_unbounded")
        if ns > integer(row.get("arrival_uptime_ns"), "capture_arrival", 1):
            raise EvidenceError("display_stamp_after_capture_arrival")
        name = row.get("frame_path")
        if not isinstance(name, str) or Path(name).name != name:
            raise EvidenceError("pixel_artifact_missing_or_unsafe")
        path = self.root / name
        if path.is_symlink() or path.resolve().parent != self.root:
            raise EvidenceError("pixel_artifact_outside_capture_root")
        if hashlib.sha256(path.read_bytes()).hexdigest() != row.get("pixels_sha256"):
            raise EvidenceError("pixel_hash_mismatch")
        if self.cache is None or self.cache[0] != frame_id:
            self.cache = frame_id, decode_png(path)
        return row, self.cache[1]

    def matches(self, frame_id: int, expectation: dict[str, Any]) -> bool:
        """Check specification-selected pixel probes in a declared display ROI."""
        row, (width, height, pixels) = self.frame(frame_id)
        capture_roi = row.get("roi_px")
        if not isinstance(capture_roi, list) or len(capture_roi) != 4 or capture_roi[2:] != [width, height]:
            raise EvidenceError("capture_roi_dimensions_mismatch")
        origin_x, origin_y = capture_roi[:2]
        roi = expectation.get("roi_px")
        if not isinstance(roi, list) or len(roi) != 4 or any(type(v) is not int for v in roi):
            raise EvidenceError("visual_roi_invalid")
        rx, ry, rw, rh = roi
        if rx < origin_x or ry < origin_y or rw <= 0 or rh <= 0 or rx + rw > origin_x + width or ry + rh > origin_y + height:
            raise EvidenceError("visual_roi_outside_frame")
        probes = expectation.get("probes")
        if not isinstance(probes, list) or len(probes) < 4:
            raise EvidenceError("visual_probes_insufficient")
        coordinates = set()
        for probe in probes:
            x, y = integer(probe.get("x"), "probe_x"), integer(probe.get("y"), "probe_y")
            if not rx <= x < rx + rw or not ry <= y < ry + rh:
                raise EvidenceError("visual_probe_outside_roi")
            coordinates.add((x, y))
            expected, tolerance = probe.get("rgba"), integer(probe.get("tolerance", 0), "pixel_tolerance")
            if tolerance > 16 or not isinstance(expected, list) or len(expected) != 4 or any(type(v) is not int or not 0 <= v <= 255 for v in expected):
                raise EvidenceError("visual_probe_color_invalid")
            offset = ((y - origin_y) * width + x - origin_x) * 4
            if any(abs(pixels[offset + c] - expected[c]) > tolerance for c in range(4)):
                return False
        if len(coordinates) < 4:
            raise EvidenceError("visual_probes_not_distinct")
        return True

    def first_match(self, receipt: int, expectation: dict[str, Any]) -> dict[str, Any]:
        for row in self.rows:
            if row.get("display_time_ns", 0) >= receipt and row.get("frame_path"):
                if self.matches(row["frame_id"], expectation):
                    return row
        raise EvidenceError("visible_endpoint_unobserved")


def load_admissions(path: Path) -> dict[str, dict[str, Any]]:
    admissions = {}
    for row in read_jsonl(path):
        sample_id = row.get("sample_id")
        if not isinstance(sample_id, str) or not sample_id or sample_id in admissions:
            raise EvidenceError("admission_identity_duplicate_or_missing")
        admissions[sample_id] = row
    return admissions


def validate_sample(sample: dict[str, Any], admission: dict[str, Any], budget: dict[str, Any],
                    capture: CaptureEvidence | None, binary_hash: str,
                    endpoint_provenance: dict[str, list[str]] | None = None) -> float:
    """Validate one source-correlated sample with causal partial order, return ms."""
    for field in ("sample_id", "request_id", "scenario_id", "origin", "binary_sha256"):
        if not isinstance(sample.get(field), str) or not sample[field]:
            raise EvidenceError("sample_metadata_missing_" + field)
    for field in ("sample_id", "request_id", "scenario_id", "origin", "window_count", "binary_sha256"):
        if sample.get(field) != admission.get(field):
            raise EvidenceError("admission_metadata_mismatch_" + field)
    if sample.get("binary_sha256") != binary_hash:
        raise EvidenceError("binary_hash_mismatch")
    if sample.get("origin") in ("injected", "synthetic") or sample.get("synthetic") is not False:
        raise EvidenceError("synthetic_not_live_evidence")
    if sample.get("status") != admission.get("status"):
        raise EvidenceError("admission_status_mismatch")
    if sample.get("status") not in ("accepted", "noop") or sample.get("correctness") is not True:
        raise EvidenceError("sample_refused_failed_or_incorrect")
    if sample.get("adapter_gaps"):
        raise EvidenceError("source_adapter_has_unresolved_gaps")
    if sample.get("retry_of") != admission.get("retry_of"):
        raise EvidenceError("retry_identity_mismatch")
    expected = admission.get("captured_admission")
    actual = sample.get("admission")
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        raise EvidenceError("captured_admission_missing")
    for field in IDENTITY_FIELDS:
        if field not in expected or field not in actual or actual[field] != expected[field]:
            raise EvidenceError("stale_admission_" + field)
    for field in ("revision", "observer_generation", "topology_revision"):
        integer(expected[field], field)
    if not expected["observer_epoch"] or not expected["space_key"]:
        raise EvidenceError("admission_context_missing")
    stamps = sample.get("stamps", {})
    source_stamps = admission.get("stamps", {})
    if not isinstance(stamps, dict) or not isinstance(source_stamps, dict) or any(not isinstance(stamp, dict) for stamp in stamps.values()):
        raise EvidenceError("endpoint_records_invalid")
    for endpoint, stamp in stamps.items():
        integer(stamp.get("nanos"), "endpoint_" + endpoint, 1)
        if not stamp.get("provenance"):
            raise EvidenceError("endpoint_provenance_missing_" + endpoint)
        if endpoint_provenance is not None and stamp.get("provenance") not in endpoint_provenance.get(endpoint, []):
            raise EvidenceError("endpoint_provenance_invalid_" + endpoint)
        if endpoint != "physically_visible" and stamp != source_stamps.get(endpoint):
            raise EvidenceError("endpoint_not_source_correlated_" + endpoint)
    # Visible and verified are siblings after effect issue. Neither must follow the other.
    pairs = [("receipt", "intent_resolved"), ("receipt", "plan_committed"),
             ("receipt", "render_submitted"), ("receipt", "effect_issued"),
             ("effect_issued", "verified"), ("effect_issued", "physically_visible"),
             ("receipt", "verified"), ("receipt", "physically_visible"),
             ("serving", "verified")]
    for first, last in pairs:
        if first in stamps and last in stamps and stamps[first]["nanos"] > stamps[last]["nanos"]:
            raise EvidenceError("noncausal_endpoints_" + first + "_" + last)
    for endpoint in (budget["start"], budget["end"]):
        if endpoint not in stamps:
            raise EvidenceError("missing_endpoint_" + endpoint)
    if budget["visible_required"]:
        if capture is None:
            raise EvidenceError("capture_evidence_missing")
        visible = stamps.get("physically_visible", {})
        if visible.get("provenance") != "independent_windowserver_composition":
            raise EvidenceError("visible_provenance_invalid")
        expectation = sample.get("visual_expectation", {})
        receipt = stamps["receipt"]["nanos"]
        baseline = integer(sample.get("baseline_frame_id"), "baseline_frame_id")
        baseline_row, _ = capture.frame(baseline)
        if baseline_row["display_time_ns"] >= receipt or capture.matches(baseline, expectation):
            raise EvidenceError("visible_change_baseline_invalid")
        first = capture.first_match(receipt, expectation)
        if visible.get("frame_id") != first["frame_id"] or visible.get("nanos") != first["display_time_ns"]:
            raise EvidenceError("visible_stamp_not_first_independent_matching_frame")
    counters = sample.get("counters", {})
    if "maximum_ax_writes" in budget and counters.get("ax_writes") != 0:
        raise EvidenceError("noop_ax_write_or_missing_counter")
    start, end = stamps[budget["start"]]["nanos"], stamps[budget["end"]]["nanos"]
    if budget["id"] == "held_resize_final":
        if "key_up" not in stamps:
            raise EvidenceError("key_up_missing")
        start = stamps["key_up"]["nanos"]
        end = max(stamps["verified"]["nanos"], stamps["physically_visible"]["nanos"])
        if counters.get("maximum_pending_desired") is None or counters["maximum_pending_desired"] > 1:
            raise EvidenceError("held_pending_desired_bound_missing_or_exceeded")
        duration = integer(sample.get("held_duration_ns"), "held_duration_ns", 1)
        updates = sample.get("held_visible_updates", [])
        geometry, observed_pixels, last_stamp = set(), set(), 0
        for update in updates:
            row, _ = capture.frame(integer(update.get("frame_id"), "held_frame_id"))  # type: ignore[union-attr]
            if row["display_time_ns"] <= last_stamp or not stamps["receipt"]["nanos"] <= row["display_time_ns"] <= start:
                raise EvidenceError("held_updates_not_causal")
            if not capture.matches(row["frame_id"], update.get("visual_expectation", {})):  # type: ignore[union-attr]
                raise EvidenceError("held_geometry_not_observed")
            key = update.get("geometry_key")
            expectation = update.get("visual_expectation", {})
            observed_key = json.dumps({"roi_px": expectation.get("roi_px"), "probes": expectation.get("probes")}, sort_keys=True)
            if not key or key in geometry or observed_key in observed_pixels:
                raise EvidenceError("held_duplicate_geometry")
            geometry.add(key); observed_pixels.add(observed_key); last_stamp = row["display_time_ns"]
        if len(geometry) / (duration / 1e9) < 10:
            raise EvidenceError("held_visible_rate_below_10hz")
        if duration != start - stamps["receipt"]["nanos"]:
            raise EvidenceError("held_duration_mismatch")
    if end < start and budget["id"] == "held_resize_final":
        # Already-landed final state satisfies the key-up ceiling; retain actual earlier stamps.
        return 0.0
    if end < start:
        raise EvidenceError("endpoint_interval_negative")
    return (end - start) / 1e6


def percentile(values: list[float], percentile_value: int) -> float:
    return sorted(values)[max(0, math.ceil(len(values) * percentile_value / 100) - 1)]


def validate(samples: list[dict[str, Any]], admissions: dict[str, dict[str, Any]],
             scenarios: dict[str, Any], capture: CaptureEvidence | None,
             binary_hash: str, full: bool) -> dict[str, Any]:
    """Retain all admitted attempts; fail missing populations and ceiling misses."""
    frozen = hashlib.sha256(json.dumps(scenarios, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if frozen != SCENARIOS_SHA256:
        raise EvidenceError("frozen_scenario_thresholds_or_inventory_changed")
    budgets = {row["id"]: row for row in scenarios["budgets"]}
    seen, seen_requests, errors, groups, counts = set(), set(), [], {}, {}
    for sample in samples:
        sid = sample.get("sample_id")
        if not isinstance(sid, str) or sid in seen:
            errors.append({"sample_id": sid, "code": "duplicate_or_missing_sample_id"}); continue
        seen.add(sid)
        if any(not isinstance(sample.get(field), str) or not sample[field] for field in ("scenario_id", "origin", "request_id", "binary_sha256")):
            errors.append({"sample_id": sid, "code": "sample_metadata_missing"}); continue
        if type(sample.get("window_count")) is not int or not isinstance(sample.get("admission"), dict):
            errors.append({"sample_id": sid, "code": "sample_context_invalid"}); continue
        admission = admissions.get(sid)
        budget = budgets.get(sample.get("scenario_id"))
        if admission is None or budget is None:
            errors.append({"sample_id": sid, "code": "admission_or_scenario_missing"}); continue
        request_key = (sample.get("binary_sha256"), sample.get("admission", {}).get("observer_epoch"), sample.get("request_id"), sample.get("scenario_id"))
        if request_key in seen_requests:
            errors.append({"sample_id": sid, "code": "duplicate_request_cannot_inflate_population"}); continue
        seen_requests.add(request_key)
        group = (budget["id"], sample.get("window_count"), sample.get("origin"))
        counts[group] = counts.get(group, 0) + 1
        try:
            if sample.get("window_count") not in scenarios["window_counts"]:
                raise EvidenceError("scene_window_count_invalid")
            elapsed = validate_sample(sample, admission, budget, capture, binary_hash, scenarios["endpoint_provenance"])
            groups.setdefault(group, []).append(elapsed)
        except (EvidenceError, KeyError, TypeError, OSError, ValueError) as error:
            errors.append({"sample_id": sid, "code": str(error)})
    for sid in admissions.keys() - seen:
        errors.append({"sample_id": sid, "code": "admitted_attempt_missing_from_samples"})
    required = [(key, count, budget["required_origin"]) for key, budget in budgets.items()
                for count in scenarios["window_counts"]] if full else list(counts)
    summaries = []
    for key, count, origin in sorted(set(required), key=str):
        budget = budgets[key]; group = (key, count, origin); values = groups.get(group, [])
        row = {"scenario_id": key, "window_count": count, "origin": origin,
               "attempt_count": counts.get(group, 0), "valid_count": len(values),
               "required_count": budget["minimum_samples"], "hardware_path_proven": origin == "hid"}
        if len(values) < budget["minimum_samples"]:
            errors.append({"group": list(group), "code": "insufficient_scenario_samples"})
        if values:
            for p in (50, 95, 99):
                row[f"p{p}_ms"] = percentile(values, p)
            row["max_ms"] = max(values)
            for field in ("p50_ms", "p95_ms", "p99_ms", "max_ms"):
                if field in budget and (row[field] >= budget[field] if budget.get("strict_less") else row[field] > budget[field]):
                    errors.append({"group": list(group), "code": "absolute_ceiling_missed", "endpoint": field})
        if origin != budget["required_origin"]:
            errors.append({"group": list(group), "code": "origin_not_acceptance_path"})
        summaries.append(row)
    if not samples:
        errors.append({"code": "empty_evidence_inventory"})
    return {"schema": "leyline/native-acceptance-report/v1", "passed": not errors,
            "full_corpus_requested": full, "physical_scanout_proven": False,
            "admission_count": len(admissions), "attempt_count": len(samples),
            "binary_sha256": binary_hash, "groups": summaries, "errors": errors}


def resident_request(path: Path, body: dict[str, Any], timeout: float) -> dict[str, Any]:
    """Read-only length-framed RPC with a single bounded deadline and no retry."""
    if body.get("op") not in ("hello", "trace", "snapshot"):
        raise EvidenceError("collector_operation_is_not_read_only")
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(timeout); peer.connect(str(path))
        encoded = json.dumps(body, separators=(",", ":")).encode()
        peer.sendall(struct.pack(">I", len(encoded)) + encoded)
        def receive(size: int) -> bytes:
            output = bytearray()
            while len(output) < size:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise EvidenceError("trace_rpc_deadline_exceeded")
                peer.settimeout(remaining)
                data = peer.recv(size - len(output))
                if not data:
                    raise EvidenceError("trace_rpc_eof")
                output.extend(data)
            return bytes(output)
        size = struct.unpack(">I", receive(4))[0]
        # Match the resident framing bound; a128-row20-window page can exceed1MiB.
        if not 0 < size < 64 * 1024 * 1024:
            raise EvidenceError("trace_rpc_payload_exceeds_bound")
        result = json.loads(receive(size))
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise EvidenceError("trace_rpc_refused_or_malformed")
        return result


def trace_recording_drops(page: dict[str, Any]) -> int:
    """Separate counted ring overwrites from nonblocking recording loss."""
    total = integer(page.get("dropped_events"), "trace_dropped_events")
    oldest = page.get("oldest_sequence")
    overwritten = integer(oldest, "trace_oldest_sequence", 1) - 1 if oldest is not None else 0
    if total < overwritten:
        raise EvidenceError("trace_drop_accounting_invalid")
    return total - overwritten


def trace_page_events(page: dict[str, Any], cursor: int, pid: int,
                      baseline_drops: int) -> tuple[list[dict[str, Any]], int]:
    """Validate actual exporter pagination, PID and loss indicators."""
    if page.get("schema") != "leyline/native-performance-trace/v1" or page.get("pid") != pid:
        raise EvidenceError("trace_schema_or_process_epoch_changed")
    drops = trace_recording_drops(page)
    if drops != baseline_drops:
        raise EvidenceError("trace_drop_counter_changed")
    last = integer(page.get("last_sequence"), "trace_last_sequence")
    if last < cursor:
        raise EvidenceError("trace_sequence_regressed")
    rows = page.get("events")
    if not isinstance(rows, list) or len(rows) > 128:
        raise EvidenceError("trace_page_bound_exceeded")
    for row in rows:
        if not isinstance(row, dict) or integer(row.get("sequence"), "trace_sequence", 1) != cursor + 1:
            raise EvidenceError("trace_sequence_gap")
        if row.get("provenance") != "resident_monotonic_observation" or not isinstance(row.get("kind"), str):
            raise EvidenceError("trace_event_provenance_invalid")
        integer(row.get("uptime_ns"), "trace_uptime", 1)
        cursor += 1
    if not rows and last > cursor:
        raise EvidenceError("trace_page_missing_available_events")
    return rows, cursor


def run_collector(path: Path, binary: Path, output: Path, seconds: float,
                  timeout: float, from_sequence: int | None) -> dict[str, Any]:
    """Persist real trace pages plus independently read scene, without UI actuation."""
    if not 0 < seconds <= 3600 or not 0 < timeout <= 5 or output.exists():
        raise EvidenceError("collector_bounds_or_output_invalid")
    output.mkdir(mode=0o700)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    started = time.monotonic_ns()
    metadata: dict[str, Any] = {"schema": "leyline/native-trace-collection/v1", "binary_sha256": binary_hash,
        "started_uptime_ns": started, "passed": False, "errors": [], "hardware_origin_verified": False,
        "source": "live_framed_socket", "socket": str(path), "from_sequence_requested": from_sequence}
    metadata["measurement_certified"] = False
    metadata["collector_clock"] = "python_time_monotonic_ns"
    cursor, event_count = 0, 0
    try:
        hello = resident_request(path, {"op": "hello"}, timeout)
        snapshot = resident_request(path, {"op": "snapshot"}, timeout)
        # Scene comes from the actual world response. Never infer total count from fixture windows.
        world = snapshot.get("world", {})
        windows = world.get("windows")
        if world.get("world_complete") is not True and world.get("complete") is not True and world.get("observation", {}).get("world_complete") is not True:
            raise EvidenceError("collector_scene_incomplete")
        if not isinstance(windows, list):
            raise EvidenceError("collector_scene_windows_missing")
        managed = [window for window in windows if window.get("eligible") is True
                   and window.get("space_visible") is True and window.get("space_enabled") is True
                   and window.get("minimized") is not True]
        (output / "scene-snapshot.json").write_text(json.dumps(snapshot, sort_keys=True) + "\n")
        metadata.update({"pid": hello["pid"], "epoch_ms": hello["epoch_ms"],
                         "observed_window_count": len(windows), "managed_window_count": len(managed),
                         "scene_revision": snapshot["revision"], "managed_window_ids": [w["window_id"] for w in managed]})
        page = resident_request(path, {"op": "trace", "args": {"from_sequence": 0, "limit": 128}}, timeout)
        total_drops = integer(page.get("dropped_events"), "trace_dropped_events")
        drops = trace_recording_drops(page)
        cursor = integer(page.get("last_sequence"), "trace_last_sequence") if from_sequence is None else from_sequence
        metadata.update({"start_sequence": cursor, "initial_dropped_events": total_drops,
                         "initial_recording_drops": drops,
                         "excluded_prior_events": from_sequence is None,
                         "exclusion_reason": "explicit_collection_window_starts_at_current_tail" if from_sequence is None else None})
        with (output / "trace-pages.jsonl").open("x") as pages, (output / "trace-events.jsonl").open("x") as events:
            deadline = time.monotonic() + seconds
            first = True
            while first or time.monotonic() < deadline:
                first = False
                page_started = time.monotonic_ns()
                page = resident_request(path, {"op": "trace", "args": {"from_sequence": cursor, "limit": 128}}, timeout)
                pages.write(json.dumps({"collector_before_ns": page_started, "collector_after_ns": time.monotonic_ns(),
                                        "from_sequence": cursor, "response": page}, sort_keys=True) + "\n"); pages.flush()
                rows, cursor = trace_page_events(page, cursor, hello["pid"], drops)
                for row in rows:
                    events.write(json.dumps(row, sort_keys=True) + "\n"); event_count += 1
                events.flush()
                if cursor >= page["last_sequence"]:
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        if hashlib.sha256(binary.read_bytes()).hexdigest() != binary_hash:
            raise EvidenceError("collector_binary_changed_during_run")
        metadata["passed"] = True
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        metadata["errors"].append(str(error))
    metadata.update({"ended_uptime_ns": time.monotonic_ns(), "last_collected_sequence": cursor, "event_count": event_count})
    metadata["artifact_sha256"] = {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
        for name in ("trace-pages.jsonl", "trace-events.jsonl", "scene-snapshot.json") if (output / name).is_file()}
    (output / "collection.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def infer_scenario(action: str) -> str:
    if action.startswith("resize.adjust."):
        return "move_resize"
    if action.startswith("nav.focus."):
        return "navigation"
    if action in ("move.commit", "move.confirm"):
        return "edge_commit_visible"
    if action.startswith("move.") and action not in ("move.start", "move.off", "move.cancel"):
        return "stage_feedback"
    if action in ("move.start", "resize.start", "resize.off", "move.off", "move.cancel", "mode.cancel"):
        return "border_submission"
    return "unmapped_action"


def adapt_trace(run_root: Path, output: Path, expectations_path: Path | None,
                capture_root: Path | None, hardware_path: Path | None = None) -> dict[str, Any]:
    """Derive ledger from real admissions, preserving missing endpoints/refusals."""
    if output.exists():
        raise EvidenceError("adapter_output_exists")
    output.mkdir(mode=0o700)
    collection = json.loads((run_root / "collection.json").read_text())
    if collection.get("schema") != "leyline/native-trace-collection/v1" or collection.get("source") != "live_framed_socket" or collection.get("passed") is not True:
        raise EvidenceError("collector_loss_or_failure_blocks_adaptation")
    for name in ("trace-pages.jsonl", "trace-events.jsonl", "scene-snapshot.json"):
        if hashlib.sha256((run_root / name).read_bytes()).hexdigest() != collection.get("artifact_sha256", {}).get(name):
            raise EvidenceError("collected_source_artifact_missing_or_changed_" + name)
    events = read_jsonl(run_root / "trace-events.jsonl")
    expectations = read_jsonl(expectations_path) if expectations_path else []
    hardware = read_jsonl(hardware_path) if hardware_path else []
    hardware_by_sequence = {}
    for row in hardware:
        sequence = integer(row.get("tap_sequence"), "hardware_tap_sequence", 1)
        if sequence in hardware_by_sequence or row.get("method") not in ("operator_physical_keyboard", "instrumented_hid_device"):
            raise EvidenceError("hardware_attestation_duplicate_or_unsupported")
        evidence = Path(row.get("evidence_path", ""))
        if not evidence.is_file() or hashlib.sha256(evidence.read_bytes()).hexdigest() != row.get("evidence_sha256"):
            raise EvidenceError("hardware_attestation_artifact_missing_or_changed")
        hardware_by_sequence[sequence] = row
    by_request: dict[str, list[dict[str, Any]]] = {}
    for event in events:
        request = event.get("request_id")
        if isinstance(request, str):
            by_request.setdefault(request, []).append(event)
    expectation_by_request = {}
    for expectation in expectations:
        request = expectation.get("request_id")
        if not isinstance(request, str) or request in expectation_by_request:
            raise EvidenceError("expectation_request_duplicate_or_missing")
        expectation_by_request[request] = expectation
    capture = CaptureEvidence(capture_root) if capture_root else None
    admissions, samples, diagnostics = [], [], []
    for request, request_events in by_request.items():
        source = next((row for row in request_events if row["kind"] == "admission"), None)
        if source is None:
            diagnostics.append({"request_id": request, "code": "request_has_no_captured_admission", "events": request_events})
            continue
        terminals = [row for row in request_events if row["kind"] in ("completion", "refusal")]
        terminal = terminals[-1] if terminals else {}
        plan = next((row for row in request_events if row["kind"] == "intent_resolved"), {})
        issue = next((row for row in request_events if row["kind"] == "effect_issued"), {})
        verified = next((row for row in request_events if row["kind"] == "verified"), {})
        expectation = expectation_by_request.get(request, {})
        action = source.get("action_id", "")
        scenario = expectation.get("scenario_id", infer_scenario(action))
        origin = "cg_session_tap" if source.get("origin") == "input" else source.get("origin", "unknown")
        identity = {"revision": source.get("revision"), "observer_generation": source.get("observer_generation"),
            "input_generation": source.get("source_input_generation"), "observer_epoch": source.get("observer_epoch"),
            "space_key": source.get("space_key"), "topology_revision": source.get("topology_revision"),
            "window_id": source.get("window_id"), "pid": source.get("pid"), "lifetime": source.get("window_generation")}
        receipt = integer(source.get("source_receipt_uptime_ns", source.get("uptime_ns")), "source_receipt", 1)
        receipt_provenance = {"cg_session_tap": "resident_input_callback", "socket": "resident_socket_admission", "menu": "resident_menu_admission"}.get(origin, "resident_controller_admission")
        stamps = {"receipt": {"nanos": receipt, "provenance": receipt_provenance}}
        for row, endpoint, provenance in ((plan, "intent_resolved", "resident_input_resolution"),
            (issue, "effect_issued", "resident_ax_issue"), (verified, "verified", "resident_scoped_ax_readback")):
            if row:
                stamps[endpoint] = {"nanos": row["uptime_ns"], "provenance": provenance}
        commits = [row for row in request_events if row["kind"] == "plan_committed"]
        if len(commits) == 1:
            stamp_provenance = "resident_authority_publication_return" if commits[0].get("boundary") == "authoritative_publication_return" else "resident_authority_commit"
            stamps["plan_committed"] = {"nanos": commits[0]["uptime_ns"], "provenance": stamp_provenance}
        # Render binds immutable candidate+revision; no nearest-time or current-health substitution.
        revision = terminal.get("desired_state_committed_revision") or issue.get("revision") or (commits[0].get("revision") if len(commits) == 1 else None)
        candidate = commits[0].get("candidate_id") if len(commits) == 1 else plan.get("candidate_id")
        renders = [row for row in events if row["kind"] == "render_submitted"
                   and revision is not None and row.get("revision") == revision
                   and row.get("candidate_id") == candidate]
        if len(renders) == 1:
            stamps["render_submitted"] = {"nanos": renders[0]["uptime_ns"], "provenance": "resident_appkit_submission"}
        tap = [row for row in events if row["kind"] == "tap_receipt" and row.get("uptime_ns") == receipt and row.get("action_id") == action]
        attestation = hardware_by_sequence.get(tap[0]["sequence"]) if len(tap) == 1 else None
        if attestation:
            if attestation.get("binary_sha256") != collection["binary_sha256"] or attestation.get("epoch_ms") != collection["epoch_ms"]:
                raise EvidenceError("hardware_attestation_binary_or_epoch_mismatch")
            for field in ("action_id", "input_generation", "cg_event_timestamp_ns"):
                if attestation.get(field) != tap[0].get(field):
                    raise EvidenceError("hardware_attestation_does_not_match_captured_tap_" + field)
            if origin != "cg_session_tap":
                raise EvidenceError("hardware_attestation_not_for_captured_input")
            origin = "hid"
        key_ups = [row for row in events if row["kind"] == "key_up" and row.get("action_id") == action
                   and row.get("input_generation") == source.get("source_input_generation") and row["uptime_ns"] >= receipt]
        if key_ups:
            stamps["key_up"] = {"nanos": key_ups[0]["uptime_ns"], "provenance": "resident_input_callback"}
        sample_id = f"{collection['epoch_ms']}:{request}:{scenario}"
        source_identity = {"sample_id": sample_id, "request_id": request, "scenario_id": scenario, "origin": origin,
            "window_count": collection["managed_window_count"], "binary_sha256": collection["binary_sha256"],
            "status": terminal.get("status", "unfinished"), "retry_of": expectation.get("retry_of"),
            "captured_admission": identity, "stamps": stamps.copy(), "source_events": request_events,
            "tap_events": tap, "key_up_events": key_ups[:1], "render_events": renders,
            "scene_snapshot": "scene-snapshot.json", "hardware_origin_verified": bool(attestation),
            "hardware_attestation": attestation}
        sample = {k: v for k, v in source_identity.items() if k not in ("captured_admission", "source_events", "tap_events", "render_events", "key_up_events")}
        sample.update({"admission": identity.copy(), "stamps": stamps.copy(), "synthetic": False,
                       "correctness": False, "reason": terminal.get("reason"), "adapter_gaps": []})
        if not terminals:
            sample["adapter_gaps"].append("terminal_not_captured")
        if len(terminals) > 1:
            sample["adapter_gaps"].append("multiple_terminal_records")
        if origin == "cg_session_tap" and len(tap) != 1:
            sample["adapter_gaps"].append("original_tap_receipt_not_uniquely_captured")
        targets = issue.get("target_frames") or {wid: row.get("frame") for wid, row in plan.get("targets", {}).items() if row.get("presented") is not False}
        requested = terminal.get("requested_frames")
        landed = terminal.get("landed_frames")
        # Frame correctness requires actual exact requested/landed evidence, not accepted status alone.
        if verified and targets and targets == requested == landed and terminal.get("status") == "accepted":
            sample["correctness"] = True
        elif verified and terminal.get("focus_confirmed") is True and scenario == "navigation":
            sample["correctness"] = True
        if expectation:
            if expectation.get("candidate_id") != candidate or expectation.get("target_frames") != targets:
                sample["adapter_gaps"].append("immutable_candidate_or_geometry_expectation_mismatch")
            else:
                sample["visual_expectation"] = expectation.get("visual_expectation")
                sample["baseline_frame_id"] = expectation.get("baseline_frame_id")
                if capture and sample.get("visual_expectation"):
                    try:
                        visible = capture.first_match(receipt, sample["visual_expectation"])
                        sample["stamps"]["physically_visible"] = {"nanos": visible["display_time_ns"], "frame_id": visible["frame_id"],
                                                                 "provenance": "independent_windowserver_composition"}
                        if scenario in ("border_submission", "border_visible", "stage_feedback") and len(renders) == 1 and terminal.get("status") == "accepted":
                            sample["correctness"] = True
                    except (EvidenceError, OSError, ValueError, TypeError) as error:
                        sample["adapter_gaps"].append(str(error))
        admissions.append(source_identity); samples.append(sample)
    for name, rows in (("admissions.jsonl", admissions), ("samples.jsonl", samples), ("unmatched-events.jsonl", diagnostics)):
        with (output / name).open("x") as file:
            for row in rows:
                file.write(json.dumps(row, sort_keys=True) + "\n")
    result = {"schema": "leyline/native-trace-adapter/v1", "admission_count": len(admissions),
        "sample_count": len(samples), "unmatched_request_count": len(diagnostics), "measurement_certified": False,
        "source_collection": str(run_root), "hardware_origin_verified": False,
        "hardware_attested_sample_count": sum(sample.get("hardware_origin_verified") is True for sample in samples),
        "gaps": ["hardware_origin_requires_independent_attestation", "unsupported_paths_keep_missing_endpoints"]}
    (output / "adapter.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    query = commands.add_parser("fixture-status", help="Read atomic fixture filesystem IPC; no UI actions")
    query.add_argument("--capture-root", type=Path, required=True)
    collector = commands.add_parser("run-collector", help="Read-only live framed trace exporter; no UI actuation")
    collector.add_argument("--socket", type=Path, required=True)
    collector.add_argument("--binary", type=Path, required=True)
    collector.add_argument("--output", type=Path, required=True)
    collector.add_argument("--seconds", type=float, default=30)
    collector.add_argument("--timeout", type=float, default=2)
    collector.add_argument("--from-sequence", type=int)
    adapter = commands.add_parser("adapt-trace", help="Join actual raw trace admissions with immutable pixel expectations")
    adapter.add_argument("--run-root", type=Path, required=True)
    adapter.add_argument("--output", type=Path, required=True)
    adapter.add_argument("--expectations", type=Path)
    adapter.add_argument("--capture-root", type=Path)
    adapter.add_argument("--hardware-attestations", type=Path)
    for command in ("assemble", "validate"):
        p = commands.add_parser(command)
        p.add_argument("--samples", type=Path, required=True)
        p.add_argument("--admissions", type=Path, required=True)
        p.add_argument("--capture-root", type=Path)
        p.add_argument("--binary", type=Path, required=True)
        p.add_argument("--output", type=Path, required=True)
        p.add_argument("--full", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "run-collector":
            report = run_collector(args.socket, args.binary, args.output, args.seconds, args.timeout, args.from_sequence)
            print(json.dumps(report, sort_keys=True)); return 0 if report["passed"] else 1
        if args.command == "adapt-trace":
            report = adapt_trace(args.run_root, args.output, args.expectations, args.capture_root, args.hardware_attestations)
            print(json.dumps(report, sort_keys=True)); return 0
        if args.command == "fixture-status":
            result = {"window_manifest": json.loads((args.capture_root / "window-manifest.json").read_text()),
                      "capture_status": json.loads((args.capture_root / "capture-status.json").read_text())}
            print(json.dumps(result, sort_keys=True)); return 0
        samples = read_jsonl(args.samples); admissions = load_admissions(args.admissions)
        capture = CaptureEvidence(args.capture_root) if args.capture_root else None
        binary_hash = hashlib.sha256(args.binary.read_bytes()).hexdigest()
        if args.output.exists():
            raise EvidenceError("output_already_exists")
        if args.command == "assemble":
            if capture is None:
                raise EvidenceError("capture_required_for_assembly")
            for sample in samples:
                expectation = sample.get("visual_expectation")
                if not expectation:
                    continue
                receipt = sample["stamps"]["receipt"]["nanos"]
                frame = capture.first_match(receipt, expectation)
                sample["stamps"]["physically_visible"] = {"nanos": frame["display_time_ns"],
                    "provenance": "independent_windowserver_composition", "frame_id": frame["frame_id"]}
            with args.output.open("x") as output:
                for sample in samples:
                    output.write(json.dumps(sample, sort_keys=True) + "\n")
            return 0
        report = validate(samples, admissions, json.loads(SCENARIOS.read_text()), capture, binary_hash, args.full)
        with args.output.open("x") as output:
            json.dump(report, output, indent=2); output.write("\n")
        print(json.dumps(report, sort_keys=True)); return 0 if report["passed"] else 1
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"data": None, "error": {"code": "EVIDENCE.INVALID", "message": str(error)}}), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
