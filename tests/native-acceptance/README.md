# Native acceptance tooling

This directory owns a test-only AppKit fixture, independent WindowServer pixel
capture and source-correlated acceptance validation. It does not install a
production resident, synthesize keyboard events, change grants or manipulate
other applications. Every UI action uses CUA or actual operator hardware input.

The boundary-integration lens applies: real fixture windows exercise AppKit/AX;
ScreenCaptureKit observes compositor pixels; genuine HID input and physical
display scanout remain separate boundaries. Requirements come from
[`core-window-manager-spec.md`](../../docs/contracts/core-window-manager-spec.md#acceptance-and-performance-contract),
[`event-driven-responsiveness.md`](../../docs/contracts/event-driven-responsiveness.md),
and the single-process plan's remaining acceptance table.

## Build and inspect without launching

```bash
bash tests/native-acceptance/build-fixture.sh /tmp/leyline-acceptance-build-unique
'/tmp/leyline-acceptance-build-unique/Leyline Acceptance Fixture.app/Contents/MacOS/AcceptanceFixture' --self-test-clock
'/tmp/leyline-acceptance-build-unique/Leyline Acceptance Fixture.app/Contents/MacOS/AcceptanceFixture' --preflight
/usr/bin/python3 tests/native-acceptance/test_collect_and_validate.py
```

The output directory must be new and under `/tmp`. Signing uses the stable
`leyline-local-cert`, or `LEYLINE_CODESIGN_IDENTITY`; unavailable signing fails
the build. No ad-hoc fallback or grant repair occurs.

`--preflight` calls only `CGPreflightScreenCaptureAccess`, returns an explicit
`CAPTURE.SCREEN_RECORDING_REQUIRED` envelope and exit77 when missing, and never
requests permission. The Capture button also checks before requesting shareable
content. Existing leylined Accessibility authorization does not authorize this
new app's Screen Recording access.

## Fixture UI and read-only IPC

Launch the built app through CUA. With no arguments it creates a fresh
`/tmp/leyline-native-acceptance-session-UUID` directory displayed in its controls.
Explicit `--output /tmp/new-session` is also supported when invoked through an
authorized CUA-operated Terminal. Launching does not immediately create a window
cohort or start capture. The floating utility control panel is separate from the
ordinary fixture cohort; the resident's actual classification must confirm it is
ignored before measuring an exact window-count scene.

Buttons choose **1**, **6**, **12** or **20** actual ordinary windows. Each has a
unique title/identity marker, black content edges, blue identity bars and a
120×90point minimum frame. These are fixture-owned windows with actual CG window
numbers. The app does not call AX setters. Verify that all intended cohort IDs
and no unexpected eligible windows are admitted by the resident before measuring.

**Lifecycle100** executes100 minimize/restore/close/create cycles:400 events with
one-second workload spacing. This timer schedules fixture events; it is not a
product settle timer. **Stop** cancels future lifecycle work and capture.
Lifecycle counts are setup/workload counts, not certified product samples.

IPC consists of files under the displayed session directory:

| File | Boundary |
|---|---|
| `window-manifest.json` | Atomic fixture PID/window IDs, actual frames/minima and workload status |
| `fixture-events.jsonl` | Actual fixture lifecycle callback/create receipts |
| `fixture-error.json` | Failed lifecycle event persistence; workload stops |
| `capture-status.json` | Atomic capture readiness/failure/permission state |
| `clock-calibration.json` | Mach ticks/uptime bracketing and timebase conversion |
| `capture-frames.jsonl` | Independent frame status, display time, ROI, refresh and pixel hashes |
| `frame-N.png` | Distinct compositor pixels |

```bash
/usr/bin/python3 tests/native-acceptance/collect-and-validate.py fixture-status \
  --capture-root /tmp/leyline-native-acceptance-session-UUID
```

There is no mutation socket. Readers cannot trigger UI actions through IPC.

## Capture semantics

Before selecting **Capture**, optionally write `capture-roi.json` in the session
directory with `{"roi_px":[x,y,width,height]}`. Coordinates are physical display
pixels from the top-left of the primary captured display. The ROI must include
fixture edges and Leyline border/preview pixels. Capture includes all composited
windows; it does not exclude Leyline panels. The ROI is fixed for a capture run;
an insufficient ROI fails observation rather than following windows silently.
Absent this file, the full primary display is saved. Keep the scene limited to
test content. This collector currently captures one primary display; a complete
multi-display pixel corpus needs additional display streams.

The collector persists PNGs only when pixels change, while recording frame
metadata on every delivery. It stops at512MiB of distinct PNGs or20,000 frame
records with an explicit storage gap. Split long workloads into declared fresh
sessions; retain all admissions and exclusions across them. Restarting capture
does not erase existing records or reset the storage accounting.

`SCStreamFrameInfo.displayTime` is mach absolute time when WindowServer displayed
the frame, according to the installed SDK's `SCStream.h` and
[Apple documentation](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime).
Record callback arrival independently. Convert ticks with mach timebase; bracket
mach time against DispatchTime uptime. The validator rejects missing timestamps,
unbounded calibration, unknown refresh, incomplete frames and changed PNG hashes.
It never replaces an unknown refresh rate with60Hz.

`independent_windowserver_composition` means independently captured compositor
pixels. It does not establish physical panel scanout, emitted photons or a
hardware key actuation timestamp. An external synchronized camera/photodiode is
needed when acceptance requires that stricter endpoint.

## Resident trace adapter contract

Production trace/export belongs to the resident implementation owner. Export
one source admission row per attempt, including refusals and retries, to a
separate JSONL file. Normalize into these keys:

```json
{
  "sample_id":"unique-attempt", "request_id":"resident-request",
  "scenario_id":"move_resize", "origin":"hid", "window_count":6,
  "binary_sha256":"exact-installed-binary-sha256", "status":"accepted",
  "retry_of":null,
  "captured_admission":{
    "revision":41,"observer_generation":12,"input_generation":9,
    "observer_epoch":"epoch","space_key":"space","topology_revision":3,
    "window_id":700,"pid":123,"lifetime":4
  },
  "stamps":{
    "receipt":{"nanos":1000000000,"provenance":"resident_input_callback"},
    "effect_issued":{"nanos":1002000000,"provenance":"resident_ax_issue"},
    "verified":{"nanos":1010000000,"provenance":"resident_scoped_ax_readback"}
  }
}
```

The example is schematic, not measured evidence. Use actual production trace
identity/timestamps. Null identity dimensions require a scenario that cannot
have that dimension; unknown applicable identity cannot authorize a mutation.
Endpoint provenance labels and thresholds are frozen in `scenarios.json`.
Every sample validates against its own source admission. Revisions/generations
may advance between samples.

Sample rows repeat metadata, use `admission` for the captured identity, declare
`synthetic:false`, `correctness:true` only after independent scenario checks,
and include all source internal stamps without modification. Visual rows add:

```json
{
  "baseline_frame_id":0,
  "visual_expectation":{
    "roi_px":[0,0,100,100],
    "probes":[
      {"x":0,"y":0,"rgba":[0,0,0,255],"tolerance":8},
      {"x":99,"y":0,"rgba":[0,0,0,255],"tolerance":8},
      {"x":0,"y":99,"rgba":[0,0,0,255],"tolerance":8},
      {"x":99,"y":99,"rgba":[0,0,0,255],"tolerance":8}
    ]
  }
}
```

Select probes from the independently specified target geometry/color, including
old-edge absence when needed. Four arbitrary dark pixels do not establish a
correct window shape. Probe design owns that oracle. Validate fixture markers,
role and target frame, not an unrelated foreground change. The baseline must
precede receipt and fail the target expectation. The independent join uses the
first retained complete frame matching the probes after receipt; it is a sampled
upper bound on when target pixels became visible, not proof no earlier uncaptured
frame existed. Unchanged matching baselines cannot certify first-change paths.

Held resize additionally supplies source `key_up`, `held_duration_ns`,
`held_visible_updates` with distinct `geometry_key`, `frame_id` and per-update
`visual_expectation`, plus `counters.maximum_pending_desired`. The validator
requires source-to-key-up duration consistency, independently matching distinct
probe expectations, ≥10Hz and final verified AND compositor state within150ms.
The geometry key and probes must describe actual target geometry; random keys or
animation/color changes are not resizing evidence.

## Assemble and validate

The live source adapter reads the actual resident's framed socket, without
mutations or reconstructed health timestamps:

```bash
/usr/bin/python3 tests/native-acceptance/collect-and-validate.py run-collector \
  --socket "$HOME/.config/leyline"/runtime/sockets/leylined.sock \
  --binary "$PWD/bin/leylined" \
  --output /tmp/new-live-trace-run --seconds 30
/usr/bin/python3 tests/native-acceptance/collect-and-validate.py adapt-trace \
  --run-root /tmp/new-live-trace-run --output /tmp/new-adapted-trace \
  --expectations /tmp/request-pixel-expectations.jsonl --capture-root /tmp/session
```

`run-collector` accepts only hello/snapshot/trace operations. It records raw
128-event pages, actual exported events, collection metadata and an actual world
snapshot. Managed scene count uses resident eligibility/visible/enabled flags,
not fixture count: four user windows plus six fixture windows is a10-window scene.
Each RPC has a bounded timeout; a failed read stops collection and records the
failure. No hidden reconnect, retries or dropped success-only populations occur.
PID change, sequence gap, new recording drops and changed binary fail collection.
The source aggregates retention overwrites and nonblocking recording drops.
Retention overwrites equal `oldest_sequence - 1`; the adapter subtracts those
while preserving the raw total. Only overwrites of already collected/excluded
records are harmless; any missing collected sequence still fails.
The exported ring is bounded4096, so collect while trials run. Default start is
the current trace tail, with prior events explicitly excluded as premeasurement.
`--from-sequence 0` requests history and rejects overwritten/gapped history.
The collector's `passed` indicates lossless collection, never acceptance.

`adapt-trace` writes real `admissions.jsonl`, `samples.jsonl`, unmatched-request
diagnostics and an uncertified adapter summary. It directly joins actual
admission/intent/effect/verification/completion/refusal records by request ID.
No missing verification endpoint is manufactured. Render submission joins exact
committed revision and candidate ID; nearest timestamps are insufficient.
`plan_committed` at authoritative API return retains provenance
`resident_authority_publication_return`, which is a conservative publication-
return observation, not the internal commit instant. Terminal refusals remain
samples; incomplete joins keep explicit gaps. Unknown action categories remain
unmapped, rather than silently disappearing.

Raw source pages/events and the scene snapshot are SHA256-bound in collection
metadata. Modification after collection blocks adaptation.

Each expectation row has `request_id`, `scenario_id`, `candidate_id`,
`target_frames` (direct ID→{x,y,w,h}), `baseline_frame_id` and `visual_expectation`.
The immutable geometry/candidate must match emitted planner/effect targets before
the independent PNG join. The adapter does not invent pixel correctness from
accepted status. Frame correctness requires actual requested/landed evidence;
focus correctness requires actual verified focus. Full product oracles remain
the scenario author's responsibility.

Input origin is `cg_session_tap` by default. The resident explicitly reports
`hardware_origin_verified:false`; tap delivery is not HID proof. Optional
`--hardware-attestations /tmp/attestations.jsonl` supports separately documented
physical trials. Each record must contain `tap_sequence`, `action_id`,
`input_generation`, `cg_event_timestamp_ns`, `binary_sha256`, `epoch_ms`,
`method` (`operator_physical_keyboard` or `instrumented_hid_device`),
`evidence_path` and `evidence_sha256`. The artifact must exist and its hash,
binary/epoch and exact captured tap fields must match. Only those matching
records yield `origin:hid`; the original raw tap fact remains unchanged. The
external artifact must genuinely document physical input; hash matching does
not independently establish that its contents are truthful.

Use the adapter outputs with `validate`; `assemble` remains available for already
normalized source-correlated sample files:

```bash
/usr/bin/python3 tests/native-acceptance/collect-and-validate.py assemble \
  --samples /tmp/normalized-samples.jsonl --admissions /tmp/source-admissions.jsonl \
  --capture-root /tmp/session --binary /absolute/path/to/installed/leylined \
  --output /tmp/new-joined-samples.jsonl
/usr/bin/python3 tests/native-acceptance/collect-and-validate.py validate --full \
  --samples /tmp/new-joined-samples.jsonl --admissions /tmp/source-admissions.jsonl \
  --capture-root /tmp/session --binary /absolute/path/to/installed/leylined \
  --output /tmp/new-acceptance-report.json
```

Outputs must be new files. `assemble` joins pixels; it does not certify samples.
`validate` returns0 only for a passing requested population,1 for failed gates,
or65 for invalid tooling/input. Partial validation does not certify the full
product. `--full` requires every frozen path/scene population. A genuinely
inapplicable interaction still needs an explicit source-grounded applicability
decision; the tool does not invent exemptions or replace movement with noops.
Refused/failed attempts remain in the report and fail their population. Missing
admitted attempts and unsupported/synthetic origins fail. The original200 chord,
100 lifecycle and20 crash minima and absolute thresholds are unchanged.

Internal causal order does not force AX verification after compositor capture.
Both follow issue when supplied; receipt precedes each. Held final timing uses
actual key-up, never substituted admission time. If final geometry already
landed/verified before key-up, elapsed final-landing delay is zero; the original
earlier endpoint stamps remain intact. A hold-start receipt cannot be invented
by changing the final repeat's admission. Aggregate held episodes require
explicit source-bound membership and duration evidence.

Socket/CUA actions can measure actual AX/compositor behavior, but socket/CUA
populations fail a required HID origin. Physical chords/repeats and Karabiner
recovery require operator hardware input on this host. Actual trust loss,
multi-display disconnect, Finder wedge recovery and process crash/serving require
their own real OS/hardware/source observations. This harness does not weaken
grants or invoke recovery, launchctl, process killing or external AX actions.

## Mutation verification and remaining oracle gaps

`test_collect_and_validate.py` verifies endpoint substitution, verified-before-
visible ordering, per-sample authority, stale identities, PNG/hash/clock/ROI
corruption, source omissions, refused samples, origin distinctions and threshold/
minimum tampering. All test artifacts are synthetic; test success is not a
measured live pass.

The fixture does not exercise Safari/Chrome AX wrapper repair. Source admission
exports must be honestly bound to the installed binary and runtime; matching
JSON fields alone cannot attest their origin. Pixel probes establish selected
pixels, not exhaustive raster correctness. Display capture cannot prove photons.
These gaps follow the boundary-integration lens, including the Testineer memory
`2026-05-kitty-graphics-case-sensitivity`: typed intent and backend output are
separate proofs.

## Ordinary launchd crash measurement

`measure-crash-recovery.py` kills only the exact signed resident identified by
its private socket, protected process path and registered launchd job. It never
kickstarts or invokes recovery. A new process must expose genuine startup
reconciliation proof, current complete observation, live claims and matching
requested geometry before convergence can pass. PID/epoch changes, scene drift,
source/binary mismatch and timeout remain failures.

Supply a trusted release-build binding JSON containing `source_commit`, the
signed `binary_sha256`, every Swift/package `source_files` SHA256 and an empty
`source_drift` array. The commit must equal current HEAD and source must be clean.
The executor creates this binding from the frozen before/after build inventory.

```bash
/usr/bin/python3 tests/native-acceptance/measure-crash-recovery.py \
  --socket "$LEYLINE_ROOT/runtime/sockets/leylined.sock" \
  --binary /absolute/path/to/bin/leylined \
  --source-commit FULL_COMMIT_SHA --build-binding /tmp/final-build-binding.json \
  --output /tmp/new-crash-run --trials 20
```

All attempts and raw observations stay
in the new output directory. The receipt is a conservative SIGKILL-dispatch
lower bound, explicitly distinguished from observed process exit. Statistics use
one independent collector clock. Fewer than20 attempts or an unexpected scene
count cannot pass the population; `checks_passed` remains separate from
`population_sufficient`, and `full_product_certified` is always false. These
process-boundary measurements never establish HID input or physical display
scanout. The five tooling mutation tests do not kill any resident.
