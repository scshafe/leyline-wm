# Configuration

User data lives under `~/.config/leyline`. Package updates preserve it. Application
resources and defaults belong to the installed package rather than this directory.

| Path relative to the user-data root | Purpose |
|---|---|
| `config/borders.json` | Base border width, corner radius and role colors |
| `config/leylined-settings.json` | Global desired ON/OFF, per-Space choices and menu width override |
| `state/leylined/journal.jsonl` | Authoritative layout checkpoints and effect evidence |
| `runtime/` | Local socket and resident logs |

## Border width and spacing

The default is **1 point**. One value controls the outside stroke, the display-edge
allowance and the shared buffer between neighbouring tiled windows. A neighbouring
pair shares one width rather than reserving two widths. Nested regions do not add
a second gap. Window edges are rounded together so the final tile and border reach
the display edge.

Leyline fills each display below the menu bar/notch through the bottom and side
edges. A visible Dock may overlay windows; Leyline does not reserve a Dock strip or
change Dock preferences. Width `0` disables borders and spacing together.

Use the **Border width** menu for a saved global override. To set an exact base
value, create or edit `~/.config/leyline/config/borders.json`:

```json
{
  "width": 1,
  "border_radius": 12,
  "colors": {
    "focus": "0xff39ff14",
    "resizing": "0xffff8c00",
    "moved": "0xff2962ff",
    "move_to": "0xffff5fa2",
    "drop_edge": "0xffffd400",
    "stacked": "0xff00d7d7"
  }
}
```

`width` must be an integer from 0 through 512, measured in macOS coordinate points.
`border_radius` controls corner rounding. Colors use `0xAARRGGBB`. Missing values
use package defaults; malformed geometry reports unavailability. Select **Use
configured border width** if a saved menu override is masking your file value.
File replacement is observed while running and valid width changes reflow tiles.

## Management preferences

Prefer the menu and Hyper + A to edit ON/OFF state. The settings file uses schema
`leyline/resident-settings/v1`, with `desired_running`, `spaces_enabled` and optional
`global_gutter_width`. Despite its wire name, `global_gutter_width` is the one border
width override, including stroke and outer spacing. Space keys are observed macOS
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
and `LEYLINE_RUNTIME_DIR` (socket/log directory). Use absolute paths. See
[development](development.md) before changing process roots or signing identities.
