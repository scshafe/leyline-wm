# Development and contributions

Build on macOS 14 or later with Swift 6 and Xcode Command Line Tools. Developer
verification additionally needs `jq` and Python 3. Native downloaded apps need no
compiler or Python. Optional CLI diagnostics require `jq`, which the Homebrew
formula supplies.

## Source map

| Path | Responsibility |
|---|---|
| `leylined/Sources/LeylineModel` | Pure layout, allocation, navigation, FSM and evidence models |
| `leylined/Sources/leylined` | Resident authority, command client, observation, input, effects and presentation |
| `leylined/Sources/CResidentAtomics` | Process-local atomic primitives |
| `leylined/Fixtures` | Native hermetic and frozen regression inputs |
| `keymap` | Shipping global/mode chords and the US decode table for bound keys |
| `commands`, `lib`, `bin/ley` | Explicit CLI operations and source verification |
| `bin/leylined-build`, `bin/leyline-recovery-app-build` | Resident and Recovery builds |
| `bin/leyline-recovery.swift` | The independent, grant-free Finder Recovery app |
| `tests/native-cli` | CLI boundary checks |
| `tests/native-acceptance` | Scoped live-evidence collectors behind `ley bench` ([notes](../tests/native-acceptance/README.md)) |
| `tests/oracles` | Independent frozen model/navigation/geometry regressions |
| `tests/release`, `tests/source_checks.py` | Packaging/installer regressions and source syntax/link/dependency checks |
| `scripts/release`, `packaging`, `install.sh` | Clean exports, app packaging, privacy audit and archive installer |

[Architecture](architecture/leylined-core.md) maps the one resident. Extend existing
canonical capabilities instead of adding parallel writers, process owners or
renderer-side decisions.

## Production and test profiles

```sh
bin/ley build all
bin/leylined-build --tests
bin/leyline-recovery-app-build --tests
bin/ley test all
```

Production `bin/leylined` excludes self-test sources and oracle CLI adapters.
The test profile emits `bin/leylined-tests`, with a separate Swift scratch path;
`ley test` selects that runner. The Recovery test profile emits
`bin/Leyline Recovery Tests.app`, separately from the production Recovery app.
Frozen fixtures and developer harnesses are not shipping resources. The native
test aggregate includes installation. Production CLI actions still use the
native resident socket.

Targeted checks are `bin/ley test native`, `oracles`, `cli`, `recovery`,
`acceptance-tools`, `release`, `syntax`, `json`, `links` and `dependencies`.
A missing binary, fixture/tool or empty inventory fails rather than skipping required coverage.
Do not run actuating probes or launchd installation as part of a hermetic test.
`ley test release` refuses to run while an `org.leyline.leylined` job is registered,
leaving that job untouched.

To inspect the insertion cue's actual view drawing without opening decoration
panels, run `bin/leylined-tests self-test projection --render-samples /tmp/leyline-preview-samples`.
The output contains fixture-based PNGs for LEFT, RIGHT, ABOVE and BELOW; it does
not certify live compositing or input timing.

## Frozen oracles

`tests/oracles` holds independent frozen answers for grid geometry, recursive
targets, tileability, display assignment, minimum learning, reclaim, insertion
and directional navigation. `ley test oracles` runs them through the production
model functions via the developer runner; `fixtures.sha256.json` pins their
bytes. See [the oracle notes](../tests/oracles/README.md).

## Change discipline

Preserve exact identity/lifetime/Space fences, immutable candidates, no-hole
geometry and member conservation. Preview and commit must use the same rounded
targets. Keep accepted/noop/refused/failed results honest, including partial external
effects. Config validation or observed-world failure cannot become a fabricated
healthy baseline. Rendering and observation remain outside the ordered authority.

Add tests for the changed invariant and run its relevant suite before the full
check. Keep independent frozen fixture bytes immutable unless intentionally
replacing their contract and provenance. Update current guides/contracts with the
same change. Use focused commits such as `fix:`, `feat:`, `docs:` or `test:`.

Reports should name version, platform, application, reproduction and machine-readable
error. Redact local titles/paths/identifiers before sharing diagnostics. Do not
commit user state, signing keys, private handoffs or generated binaries. Shared
Swift sources must stay unchanged while a build uses them.

## Live verification limits

Model, command and fake-executor checks prove their scoped invariants. Physical
keyboard, compositor/scanout, live Space identity, trust and wedge/crash recovery
need separate source/binary-bound evidence. `ley bench native` provides collectors
and validators; see [responsiveness](contracts/event-driven-responsiveness.md).
Do not infer measured performance from fixture success or accepted AX setters.

For signatures and local permission continuity, see
[developer signing](instructions/local-signing-cert.md). For anonymous source and
versioned artifacts, see [release preparation](releasing.md).

Contributions use the project's [MIT License](../LICENSE).
