# Input route regression evidence

`v1-claims.json` is the independent v1 route contract: the retained action set and
the exact chord-to-action routes for default, move and resize. The claims suite
loads the shipped keymaps without starting an input tap and compares every route.
Unknown and retired modes claim nothing; there is no shipping text capture mode.

Mutation checks remove supported routes or add a retired route to a test
configuration; the route contract must reject each change. These checks measure
configuration behavior, not live input latency.
