# Usage and shortcuts

Leyline automatically tiles eligible, resizable windows in enabled visible desktop
Spaces. New Spaces default to ON. Open **Leyline** in the macOS menu bar to see
readiness, select a managed window, change border width or stop management.

**Hyper** means Command + Control + Option + Shift. If you map Caps Lock to Hyper
with your preferred keyboard remapper, the shortcuts below become Caps Lock + key.
Leyline does not remap Caps Lock itself. Keyboard decoding follows physical US key
positions; see [configuration](configuration.md) for the checked-in keymap.

| Shortcut | Action |
|---|---|
| Hyper + A | Toggle management for the focused Space |
| Hyper + H / J / K / L | Focus left / down / up / right |
| Hyper + R | Enter resize mode; press again to exit |
| Hyper + M | Enter move mode; press again to exit |
| Control + Option + R | Restart management through the resident |

Hyper + A works on an identified OFF Space to turn it back ON. Turning a Space OFF
removes its management borders and leaves its window frames in place. Its ordinary
window shortcuts pass through; other enabled Spaces remain managed. A global
**Stop Leyline** releases all management shortcuts while retaining the menu.

## Resize

Enter with Hyper + R, release the modifiers, then press H / J / K / L to move a
shared boundary by 40 points. Adjacent windows resize together. At a display wall,
Leyline adjusts the opposite interior boundary. Known application minimum sizes
limit movement. Escape exits; completed resize steps remain applied.

## Move

Enter with Hyper + M. The focused managed window remains the source even if
ordinary focus changes. Windows stay still while you choose the destination;
solid rings show the source and cursor, and dashed outlines show the planned result.

| Key in move mode | Action |
|---|---|
| H / J / K / L | Move the cursor; with an edge staged, walk its finite run |
| S or Return, without a staged edge | Swap with the cursor window |
| D | Stage an insertion edge; press again to confirm |
| C | Rotate the staged edge |
| U | Widen edge → contiguous run → owning parent |
| I | Restore the preceding narrower selection |
| Return, with an edge staged | Commit the displayed insertion |
| Escape | Unstage an edge; press again to exit |
| Hyper + M | Exit immediately |

A successful swap or insertion exits move mode. A changed source, Space, display
or stale preview can cancel the interaction; a replacement preview requires fresh
confirmation. Cross-display moves require both desktop Spaces to be concurrently
visible and enabled. Leyline cannot move windows into inactive Spaces.

### Example: two terminals above a browser

Start with two terminals stacked on the left and a browser filling the right:

1. Focus the browser, enter move mode and release the modifiers. Press H, J to
   select the lower terminal, then D, C, U, U. Check that the preview puts the
   browser across the bottom, then press Return.
2. Focus the lower terminal above the browser and enter move mode again. Press
   K to select the upper terminal, then D, C, C. Check that the preview places
   the source to its right, then press Return.

The terminals now share the top row and the browser spans the bottom. This
sequence assumes the stated starting layout; use the cursor and preview to
choose the corresponding windows when your layout differs.

## Menus and recovery

The **Windows** submenu includes every managed window on the captured Space,
including a window obscured by crowding. Selecting one reveals and focuses it.
**Border width** changes border thickness and tile spacing together. **Use
configured border width** restores the value in the border configuration file.

**Start**, **Stop** and **Restart Leyline** control management without removing its
launchd job. **Hard reset** quarantines the layout journal and rebuilds from fresh
observation. Use [troubleshooting](troubleshooting.md) before resetting.

If the resident or menu is unresponsive, open **Leyline Recovery.app** in Finder.
**Bounce** restarts the resident job, **Disable** removes it from the current login
session, and **Re-enable** restores it. Recovery preserves configuration and
journals and works without Accessibility or Input Monitoring.
