# Installation

Leyline requires macOS 14 or later and a logged-in graphical user session. Native
universal app archive contains Apple silicon (`arm64`) and Intel (`x86_64`) slices
for both Leyline and Recovery. Automated native and package checks run on Apple
Silicon and Intel macOS runners; live Intel desktop integration remains untested.
A downloaded native package needs no Python, Swift compiler or Xcode tools.
Optional `ley doctor` and keymap-validation commands require `jq`; native health
queries and the app/Recovery/installer do not.

## Native archive

Extract the versioned archive containing `Leyline.app`, `Leyline Recovery.app`
and `install.sh`, then run in the extracted directory:

```sh
./install.sh
```

Defaults are `~/Applications` for both apps and `~/.local/bin/ley` for the CLI.
Add `~/.local/bin` to your shell's PATH if needed. Installation writes the
`org.leyline.leylined` LaunchAgent without starting management. Open the installed
Leyline app to start it, or explicitly request start during installation:

```sh
./install.sh --start
```

`--application-dir` and `--bin-dir` select different destinations; `--no-start`
keeps the job stopped. Existing apps require the explicit `--update` option.
Run `./install.sh --help` for the exact interface. Choose
final app locations before granting permissions. If installing manually, move both
apps into their final directory before opening Leyline; its launcher installs and
starts the direct resident job.

## Permissions and first start

The resident needs **Accessibility** to observe/move/focus windows and **Input
Monitoring** for management shortcuts. Grant the installed resident identity in
System Settings → Privacy & Security. Permission for a terminal or compiler alone
is insufficient. Restart Leyline after changing grants and inspect its menu status
or `ley doctor`. Do not enable management until it reports current observation and
input readiness.

Leyline Recovery requests neither permission. Open it in Finder to Bounce, Disable
or Re-enable the resident independently of its socket. Local settings live under
`~/.config/leyline`; installation does not replace existing preferences or journals.

## Updates and removal

Install the new archive into the same locations with an explicit update:

```sh
./install.sh --update --start
```

For a Homebrew/package installation, `ley install --update --start` copies the
packaged apps and updates the service. An installed app's `ley install` delegates
to the native installer when no outer archive install script remains.
The native launchd interface supports direct management of the installed app:

```sh
ley setup launchd install --no-start
ley setup launchd install --start
ley setup launchd install --update --start
ley setup launchd uninstall --plan
ley setup launchd uninstall
```

Uninstall stops and removes Leyline's LaunchAgent. It preserves user configuration
and journals. App and CLI files can then be removed from their installed locations.
Do not delete user state while a resident is still running. A changed signing
identity may require granting permissions again.

## Homebrew and source installation

The [Homebrew tap](https://github.com/scshafe/homebrew-tap) builds Leyline and Recovery,
installs their immutable bundles in its package prefix and provides `ley`:

```sh
brew install scshafe/tap/leyline
ley install --start
```

`ley install` copies both apps to `~/Applications` and installs the per-user job.
It preserves settings/journals. Use `--no-start` to prepare without starting.
The formula supplies `jq`. Source builds use Swift 6 or newer and the Python 3
interpreter supplied by Xcode Command Line Tools; a full Xcode application is not
required. Developer checks also need Python 3.
See [development](development.md) for isolated test profiles.

Versioned source, universal app archives and checksums are available in the
[GitHub release](https://github.com/scshafe/leyline-wm/releases/tag/v1.0.0).

## Signing and Gatekeeper

The prepared 1.0.0 universal app is **ad-hoc signed and unnotarized**. Local
Homebrew/source builds are also ad-hoc signed. These signatures do not establish
Developer ID signing or notarization. Do not treat an archive
checksum as Gatekeeper approval. Normal direct distribution uses a Developer ID
signing identity and Apple's notarization workflow. Such a signature exposes the
certificate's publisher identity; anonymizing source cannot remove that identity
while preserving a valid signature. See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/)
and [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Check the release's stated signing status. If macOS refuses a download, use
[Apple's guidance on safely opening apps](https://support.apple.com/102445) and verify
its origin rather than disabling platform protection. Publishing credentials and
notarization are separate from preparing the anonymous source and local packages.
