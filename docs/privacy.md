# Privacy and local data

Leyline runs locally without an account, telemetry uploader, update service or
network listener. Its command transport is a Unix-domain socket under the local
user-data root. The resident observes application/window identities, frames, focus
and desktop Space membership to manage the current desktop.

Accessibility permits broad interaction with other applications. Input Monitoring
allows the resident event tap to see keyboard events. Leyline routes its declared
management chords; it is not a text/clipboard-history recorder. Recovery needs
neither grant and controls the one user LaunchAgent directly.

Settings, authoritative layout/effect journals, logs and bounded diagnostics live
under `~/.config/leyline`. They may contain local paths, process/application
metadata, window titles or identifiers, Space/display UUIDs and timing. They are
private operational data, not release assets. The Unix socket is user-scoped;
other software running as the same macOS user may reach the command interface.

No diagnostics are sent automatically. Before publishing a report, inspect and
redact it, including titles, paths and identifiers. A public source export excludes
user configuration/state, build caches, local handoffs, signing credentials and
private Git history. A Developer ID signature separately identifies its publisher.

Uninstall removes the LaunchAgent while preserving configuration and journals.
Remove local data deliberately only after the resident is stopped if you want to
remove retained settings/history. See [installation](installation.md).
