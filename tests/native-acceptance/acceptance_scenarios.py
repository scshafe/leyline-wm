#!/usr/bin/env python3
"""The frozen acceptance scenarios and the one percentile definition, shared by the collector and the crash measurer."""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCENARIOS = HERE / "scenarios.json"
SCENARIOS_SHA256 = "7470f5fc1d1da91dc35178ee7dd6ac95eb5a9a013d45b42c796b6b8dfc432388"


def scenario_digest(scenarios: dict) -> str:
    return hashlib.sha256(json.dumps(scenarios, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def load_frozen_scenarios() -> dict:
    """scenarios.json exactly as frozen; a changed threshold or inventory is refused, never adopted."""
    scenarios = json.loads(SCENARIOS.read_text())
    if scenario_digest(scenarios) != SCENARIOS_SHA256:
        raise ValueError("frozen_scenario_thresholds_or_inventory_changed")
    return scenarios


def nearest_rank(values: list[float], percentile: int) -> float:
    """The smallest observed value at or above the requested rank; never interpolated."""
    return sorted(values)[max(0, math.ceil(len(values) * percentile / 100) - 1)]
