# Move-mode contract

Move mode places one managed window by cursoring, swapping, inserting at an edge
or inserting across a contiguous span. [Usage](../usage.md) lists the controls;
this contract defines their geometry and authority.

## Entry and cursor

Entry captures the focused managed source, its origin frame, identities and
revision atomically. It requires complete reconciled observation in an enabled
visible Space and a legal useful destination. A trustworthy source with no useful
destination refuses with “Nothing to move to”; incomplete identity or convergence
reports unavailability. Entry never adopts ignored windows or enables an OFF Space.

The cursor initially selects the source. H/J/K/L cursoring uses the same stitched
surface, direct-then-wrap ranker as focus navigation. Ordinary focus changes do not
retarget the source. Overload cells present their selected top. Cosmetic gaps and
empty slots are not cursor destinations. Windows remain physically stationary
until commit.

## Swap and edge selection

Without a staged edge, S or Return swaps with the cursor. D stages an insertion
edge; Return or a second D confirms that insertion. C rotates north → east → south
→ west and resets selection to the cursor's single edge.

The first edge compares the log aspect distances of width-halved and height-halved
target cells to the destination display. Ties choose width-halving. The selected
half is nearest the captured source center; center ties choose west/north.

With an edge staged, H/J/K/L walks its finite collinear run in geometric order.
Perpendicular movement and walking beyond an endpoint are no-ops. Edge scope selects
one edge; run/parent scope moves the cursor without enlarging the displayed scope.
U explicitly widens edge → complete contiguous run → actual owning parent, one
ancestor per press. I restores the recorded preceding selection, including its
anchor and ordered members. The root has no wider parent.

A gap, corner-only contact, changed coordinate, opposite side, excluded/OFF member
or display seam terminates a run. Resolve a child's outer edge to the parent-owned
boundary. Never infer parenthood from all cells sharing a coordinate. Participants
are ordered by perpendicular coordinate, then stable identity after simulating
source vacancy; the source is never inserted twice.

## Allocation and preview

The planner first simulates source removal and owner-local reclaim. The anchor
cell midpoint proposes a common cut. Clamp it to the nearest position where the
source and every surviving participant satisfy known minima, counting spacing
once. Equal-distance ties choose the lower coordinate. An empty shared feasible
interval refuses without mutation.

Existing participants retain perpendicular order and far-side geometry. Unrelated
boundaries remain unchanged except explicit source reclaim. Nested owners compose
through parent frames and child minima rather than flattening their identities.
A span stays inside one display owner. Swap/insert can cross concurrently visible
identifiable enabled display-local Spaces; inactive-Space transfer is unsupported.

Solid source/cursor rings and the selection boundary show intent. Dashed ghosts
show every affected destination frame, including reclaim. One immutable candidate
carries the arrangement, rounded targets, ordered participants, selection scope and
base provenance. Preview never authors layout. Commit consumes this exact candidate
rather than independently calculating another arrangement.

## Commit, cancel and invalidation

Modifier release does not commit or exit. Successful swap or insertion consumes
the interaction and exits move mode. Queued repetitions and late acknowledgments
cannot produce a second mutation or revive the mode.

Escape unstages an edge and stays in cursoring; Escape while cursoring exits.
Hyper + M exits unconditionally. Cancel discards intent with zero layout mutation.
A refusal clears staged promises and reports a reason. A stale interaction exits
and reports unavailability; it cannot retain an apparently valid ghost.

A cursor-only vanished target may choose the next ranked eligible candidate.
A missing source always cancels. A staged interaction permits at most one
rederivation only if operation, source, boundary owner/edge and ordered participant
identities preserve the same intent. A replacement preview needs fresh confirmation.
Changed Space, topology, session or trust invalidates the interaction. Trust loss
also releases input claims independently of blocked dispatch.

Tests cover empty/unavailable entry, no useful target, two-window swaps, nested
owners, infeasible minima, source-within-span conservation, repeat/cancel ordering,
stale candidates and partial external effects. These test boundaries do not assert
physical preview timing; see [responsiveness](event-driven-responsiveness.md).
