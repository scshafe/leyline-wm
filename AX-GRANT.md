# macOS permissions

The `leylined` resident requires Accessibility and Input Monitoring. Grant them to
the installed resident, then restart Leyline and inspect `ley doctor`. The
independent Leyline Recovery app requires neither permission.

See [installation and permissions](docs/installation.md) and
[developer signing](docs/instructions/local-signing-cert.md). A new signing
identity may require new grants; permission attributed to a terminal or build
process does not prove that the resident is trusted.
