# Configuration

User data lives under `~/.config/leyline`. Package updates preserve it. Installation
creates `config/borders.json` (default palette) and `config/leylined-settings.json`
(management ON, no per-Space choices) only when they are absent; keymaps and other
resources stay in the installed package.

| Path relative to the user-data root | Purpose |
|---|---|
| `config/borders.json` | Border corner radius and role colors |
| `config/leylined-settings.json` | Global desired ON/OFF and per-Space choices |
| `state/leylined/journal.jsonl` | Authoritative layout checkpoints and effect evidence |
| `runtime/` | Local socket and resident logs |

## Border width and spacing

Borders are fixed at **1 point**. This controls the outside stroke, the display-edge
allowance and the shared buffer between neighbouring tiled windows. A neighbouring
pair shares one width rather than reserving two widths. Nested regions do not add
a second gap. Window edges are rounded together so the final tile and border reach
the display edge.

Leyline fills each display below the menu bar/notch through the bottom and side
edges. A visible Dock may overlay windows; Leyline does not reserve a Dock strip or
change Dock preferences. Turning management OFF removes its borders.

To adjust corner rounding or role colors, create or edit
`~/.config/leyline/config/borders.json`:

```json
{
  "border_radius": 12,
  "colors": {
    "focus": "0xff39ff14",
    "resizing": "0xffff8c00",
    "moved": "0xff2962ff",
    "move_to": "0xffff5fa2",
    "drop_edge": "0xffffd400"
  }
}
```

`border_radius` (0–512) controls corner rounding. Colors use `0xAARRGGBB`; a
missing or malformed color uses its default. An unparseable file, a non-object, a
file over 64 KiB or an out-of-range radius blocks readiness until corrected. File
replacement is observed while running. Border width and spacing have no override;
a `width` key from an earlier build, or `global_gutter_width` in the settings file,
is ignored.

## Management preferences

Prefer the menu and Hyper + A to edit ON/OFF state. The settings file uses schema
`leyline/resident-settings/v1`, with `desired_running` and `spaces_enabled`.
Space keys are observed macOS
UUID identities; never substitute display numbers or a guessed Space index.

Malformed or unreadable settings block readiness. They do not silently enable
management. OFF Space layouts remain stored and reconcile against fresh windows
when re-enabled. Do not delete the journal while the resident is running.

## Keymap and development paths

Package resources include `keymap/global.json`, `keymap/modes.json` and `keymap/decode-us.json`. They define the supported native routes. The installed
package is not a general command registry or keyboard remapper; use the documented
shortcuts and optional external Caps Lock mapping.

Developer and isolated-test roots can be selected with `LEYLINE_HOME` (resource
root), `LEYLINE_ROOT` (user-data root), `LEYLINE_CONFIG_DIR` (configuration directory)
and `LEYLINE_RUNTIME_DIR` (socket/log directory); `LEYLINE_CORE_SOCKET` points the
CLI client at another socket. Use absolute paths. See
[development](development.md) before changing process roots or signing identities.
