# Development and contributions

Build on macOS 14 or later with Swift 6 and Xcode Command Line Tools. Developer
verification additionally needs current `jq`, Python 3 and the explicit
checksum-bound oracle tool setup below. Native downloaded apps need no compiler or Python. Optional CLI diagnostics
require `jq`, which the Homebrew formula supplies.

## Source map

| Path | Responsibility |
|---|---|
| `leylined/Sources/LeylineModel` | Pure layout, allocation, navigation, FSM and evidence models |
| `leylined/Sources/leylined` | Resident authority, command client, observation, input, effects and presentation |
| `leylined/Sources/CResidentAtomics` | Process-local atomic primitives |
| `leylined/Fixtures` | Native hermetic and frozen regression inputs |
| `keymap` | Shipping global/mode chords and US decode table |
| `config/registry/borders.json` | Shipping border metadata/defaults |
| `commands`, `lib`, `bin/ley` | Explicit CLI operations and source verification |
| `bin/leylined-build`, `bin/leyline-recovery-app-build` | Resident and Recovery builds |
| `tests/native-cli`, `tests/native-acceptance` | CLI boundaries and scoped release-evidence tooling |
| `tests/oracles` | Independent frozen model/navigation/geometry regression closure |
| `scripts/release` | Clean source/app packaging and release checks |

[Architecture](architecture/leylined-core.md) maps the one resident. Extend existing
canonical capabilities instead of adding parallel writers, process owners or
renderer-side decisions.

## Production and test profiles

```sh
bin/ley build all
bin/leylined-build --tests
bin/leyline-recovery-app-build --tests
scripts/development/setup-oracle-jq.sh
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

## Frozen oracle compiler

The independent oracle suite uses official jq 1.8.1 binaries whose arm64/x86_64
SHA-256 digests are checked before execution. Run
`scripts/development/setup-oracle-jq.sh` explicitly; it caches the selected tool
under ignored `.release-build/oracle-jq`. The offline `--verify` mode rejects a
missing or changed binary. `LEYLINE_ORACLE_JQ_DIR` selects an alternate cache
root. `ley test oracles` verifies the tool and scopes its PATH to that suite;
`ley test cli` and shipping diagnostic commands continue to use current jq.

jq 1.8.2 has an upstream compile-time regression in transitive imports: library
registration order can cause dead-code elimination to free a referenced helper.
It aborts before evaluating valid frozen inputs. The fix is merged upstream in
[jqlang/jq#3620](https://github.com/jqlang/jq/pull/3620), after the 1.8.2 release.
The isolated 1.8.1 compiler processes only trusted repository regression inputs;
it is neither bundled in the app nor substituted for user-facing jq. No frozen
fixtures or oracle modules are rewritten to accommodate the compiler defect.

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
