# Leyline

Leyline 1.0.1 is a native macOS tiling window manager. One resident manages window
layout, keyboard shortcuts, borders, move previews and menu controls. An independent
Recovery app remains available when the resident is unresponsive.

- Automatic tiling with directional focus, shared-boundary resize and previewed moves.
- Independent ON/OFF state for each desktop Space, toggled with **Hyper + A**.
- Fixed **1-point** borders with configurable colors, one shared gap between
  neighbours, and just enough room at display edges.
- A menu-bar icon per focused Space: empty when OFF, green when ON, red on errors.
- Full display coverage below the menu bar/notch, including the Dock area.
- Local configuration and layout state, with no account or network service.

**Hyper** means Command + Control + Option + Shift. Mapping Caps Lock to Hyper is
optional and handled by your keyboard remapper; Leyline does not remap it itself.

## Install

Requires macOS 14 or later. Install from the [Homebrew tap](https://github.com/scshafe/homebrew-tap):

```sh
brew install scshafe/tap/leyline
ley install --start
```

Source installation needs Swift 6 or newer from Xcode Command Line Tools. Homebrew
builds Leyline and Recovery and supplies optional CLI diagnostic dependencies.

Or download the universal app archive from the [1.0.1 release](https://github.com/scshafe/leyline-wm/releases/tag/v1.0.1).
It contains Apple silicon and Intel binaries. Extract it, then run:

```sh
./install.sh
```

This installs **Leyline.app**, **Leyline Recovery.app** and a `ley` command for your
user account. It installs the login job without starting management. Open the
installed Leyline app to start it, grant **Accessibility** and **Input Monitoring**
to the resident in System Settings → Privacy & Security, then choose **Restart
Leyline** from its menu. To start during installation, use `./install.sh --start`.

A downloaded archive's signing/notarization status matters to macOS Gatekeeper.
The prepared 1.0.1 app archive is ad-hoc signed and has not been notarized. Read
[installation](docs/installation.md) for permissions, updates and signing details.

Both installation paths preserve existing preferences and journals. See the
[release](https://github.com/scshafe/leyline-wm/releases/tag/v1.0.1) for checksums,
source and the app archive's actual signing status.

## Use

| Shortcut | Action |
|---|---|
| Hyper + A | Toggle the focused Space, including turning an OFF Space back ON |
| Hyper + H / J / K / L | Focus left / down / up / right |
| Hyper + R, then H / J / K / L | Resize; Escape exits |
| Hyper + M | Move with exact destination previews; Return commits |

Click the Leyline icon in the menu bar to select a window or control
management. Use **Leyline Recovery.app** in Finder if the resident or menu stops
responding. See [usage](docs/usage.md), [configuration](docs/configuration.md) and
[troubleshooting](docs/troubleshooting.md).

Leyline manages eligible resizable windows in enabled visible ordinary desktop
Spaces. Fullscreen/system Spaces and inactive-Space transfer are unsupported.
Application minimum sizes may move split lines, make a window overlap the one it
was split from, cause crowding or produce an explicit refusal. Keyboard decode
uses physical US key positions. Version 1 does not claim measured physical latency
or compatibility certification for every Mac/application. See [release notes](docs/release-notes.md).

For contributors, start with [development](docs/development.md),
[the architecture](docs/architecture/leylined-core.md) and
[the documentation index](docs/README.md).

Released under the [MIT License](LICENSE).
