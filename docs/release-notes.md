# Release notes

## 1.0.1

Changes since 1.0.0:

- Borders are fixed at 1 point; the border-width setting and its menu override are
  removed. An existing `width` or `global_gutter_width` key is ignored.
- The menu-bar icon reflects the focused Space: empty when OFF, green when ON and
  red when an error needs attention.
- Move previews show the insertion side and destination; an edge that cannot fit
  shows **WON'T FIT** and keeps move mode active.
- Directional focus keeps working after recovery renews window identities.
- Fixed: Hyper + A never fired because the US decode table lacked the A key.
- Fixed: new installs seeded border colors in a shape the renderer ignored, and
  the Windows menu did not show application names.
- A window whose minimum size exceeds its tile gets room by moving split lines,
  inner splits before the main split. When no cut fits every known minimum, the
  lines that can still move do and the window overlaps the window it was split
  from, keeping its unshared edges, or, when that cannot hold it, its neighbours,
  instead of collapsing the display into one stack. Only a minimum larger than the
  display still stacks. Leyline learns the minimum of a window that refuses any shrink.
- Fixed: directional focus skipped a window that overlapped the focused one.
- Fixed: an app with enhanced accessibility enabled could ignore window moves.
- Fixed: resizing one half of a split line could swap the windows below it.
- Fixed: Leyline stopped at startup ("Recovery needed") when an app refused to
  shrink to its tile; that confirmed shortfall now counts as a completed start.
- Fixed: after an app quit or launched, Hyper + M and Hyper + R could refuse
  until another window opened. A layout pass that loses a commit race is now
  replanned, and a refused command schedules the owed repair.
- Fixed: an app launching or quitting could undo window moves by re-tiling the
  Space in window-ID order. A window of the same app that still covers its tile
  keeps it when Leyline renews window identities.
- Fixed: a window already at its minimum size could fail to have that minimum
  learned when its other side was one point short, turning the menu-bar icon red.
- Fixed: moving a window to another Space in Mission Control left its old Space
  untiled until you switched away and back. Leyline now re-tiles that Space when
  the window server reports the move.
- Fixed: Leyline could stop at startup ("Recovery needed") when an app settled
  one point from its tile, such as a 960-point minimum width asked for 959.
- Move mode's U now widens up to the whole display, so one move turns two windows
  over one into one window beside two, and back.
- Fixed: after some moves, closing a window or the next layout pass could fail
  and turn the menu-bar icon red, because a split line was stored as overlapping
  pieces. Existing layouts with such lines recover.
- Fixed: a running app that macOS lists without a process (Xcode's Device Hub
  can stay that way for hours) stopped all tiling with "world observation
  incomplete" on every Space.
- Windows with a fixed aspect ratio, such as the iOS Simulator's device window,
  stay untiled. Leyline learns the application the first time a window refuses
  its tile's shape, instead of stopping at startup ("Recovery needed").
- Removed CLI commands: `ley perf` (the resident publishes no distributions),
  `ley validate`, the top-level `ley trace` (use `ley resident trace`) and
  `ley ctl recovery` (use Leyline Recovery.app).

## 1.0.0

Version 1.0.0 is the official initial feature baseline.

- One native resident owns management, keyboard input, observation, journaled
  effects, borders, previews, settings and menu controls.
- Automatic largest-cell tiling, fixed even reclaim and application minimum-size
  handling preserve managed members, including constrained crowding.
- Directional focus spans visible displays; resize moves shared boundaries;
  move mode previews exact swap and edge/span insertion targets.
- Hyper + A toggles the focused desktop Space and can re-enable an OFF Space.
  ON/OFF preferences persist per identified Space.
- Borders default to 1 point. Their width controls full display-edge allowance
  and one shared gap. Tiles fill below menu/notch space through the bottom edge.
- The Windows menu reveals every managed member, including obscured windows.
- Independent Finder recovery can restart, disable or re-enable the resident.
- Universal app packages include `arm64` and `x86_64` slices for Leyline and Recovery.
- App installation and the Homebrew source recipe preserve local settings.
- Public source starts with one fresh baseline commit and tag `v1.0.0`, using
  generic contributor metadata and excluding private development history.
- The public project and Homebrew tap use the publisher's chosen GitHub account.
  Public ownership is disclosed; private paths, user state and credentials are excluded.
- The project and packaged resources use the [MIT License](../LICENSE).

### Supported scope and limitations

macOS 14 or later is required. Universal binary slices, automated native suites
and package installation are checked on Apple Silicon and Intel macOS runners.
Live Intel desktop integration remains untested. Keyboard decode uses physical
US key positions. Hyper is Command+Control+Option+Shift; optional Caps Lock mapping
is external.

Management applies to eligible resizable windows in enabled, concurrently visible
ordinary desktop Spaces. Fullscreen/system Spaces, inactive-Space transfers and
programmatic OS Space changes are unsupported. Space identity/observation failure
releases management instead of guessing membership. Application AX behavior and
minimum sizes can constrain or refuse a requested layout. A visible Dock may
overlay tiled windows.

Automated suites establish their model, protocol and recovery boundaries. Version
1.0.0 does not claim physical-keyboard latency, scanout, cross-login Space identity
or induced-wedge recovery certification across every hardware/application scene.
Engineering budgets are documented in [responsiveness](contracts/event-driven-responsiveness.md).
The prepared universal app archive is **ad-hoc signed and unnotarized**. It is not
a Developer ID release. Install through the [Homebrew tap](https://github.com/scshafe/homebrew-tap)
or download the archive and matching checksums from the
[release](https://github.com/scshafe/leyline-wm/releases/tag/v1.0.0).
