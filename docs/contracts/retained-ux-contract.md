# Version 1 product surface

The user-facing guide is [usage and shortcuts](../usage.md). This table maps each
version 1 capability to its implementation contract.

| Capability | Contract |
|---|---|
| Automatic adoption, insertion and constrained crowding | [Core window manager](core-window-manager-spec.md) |
| Directional focus across visible displays | [Spatial navigation](spatial-nav-algorithm-spec.md) |
| Shared-boundary resize with accumulated nudges | [Core window manager](core-window-manager-spec.md) |
| Cursor, swap, edge/span insertion and exact ghosts | [Move mode](move-mode-spec.md) |
| Keyboard capture and stale-mode release | [Mode FSM](mode-fsm-spec.md) |
| Space ON/OFF, Hyper + A and global lifecycle | [Desktop Spaces](../desktop-space-autotile.md) |
| Close refocus and member conservation | [Reclaim](reclaim-policy.md) |
| Role-colored borders and immutable previews | [Focus and borders](../focus-domain.md) |
| Windows menu access to obscured managed members | [Core window manager](core-window-manager-spec.md) |
| Configurable shared/outer border spacing | [Configuration](../configuration.md) |
| Finder recovery and launchd controls | [Recovery](resident-recovery-spec.md) |

The public result vocabulary is accepted/noop/refused/failed. Refusal makes no
mutation; failure preserves genuine effect outcomes and the committed checkpoint.
No product decision remains open in this feature baseline. Physical responsiveness
and system compatibility are separate [measurement requirements](event-driven-responsiveness.md).

Inactive-Space transfer, discretionary floating, manual stacking, direct
move/tuck/promote/demote commands, clipboard history, widgets, generic pickers and
an alternate resident stack are not version 1 features.
