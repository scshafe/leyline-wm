# Responsiveness and evidence requirements

Leyline's ordinary work begins from input, AX/window/app notifications,
Space/display changes and configuration events. Rendering consumes committed
revision snapshots. State polling, quiet-period debounce and fixed settle sleeps
cannot substitute for observing a normal interaction.

## Scheduling invariants

One ordered authority retains original monotonic receipt, identity, context and
observer generation. Async observation/effect completions return as fenced events;
they cannot overwrite a newer revision. Replaying the same initial state and causal
input order yields the same decisions.

Each actuation lane permits one effect in flight and one pending desired-state
intent. Relative resize inputs accumulate displacement before coalescing. Focus,
commit, key-up and lifecycle events retain semantic order. Queue overflow is an
explicit refusal. Cancellation is checked at the final authority transition,
including after journal I/O.

AX reads and AppKit do not execute inside the input callback or authoritative
transition. Bounded presentation delivery replaces superseded visual work, not
state transitions. Pooled panels disable implicit animation. Rendering performs
no external discovery, process spawn or configuration read.

Every deadline has an explicit purpose and owner. Liveness watchdogs, bounded
effect evidence, recovery backoff and validation-only cache audits are distinct
from normal-state polling. Recovery takes a fresh versioned baseline and never
blindly replays stale effects. Independent input watchdogs release claims despite
blocked action dispatch or rendering.

## Numerical requirements

These are engineering acceptance requirements, **not measured guarantees for
version 1.0.0**. The machine-readable budget and timer inventory is
[the responsiveness fixture](../../leylined/Fixtures/responsiveness/inventory.json).

| Path and endpoint | Requirement |
|---|---|
| Border receipt → renderer submission | p95 ≤ 16 ms |
| Border receipt → independent physical visibility | p95 ≤ 125 ms |
| Input receipt → intent resolved | p50 ≤ 10, p95 ≤ 20, p99 ≤ 40 ms |
| Navigation receipt → confirmed focus | p50 ≤ 50, p95 ≤ 100, p99 ≤ 150 ms |
| Move/resize receipt → first physical frame | p50 ≤ 75, p95 ≤ 125, p99 ≤ 200 ms |
| Cursor/stage receipt → renderer submission | p95 ≤ 50 ms |
| Edge commit → first physical frame | p95 ≤ 200 ms |
| Edge commit → verified result | p95 ≤ 500, p99 ≤ 1000 ms |
| No-op world event → committed plan | p95 ≤ 50 ms; zero AX writes |
| Lifecycle receipt → stable verified layout | p50 ≤ 250, p95 ≤ 500, p99 ≤ 1000 ms |
| Cached receipt → targeted snapshot read | median < 50, p95 < 75 ms; fresh generation-equivalent data |
| Fault receipt → tap-local release | maximum ≤ 250 ms |
| Process crash → serving | p95 ≤ 3 seconds |
| Serving → verified convergence | p95 ≤ 2 seconds |
| Trust loss → surfaced state | maximum ≤ 2 seconds |
| Held-resize final key-up → verified result | maximum ≤ 150 ms; ≥ 10 physical updates/s; one pending desired state |

Border gates remain proposed frozen requirements. Relative improvements do not
waive absolute ceilings. Record p50/p95/p99/max, correctness/refusals, queue depth,
AX reads/enumerations and sample coverage. Chord paths require at least 200 samples,
lifecycle paths 100 and crash/fault paths 20, in the declared 1/6/12/20-window scenes
where applicable.

## Measurement boundaries

Keep genuine input/notification receipt, targeted read, intent, commit, issue,
readback, AppKit submission and independent physical visibility distinct. A setter
acknowledgment, queued callback, socket-generated input or renderer timestamp does
not establish a physical-keyboard or visible endpoint. A compositor sample does
not automatically establish physical scanout.

Evidence binds source and binary hashes, hardware, refresh rate, load, window
population, original identity and timestamps. Missing, empty, stale or substituted
endpoints fail the relevant check. External observation failure has a bounded
explicit result; it cannot become an invented successful timing sample.

`ley bench native` collects and validates scoped acceptance evidence. Automated
native/oracle/CLI/recovery/tooling suites verify their own model and boundary
contracts. They do not certify live Space identity across login, keyboard
recovery under induced wedges or these physical latency requirements.
