# Resident effector fixtures

`resize_burst.json` is the expected accumulated resize state while an effect is
in flight. Four +10 width requests issue the first +10 state and the final +40
state; superseded intermediate desired states do not actuate.

`leylined self-test effector` drives the production `CommandScheduling`,
`ResidentEffector`, `ResidentEffectorFileJournal` and `ResidentPlanner` with
controllable journal/AX ports. It verifies journal-before-effect, durable commit
markers, refused/abandoned intent recovery, same-epoch request replay, bounded
worker admission, targeted per-window/focus evidence and native planning behavior.
Injected observation verifies semantic AX state, not physical visibility.

Cancellation tests distinguish untouched pending intent (`refused`) from a
committed desired model or issued/partially observed AX effect (`failed`). The
terminal result retains accumulated requested frames, only observed landed
frames and the desired model's committed revision. Reentrant cancellation from
the commit callback resolves once after its return, without holding the state
lock or claiming that committed state stayed unchanged.

Every journal error also invokes the separate persistence fault callback. A
commit-marker failure after cancellation still fences storage availability,
without publishing a second terminal command result; callback reentrancy is
exercised outside the state lock.

The native planner refuses unsupported nested or minimum-infeasible insertion
shapes honestly. A trustworthy complete resident world, independent display/Space
eligibility and real external evidence remain prerequisites to live certification.
