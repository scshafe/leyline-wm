# Mode FSM and keyboard admission

`LeylineModel/ModeFSM.swift` evaluates pure transitions. The resident input router
owns active mode and claim generation; its one keyboard event tap owns capture.
The production modes are default, move and resize. Their declarative sources are
`keymap/global.json`, `keymap/modes.json` and the fixed physical US decode table,
which covers exactly the bound keys; the loader refuses a chord it cannot decode.
Decode does not consult changing live layout sources; pure modifiers pass through.

The `modes/v1` loader rejects malformed schema and unknown completion predicates.
The pure evaluator recognizes these predicates:

| Predicate | Exit condition |
|---|---|
| `exit_on_rc0` | Result code is 0 |
| `exit_unless_rc_in_1_3` | Result code is neither 1 nor 3 |
| `exit_on_any_nonzero` | Result code is nonzero |
| `unconditional_exit` | Always |
| `no_exit` | Only the universal stale guard |

A stale result code 4 forces default before the ordinary predicate. Direct exits
release mode locally; a partial cancel can restore its previous mode only with a
fresh generation. Late action completion cannot re-enter an invalidated mode, and
a finished frame effect whose plan neither held nor ended an interaction cannot
change the mode: a layout pass that finishes after a mode was entered leaves it
entered. A failed frame effect still returns to default.
Admission retains the original input receipt, generation and target context.
Entry/exit shortcut key-up consumes the held identity without dispatching a second
or inverse action. A claimed key stays with the tap until its key-up: its autorepeat
routes only as the same directional focus, resize nudge or cursor step, and is
otherwise swallowed, so holding an entry or exit key acts once and a held key cannot
reach the application as text after its mode ends. A released tap claims nothing. Move cancellation is further constrained by [move mode](move-mode-spec.md).

Ordinary window chords require trustworthy managed eligibility in an enabled
visible Space. Directional focus alone has a wider route: it stays claimable while
no managed window holds focus, provided a managed window stands on an identified
enabled visible Space and the focused window, if any, is itself on an enabled
visible Space. Its first press lands on the [navigation anchor](../focus-domain.md)
and restores ordinary eligibility. Move and resize entry keep requiring managed
focus. A focused window on an OFF, hidden or unidentified Space, a full-screen
Space included, keeps every ordinary chord with its application.

Hyper + A has the distinct focused-Space control route: it remains
available in default/move/resize on an identified OFF or empty Space while global
management and observation are available. One press toggles once, and stale queued
input cannot control a newly focused Space. Global OFF, unknown identity, lost
observation or session safety release all management claims.

A tap whose registered events lack key-down or key-up, as when Input Monitoring is
not granted to this build, is a failed start, not an installed tap.

Independent callback, run-loop, authority and action watchdogs can release capture
without waiting for blocked dispatch or AppKit. The release ceiling is 250 ms.
See [responsiveness](event-driven-responsiveness.md) for evidence requirements.

Native checks cover routing, claim inventory, key-up, stale completion, bounded
queues and independent fault release. Frozen predicate and transition fixtures are
regression inputs; verb strings inside test fixtures are not executable commands.
The claims suite checks the actual loaded routes against the independent v1 route
contract. A missing binary or fixture cannot yield a passing check.
