# Troubleshooting

Start with the menu's status and:

```sh
ley doctor
ley resident health
```

A registered launchd job or live PID alone does not prove current observation,
Accessibility trust or an active input tap.

| Symptom | Check |
|---|---|
| Shortcuts do nothing | Global management, focused Space ON/OFF, Accessibility/Input Monitoring grants, and actual Hyper modifiers |
| Caps Lock + key does nothing | Caps Lock must be mapped to Hyper externally; test Command+Control+Option+Shift + key |
| Space toggle unavailable | The resident needs complete trustworthy identity for the focused ordinary desktop Space |
| Border width file appears ignored | Select **Use configured border width** to remove the saved global menu override |
| A resize or move refuses | Application minima, stale observation, missing source/destination or an infeasible common cut |
| A window is hidden by crowding | Select it from the **Windows** submenu |
| A bottom/side Dock overlaps windows | Expected: the tiling canvas includes Dock space; choose your own Dock visibility preference |
| Saved state needs recovery | Inspect the diagnostic error; use a resident hard reset only when rebuilding state is intended |

## Recovery controls

**Stop Leyline** releases management while retaining the menu. **Restart Leyline**
restarts its capabilities against a fresh baseline. If the process or menu is
wedged, use Finder's **Leyline Recovery.app**. Bounce restarts the registered job;
Disable deregisters it for the login session; Re-enable restores it.

A soft reset preserves the authoritative journal. A hard reset quarantines it and
rebuilds after fresh observation. Preview maintenance through the CLI first:

```sh
ley ctl reset --dry-run
ley ctl reset --hard --dry-run
```

Apply only the reset you intend. The resident owns reset ordering; never clear its
journal by hand while it is active. Recovery failure reports the actual launchctl
or readiness problem rather than claiming a successful restart.

## Diagnostics and reports

`ley resident snapshot`, `ley perf` and `ley trace` inspect current state and bounded
local diagnostics. They can include window/app metadata, local paths, Space/display
identifiers and timing. Review and redact output before sharing it. Report macOS
version, architecture, affected applications, reproducible steps and the relevant
error code; do not post your complete user-data directory or signing credentials.

A failing automated test needs its exact source version, command and output.
Model fixtures, synthetic events and compositor samples do not prove a physical
keyboard path or scanout timing. See [privacy](privacy.md) and
[responsiveness requirements](contracts/event-driven-responsiveness.md).
