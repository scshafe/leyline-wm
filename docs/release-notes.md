# Leyline 1.0.0

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

## Supported scope and limitations

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
