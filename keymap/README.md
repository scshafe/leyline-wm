# Keyboard resources

`decode-us.json` maps macOS keycodes to US chord tokens for exactly the bound
keys; the loader refuses any chord whose key it cannot decode.
`global.json` declares focus, resident restart and per-Space management shortcuts.
`modes.json` declares move and resize modes. The native loader owns precedence,
mode exit predicates and immutable claim tables.

These three files are shipped under the application resource home. Developer
checks compare current routes to independent regression evidence in
`leylined/Fixtures/input` and run without installing an input tap.
