# Leyline development context

Leyline 1.0.0 is a native macOS window manager. Begin with [README.md](README.md),
[the development guide](docs/development.md) and [the runtime map](docs/architecture/leylined-core.md).

One `leylined` resident owns input, observation, planning, journaled effects,
settings, borders, previews and menu controls. The independent Finder Recovery
app controls its launchd job without using the resident socket. Public identifiers
use `org.leyline`; the release version has one canonical source.

Add behavior to the existing Controller → Planner → Effector → model path.
Preserve identity/lifetime/Space fences, immutable revision-bound presentation,
exact preview/commit targets and honest accepted/noop/refused/failed outcomes.
Partial observation cannot authorize an empty layout. No external script or
renderer may become a second author of window state.

Run `bin/ley test all` after a complete build. Targeted checks are `native`,
`oracles`, `cli`, `recovery`, and `acceptance-tools`. Missing tools, fixtures or
grants are failures. Automated fixtures do not certify physical input, visible
latency, Space persistence across login or recovery timing.

Keep production/test build boundaries explicit. Do not edit shared Swift sources
while another build is using them. Preserve local configuration, journals,
signing identities and unrelated untracked files. Export public releases from
tracked source only, without private history, user state or build caches.
