# Mode FSM and keyboard admission

`LeylineModel/ModeFSM.swift` evaluates pure transitions. The resident input router
owns active mode and claim generation; its one keyboard event tap owns capture.
The production modes are default, move and resize. Their declarative sources are
`keymap/global.json`, `keymap/modes.json` and the frozen physical US decode table.
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
fresh generation. Late action completion cannot re-enter an invalidated mode.
Admission retains the original input receipt, generation and target context.
Entry/exit shortcut key-up consumes the held identity without dispatching a second
or inverse action. Move cancellation is further constrained by [move mode](move-mode-spec.md).

Ordinary window chords require trustworthy managed eligibility in an enabled
visible Space. Hyper + A has the distinct focused-Space control route: it remains
available in default/move/resize on an identified OFF or empty Space while global
management and observation are available. One press toggles once, and stale queued
input cannot control a newly focused Space. Global OFF, unknown identity, lost
observation or session safety release all management claims.

Independent callback, run-loop, authority and action watchdogs can release capture
without waiting for blocked dispatch or AppKit. The release ceiling is 250 ms.
See [responsiveness](event-driven-responsiveness.md) for evidence requirements.

Native checks cover routing, claim inventory, key-up, stale completion, bounded
queues and independent fault release. Frozen predicate and transition fixtures are
regression inputs; verb strings inside test fixtures are not executable commands.
`ley validate keymap` checks actual native routes against a nonempty independent
inventory. A missing binary or fixture cannot yield a passing check.
