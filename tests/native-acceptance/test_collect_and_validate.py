"""Boundary mutation controls. All artifacts here are synthetic test fixtures."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import socket
from pathlib import Path
import struct
import tempfile
import threading
import unittest
import zlib

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("acceptance", ROOT / "collect-and-validate.py")
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


def fixture_png(channel: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    row = bytes([0]) + bytes([channel, channel, channel, 255]) * 2
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * 2)) + chunk(b"IEND", b""))


class AcceptanceBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = tempfile.TemporaryDirectory(prefix="leyline-native-validator-")
        self.root = Path(self.work.name)
        self.sample = json.loads((ROOT / "fixtures/admission-and-sample.json").read_text())["sample"]
        self.admission = copy.deepcopy(self.sample)
        self.admission["captured_admission"] = self.admission.pop("admission")
        self.admission["stamps"].pop("physically_visible")
        self.scenarios = json.loads((ROOT / "scenarios.json").read_text())
        self.budget = next(b for b in self.scenarios["budgets"] if b["id"] == "move_resize")
        frames = []
        for frame_id, (stamp, channel) in enumerate(((999000000, 255), (1020000000, 0))):
            name = f"fixture-frame-{frame_id}.png"
            data = fixture_png(channel); (self.root / name).write_bytes(data)
            frames.append({"schema": "leyline/native-capture-frame/v1", "frame_id": frame_id,
                "display_id": 1, "display_time_ticks": stamp, "display_time_ns": stamp,
                "arrival_uptime_ns": stamp + 1_000_000,
                "clock_calibration": {"numer": 1, "denom": 1, "mach_ns": stamp + 500_000,
                    "uptime_before_ns": stamp + 499_999, "uptime_after_ns": stamp + 500_001},
                "status": 0, "refresh_hz": 60, "physical_scanout_proven": False,
                "gap_flags": [], "provenance": "screencapturekit_windowserver_composition",
                "roi_px": [0, 0, 2, 2], "frame_path": name,
                "pixels_sha256": hashlib.sha256(data).hexdigest()})
        self.frames = frames; self.write_frames()

    def tearDown(self) -> None:
        self.work.cleanup()

    def write_frames(self) -> None:
        (self.root / "capture-frames.jsonl").write_text("".join(json.dumps(r) + "\n" for r in self.frames))
        self.capture = acceptance.CaptureEvidence(self.root)

    def check_sample(self) -> float:
        return acceptance.validate_sample(self.sample, self.admission, self.budget, self.capture, "a" * 64)

    def rejected(self, code: str) -> None:
        with self.assertRaisesRegex(acceptance.EvidenceError, code):
            self.check_sample()

    def test_verified_before_compositor_is_valid_partial_order(self) -> None:
        self.assertEqual(self.check_sample(), 20)

    def test_each_sample_uses_its_own_captured_revision(self) -> None:
        self.sample["admission"]["revision"] = 42
        self.admission["captured_admission"]["revision"] = 42
        self.assertEqual(self.check_sample(), 20)

    def test_stale_lifetime_is_rejected(self) -> None:
        self.sample["admission"]["lifetime"] += 1; self.rejected("stale_admission_lifetime")

    def test_stale_revision_is_rejected(self) -> None:
        self.sample["admission"]["revision"] += 1; self.rejected("stale_admission_revision")

    def test_endpoint_substitution_is_rejected(self) -> None:
        self.sample["stamps"]["physically_visible"]["nanos"] = self.sample["stamps"]["verified"]["nanos"]
        self.rejected("visible_stamp_not_first")

    def test_appkit_submission_cannot_be_visible_provenance(self) -> None:
        self.sample["stamps"]["physically_visible"]["provenance"] = "appkit_submission"
        self.rejected("visible_provenance_invalid")

    def test_already_matching_baseline_cannot_prove_changed_frame(self) -> None:
        self.frames[0]["frame_path"] = self.frames[1]["frame_path"]
        self.frames[0]["pixels_sha256"] = self.frames[1]["pixels_sha256"]
        self.write_frames(); self.rejected("visible_change_baseline_invalid")

    def test_altered_pixel_artifact_hash_is_rejected(self) -> None:
        (self.root / self.frames[1]["frame_path"]).write_bytes(fixture_png(255))
        self.rejected("pixel_hash_mismatch")

    def test_capture_gaps_cannot_certify_pixels(self) -> None:
        self.frames[1]["gap_flags"] = ["pixel_artifact_write_failed"]
        self.write_frames(); self.rejected("capture_frame_unobserved")

    def test_unknown_refresh_rate_is_rejected(self) -> None:
        self.frames[1]["refresh_hz"] = 0
        self.write_frames(); self.rejected("display_refresh_rate_unknown")

    def test_clock_conversion_mutation_is_rejected(self) -> None:
        self.frames[1]["display_time_ns"] += 1
        self.write_frames(); self.rejected("display_clock_conversion_mismatch")

    def test_unbounded_clock_calibration_is_rejected(self) -> None:
        self.frames[1]["clock_calibration"]["uptime_after_ns"] += 2_000_000
        self.write_frames(); self.rejected("display_clock_calibration_unbounded")

    def test_photon_claim_is_rejected(self) -> None:
        self.frames[1]["physical_scanout_proven"] = True
        self.write_frames(); self.rejected("physical_scanout_claim_unsupported")

    def test_synthetic_sample_cannot_be_live(self) -> None:
        self.sample["synthetic"] = True; self.rejected("synthetic_not_live_evidence")

    def test_missing_visual_endpoint_is_rejected(self) -> None:
        self.sample["stamps"].pop("physically_visible"); self.rejected("missing_endpoint_physically_visible")

    def test_refusal_cannot_disappear_into_success_population(self) -> None:
        self.sample["status"] = self.admission["status"] = "refused"
        self.rejected("sample_refused_failed_or_incorrect")

    def test_noncausal_effect_evidence_is_rejected(self) -> None:
        self.sample["stamps"]["effect_issued"]["nanos"] = 1030000000
        self.admission["stamps"]["effect_issued"]["nanos"] = 1030000000
        self.rejected("noncausal_endpoints")

    def test_wrong_binary_hash_is_rejected(self) -> None:
        self.sample["binary_sha256"] = self.admission["binary_sha256"] = "b" * 64
        self.rejected("binary_hash_mismatch")

    def test_empty_population_fails(self) -> None:
        report = acceptance.validate([], {}, self.scenarios, self.capture, "a" * 64, True)
        self.assertFalse(report["passed"])

    def test_missing_admitted_attempt_fails(self) -> None:
        report = acceptance.validate([], {self.sample["sample_id"]: self.admission}, self.scenarios, self.capture, "a" * 64, False)
        self.assertIn("admitted_attempt_missing_from_samples", [e["code"] for e in report["errors"]])

    def test_insufficient_sample_count_fails(self) -> None:
        report = acceptance.validate([self.sample], {self.sample["sample_id"]: self.admission}, self.scenarios, self.capture, "a" * 64, False)
        self.assertIn("insufficient_scenario_samples", [e["code"] for e in report["errors"]])

    def test_socket_origin_cannot_certify_hid_corpus(self) -> None:
        self.sample["origin"] = self.admission["origin"] = "socket"
        report = acceptance.validate([self.sample], {self.sample["sample_id"]: self.admission}, self.scenarios, self.capture, "a" * 64, False)
        self.assertIn("origin_not_acceptance_path", [e["code"] for e in report["errors"]])

    def test_full_corpus_keeps_all_four_window_counts(self) -> None:
        report = acceptance.validate([], {}, self.scenarios, None, "a" * 64, True)
        self.assertEqual({g["window_count"] for g in report["groups"]}, {1, 6, 12, 20})

    def test_threshold_relaxation_is_rejected(self) -> None:
        self.scenarios["budgets"][0]["p95_ms"] += 1
        with self.assertRaisesRegex(acceptance.EvidenceError, "frozen_scenario"):
            acceptance.validate([], {}, self.scenarios, None, "a" * 64, True)

    def test_sample_minimum_relaxation_is_rejected(self) -> None:
        self.scenarios["budgets"][0]["minimum_samples"] = 1
        with self.assertRaisesRegex(acceptance.EvidenceError, "frozen_scenario"):
            acceptance.validate([], {}, self.scenarios, None, "a" * 64, True)

    def test_held_resize_cannot_replace_key_up_with_receipt(self) -> None:
        self.budget = next(b for b in self.scenarios["budgets"] if b["id"] == "held_resize_final")
        self.rejected("key_up_missing")

    def test_held_resize_requires_visible_rate_evidence(self) -> None:
        self.budget = next(b for b in self.scenarios["budgets"] if b["id"] == "held_resize_final")
        stamp = {"nanos": 1005000000, "provenance": "resident_input_callback"}
        self.sample["stamps"]["key_up"] = self.admission["stamps"]["key_up"] = stamp
        self.sample["held_duration_ns"] = 5000000
        self.sample["held_visible_updates"] = []
        self.rejected("held_visible_rate_below_10hz")

    def test_png_crc_corruption_is_rejected(self) -> None:
        path = self.root / self.frames[1]["frame_path"]
        data = bytearray(path.read_bytes()); data[29] ^= 1; path.write_bytes(data)
        self.frames[1]["pixels_sha256"] = hashlib.sha256(data).hexdigest()
        self.write_frames(); self.rejected("png_crc_mismatch")

    def test_roi_cannot_probe_other_display_pixels(self) -> None:
        self.sample["visual_expectation"]["roi_px"] = [10, 10, 2, 2]
        self.rejected("visual_roi_outside_frame")

    def test_internal_endpoint_provenance_substitution_is_rejected(self) -> None:
        self.sample["stamps"]["intent_resolved"]["provenance"] = "appkit_submission"
        self.admission["stamps"]["intent_resolved"]["provenance"] = "appkit_submission"
        report = acceptance.validate([self.sample], {self.sample["sample_id"]: self.admission}, self.scenarios, self.capture, "a" * 64, False)
        self.assertIn("endpoint_provenance_invalid_intent_resolved", [e["code"] for e in report["errors"]])

    def test_duplicate_request_cannot_inflate_sample_population(self) -> None:
        other = copy.deepcopy(self.sample); other["sample_id"] = "second-sample-same-request"
        source = copy.deepcopy(self.admission); source["sample_id"] = other["sample_id"]
        admissions = {self.sample["sample_id"]: self.admission, other["sample_id"]: source}
        report = acceptance.validate([self.sample, other], admissions, self.scenarios, self.capture, "a" * 64, False)
        self.assertIn("duplicate_request_cannot_inflate_population", [e["code"] for e in report["errors"]])

    def test_absolute_p99_ceiling_miss_fails_even_with_full_sample_minimum(self) -> None:
        samples, admissions = [], {}
        for index in range(200):
            sample = copy.deepcopy(self.sample)
            sample["scenario_id"] = "input_intent"
            sample["sample_id"] = sample["request_id"] = f"ceiling-fixture-{index}"
            sample["stamps"].pop("physically_visible")
            receipt = 1000000000 + index * 100000000
            sample["stamps"] = {
                "receipt": {"nanos": receipt, "provenance": "resident_input_callback"},
                "intent_resolved": {"nanos": receipt + 41000000, "provenance": "resident_input_resolution"}}
            source = copy.deepcopy(sample); source["captured_admission"] = source.pop("admission")
            samples.append(sample); admissions[sample["sample_id"]] = source
        report = acceptance.validate(samples, admissions, self.scenarios, None, "a" * 64, False)
        self.assertIn("absolute_ceiling_missed", [e["code"] for e in report["errors"]])

    def production_events(self) -> list[dict]:
        return json.loads((ROOT / "fixtures/production-trace-events.json").read_text())

    def write_collection(self, events: list[dict]) -> Path:
        run = self.root / "production-shaped-run"; run.mkdir()
        metadata = {"schema": "leyline/native-trace-collection/v1",
            "source": "live_framed_socket", "passed": True, "epoch_ms": 1234,
            "binary_sha256": "a" * 64, "managed_window_count": 6}
        (run / "trace-events.jsonl").write_text("".join(json.dumps(row) + "\n" for row in events))
        (run / "trace-pages.jsonl").write_text(json.dumps({"response":{"events":events}})+"\n")
        (run / "scene-snapshot.json").write_text(json.dumps({"fixture_only":True})+"\n")
        metadata["artifact_sha256"] = {name: hashlib.sha256((run/name).read_bytes()).hexdigest()
            for name in ("trace-events.jsonl","trace-pages.jsonl","scene-snapshot.json")}
        (run / "collection.json").write_text(json.dumps(metadata))
        return run

    def test_production_trace_shape_joins_real_source_fields_to_independent_pixels(self) -> None:
        events = self.production_events(); run = self.write_collection(events)
        expected = {"request_id": "native-fixture-request", "scenario_id": "move_resize", "candidate_id": None,
                    "target_frames": events[2]["target_frames"], "baseline_frame_id": 0,
                    "visual_expectation": self.sample["visual_expectation"]}
        path = self.root / "expectations.jsonl"; path.write_text(json.dumps(expected) + "\n")
        output = self.root / "adapted"
        acceptance.adapt_trace(run, output, path, self.root)
        sample = acceptance.read_jsonl(output / "samples.jsonl")[0]
        self.assertEqual((sample["origin"], sample["correctness"], sample["stamps"]["physically_visible"]["nanos"]),
                         ("socket", True, 1020000000))

    def test_cg_session_tap_cannot_self_attest_hardware(self) -> None:
        events = self.production_events(); events[0]["origin"] = "input"
        run = self.write_collection(events)
        acceptance.adapt_trace(run, self.root / "adapted", None, None)
        sample = acceptance.read_jsonl(self.root / "adapted/samples.jsonl")[0]
        self.assertEqual((sample["origin"], sample["hardware_origin_verified"]), ("cg_session_tap", False))

    def test_immutable_target_geometry_mismatch_stays_a_gap(self) -> None:
        run = self.write_collection(self.production_events())
        path = self.root / "expectations.jsonl"
        path.write_text(json.dumps({"request_id": "native-fixture-request", "candidate_id": None,
                                   "target_frames": {"700": {"x":0,"y":0,"w":3,"h":2}}}) + "\n")
        acceptance.adapt_trace(run, self.root / "adapted", path, None)
        sample = acceptance.read_jsonl(self.root / "adapted/samples.jsonl")[0]
        self.assertIn("immutable_candidate_or_geometry_expectation_mismatch", sample["adapter_gaps"])

    def test_raw_refusal_is_retained_by_adapter(self) -> None:
        events = self.production_events(); events[5]["kind"] = "refusal"; events[5]["status"] = "refused"
        events = events[:6]
        acceptance.adapt_trace(self.write_collection(events), self.root / "adapted", None, None)
        sample = acceptance.read_jsonl(self.root / "adapted/samples.jsonl")[0]
        self.assertEqual(sample["status"], "refused")

    def test_trace_drop_delta_blocks_adaptation(self) -> None:
        page = {"schema":"leyline/native-performance-trace/v1", "pid":123, "dropped_events":1,
                "events":self.production_events(), "last_sequence":7}
        with self.assertRaisesRegex(acceptance.EvidenceError, "trace_drop_counter_changed"):
            acceptance.trace_page_events(page, 0, 123, 0)

    def test_trace_sequence_gap_cannot_be_silently_skipped(self) -> None:
        page = {"schema":"leyline/native-performance-trace/v1", "pid":123, "dropped_events":0,
                "events":self.production_events()[1:], "last_sequence":7}
        with self.assertRaisesRegex(acceptance.EvidenceError, "trace_sequence_gap"):
            acceptance.trace_page_events(page, 0, 123, 0)

    def test_actual_length_framed_exporter_protocol_and_paginated_collector(self) -> None:
        # Controlled peer proves real socket framing. Its contents remain synthetic fixture data.
        peer_path = self.root / "fixture.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); server.bind(str(peer_path)); server.listen()
        server.settimeout(2)
        done = threading.Event(); failures = []
        fixture_events = self.production_events()
        def serve() -> None:
            try:
                while not done.is_set():
                    try:
                        peer, _ = server.accept()
                    except socket.timeout:
                        continue
                    with peer:
                        header = peer.recv(4)
                        if not header:
                            continue
                        size = struct.unpack(">I", header)[0]
                        raw = bytearray()
                        while len(raw) < size:
                            raw.extend(peer.recv(size - len(raw)))
                        body = json.loads(raw)
                        if body["op"] == "hello":
                            response = {"ok":True,"pid":123,"epoch_ms":1234,"ready":True}
                        elif body["op"] == "snapshot":
                            response = {"ok":True,"pid":123,"revision":41,"world":{"world_complete":True,
                                "windows":[{"window_id":700+i,"eligible":True,"space_visible":True,"space_enabled":True} for i in range(6)]}}
                        else:
                            cursor = body["args"]["from_sequence"]
                            response = {"ok":True,"schema":"leyline/native-performance-trace/v1","pid":123,
                                "dropped_events":0,"last_sequence":7,"oldest_sequence":1,
                                "events":[row for row in fixture_events if row["sequence"] > cursor]}
                        data = json.dumps(response).encode(); peer.sendall(struct.pack(">I",len(data))+data)
            except Exception as error:
                failures.append(error)
        worker = threading.Thread(target=serve, daemon=True); worker.start()
        binary = self.root / "fixture-binary"; binary.write_bytes(b"fixture-only")
        try:
            report = acceptance.run_collector(peer_path, binary, self.root / "collected", 0.02, 1, 0)
        finally:
            done.set(); server.close(); worker.join(3)
        self.assertEqual((report["passed"], report["event_count"]), (True,7))

    def test_hardware_attestation_must_bind_actual_tap_binary_epoch_and_external_artifact(self) -> None:
        events = self.production_events(); events[0]["origin"] = "input"; events[0]["source_input_generation"] = 9
        for event in events:
            event["sequence"] += 1
        events.insert(0, {"kind":"tap_receipt", "sequence":1, "uptime_ns":1000000000,
            "provenance":"resident_monotonic_observation", "origin":"input", "input_boundary":"cg_session_tap",
            "hardware_origin_verified":False, "action_id":"resize.adjust.east", "input_generation":9,
            "cg_event_timestamp_ns":999000000})
        run = self.write_collection(events)
        artifact = self.root / "synthetic-hardware-attestation-fixture.txt"; artifact.write_text("synthetic test only")
        hardware = {"tap_sequence":1, "method":"operator_physical_keyboard", "evidence_path":str(artifact),
            "evidence_sha256":hashlib.sha256(artifact.read_bytes()).hexdigest(), "binary_sha256":"a"*64,
            "epoch_ms":1234, "action_id":"resize.adjust.east", "input_generation":9, "cg_event_timestamp_ns":999000000}
        path = self.root / "hardware.jsonl"; path.write_text(json.dumps(hardware)+"\n")
        acceptance.adapt_trace(run, self.root / "attested", None, None, path)
        sample = acceptance.read_jsonl(self.root / "attested/samples.jsonl")[0]
        self.assertEqual((sample["origin"],sample["hardware_origin_verified"]), ("hid",True))

    def test_collector_cannot_execute_mutations(self) -> None:
        with self.assertRaisesRegex(acceptance.EvidenceError, "collector_operation_is_not_read_only"):
            acceptance.resident_request(Path("/unused"), {"op":"act"}, 1)

    def test_adapter_never_turns_missing_verification_into_a_timestamp(self) -> None:
        events = [event for event in self.production_events() if event["kind"] != "verified"]
        acceptance.adapt_trace(self.write_collection(events), self.root / "adapted", None, None)
        sample = acceptance.read_jsonl(self.root / "adapted/samples.jsonl")[0]
        self.assertNotIn("verified",sample["stamps"])

    def test_changed_collected_trace_cannot_be_adapted(self) -> None:
        run = self.write_collection(self.production_events())
        with (run / "trace-events.jsonl").open("a") as file:
            file.write('{}\n')
        with self.assertRaisesRegex(acceptance.EvidenceError,"collected_source_artifact_missing_or_changed"):
            acceptance.adapt_trace(run, self.root / "adapted", None, None)

    def test_already_collected_ring_overwrite_is_not_a_recording_drop(self) -> None:
        page = {"schema":"leyline/native-performance-trace/v1","pid":123,"dropped_events":10,
                "oldest_sequence":11,"last_sequence":11,
                "events":[{"kind":"admission","sequence":11,"uptime_ns":1000000000,"provenance":"resident_monotonic_observation"}]}
        _, cursor = acceptance.trace_page_events(page,10,123,0)
        self.assertEqual(cursor,11)

    def test_uncollected_ring_overwrite_still_fails(self) -> None:
        page = {"schema":"leyline/native-performance-trace/v1","pid":123,"dropped_events":10,
                "oldest_sequence":11,"last_sequence":11,
                "events":[{"kind":"admission","sequence":11,"uptime_ns":1000000000,"provenance":"resident_monotonic_observation"}]}
        with self.assertRaisesRegex(acceptance.EvidenceError,"trace_sequence_gap"):
            acceptance.trace_page_events(page,9,123,0)

    def test_final_geometry_already_landed_before_key_up_satisfies_release_ceiling(self) -> None:
        self.budget = next(b for b in self.scenarios["budgets"] if b["id"] == "held_resize_final")
        self.sample["stamps"]["key_up"] = self.admission["stamps"]["key_up"] = {
            "nanos":1025000000,"provenance":"resident_input_callback"}
        self.sample["held_duration_ns"] = 25000000
        self.sample["held_visible_updates"] = [{"frame_id":1,"geometry_key":"fixture-target-2x2",
            "visual_expectation":self.sample["visual_expectation"]}]
        self.assertEqual(self.check_sample(),0)


if __name__ == "__main__":
    unittest.main()
