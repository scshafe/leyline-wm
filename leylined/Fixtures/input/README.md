# Input route regression evidence

`v1-claims.json` pins current chord/action routes for default, move and resize.
The installed `leylined --dump-claims MODE --json` derives its inventory from
actual configuration without starting an input tap. Unknown modes claim nothing.

`claims.json` and `space-toggle-claims.json` preserve independent historical
reference bytes used by the developer suite. Their comparison verifies the
current navigation, restart, move, resize and Hyper+A Space toggle. Retired
provider, capture and unimplemented top-execution routes are absent from the
shipping keymaps. There is no shipping text capture mode.

Mutation checks remove supported routes or explicitly add a retired route to a
test configuration; the independent current route oracle must reject each
change. These checks measure configuration behavior, not live input latency.
