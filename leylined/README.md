# Native resident and model

`Sources/LeylineModel` owns pure arrangement, allocation, navigation, mode FSM and
evidence models. `Sources/leylined` owns native observation, keyboard input,
commands, planning, journaled effects, lifecycle and immutable presentation in one
resident. `Sources/CResidentAtomics` provides process-local atomic primitives.

The production Swift package excludes self-test sources. Build with
`bin/leylined-build`; use `bin/leylined-build --tests` to emit the separate
`bin/leylined-tests` developer runner. Recovery has its own `--tests` build profile.
Native checks and fixtures belong to development, not installed production
resources. Independent model regression oracles are under `tests/oracles`.

Production keyboard resources are `keymap/global.json`, `keymap/modes.json` and
`keymap/decode-us.json`. See [architecture](../docs/architecture/leylined-core.md),
[development](../docs/development.md) and [contracts](../docs/README.md).
