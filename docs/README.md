# Leyline documentation

Leyline 1.0.1 manages tiled windows, borders, move previews and per-Space controls
in one native macOS resident.

| Guide | Contents |
|---|---|
| [Installation](installation.md) | Package installation, permissions, update and removal |
| [Usage and shortcuts](usage.md) | Focus, move, resize, Space toggle and recovery |
| [Configuration](configuration.md) | Border colors, settings and paths |
| [Troubleshooting](troubleshooting.md) | Readiness, permissions, constraints and recovery |
| [Privacy](privacy.md) | Local data, permissions and safe diagnostics |
| [Development](development.md) | Source map, builds, tests and contribution checks |
| [Release preparation](releasing.md) | Versioning, clean exports and distribution checks |
| [Release notes](release-notes.md) | 1.0.1 changes, the 1.0.0 baseline and limitations |

Implementation contracts describe invariants rather than installation steps:

| Contract | Scope |
|---|---|
| [Product surface](contracts/retained-ux-contract.md) | Version 1 capabilities and contract map |
| [Core window manager](contracts/core-window-manager-spec.md) | Authority, identity, effects and geometry |
| [Move mode](contracts/move-mode-spec.md) | Cursor, edge selection and exact preview/commit |
| [Mode FSM](contracts/mode-fsm-spec.md) | Keyboard admission and transition rules |
| [Spatial navigation](contracts/spatial-nav-algorithm-spec.md) | Deterministic directional ranking |
| [Reclaim policy](contracts/reclaim-policy.md) | Removal, conservation and close refocus |
| [Desktop Spaces](desktop-space-autotile.md) | Per-Space activation and visible-context relocation |
| [Focus and borders](focus-domain.md) | Confirmed focus and immutable decoration |
| [Model and layout](model-layout-correspondence.md) | Planned, observed and visible state boundaries |
| [Responsiveness](contracts/event-driven-responsiveness.md) | Event scheduling and measurement requirements |
| [Recovery](contracts/resident-recovery-spec.md) | Independent launchd controls |

[Native architecture](architecture/leylined-core.md) maps the current process and modules.
