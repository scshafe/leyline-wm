# Core window-manager contract

Leyline 1.0.1 manages eligible tiled windows, borders, move previews and controls
in one native `leylined` resident. On-demand CLI clients and the independent
Finder Recovery app do not own layout authority.

## Authority and identity

One ordered Controller → Planner → Effector path authors window state. The pure
model imports no platform UI frameworks. Input, application/window notifications,
Space/display changes and configuration events supply observations; presentation
consumes immutable committed snapshots.

A window target is bound to PID, window number, lifetime generation, observation
epoch and Space/display context. Titles and application labels cannot establish
identity. Every request retains its admission receipt, request ID, generation and
target context. Stale completions cannot mutate newer authority or revive a mode.

A complete observed world is required before membership authoring. Missing or
partial observation is unavailable, never an empty desktop. Only identifiable,
enabled visible ordinary desktop Spaces receive current layout effects. Inactive
and OFF partitions retain their saved state without background authoring.

## Automatic layout

Every eligible window belongs exactly once to its Space partition, including
nested members and obscured overload members. Ineligible windows are ignored.
New windows are inserted into the largest available recursive cell, splitting its
longer dimension. Equal choices are deterministic. Ordinary insertion preserves
unrelated ownership and boundaries.

Known application minimum sizes compose upward through nested owners. A common
cut must satisfy the source and every surviving participant along the split axis;
a floor wider than the cell's other side is left to the re-cut or overlap below. If
automatic adoption cannot fit another independent tile, an overload leaf retains
all members at a shared footprint; the Windows menu makes each member selectable.

When a known minimum later exceeds a window's tile, lines move the least distance
that lets every known minimum fit, inner splits before the lines bounding their
parcel; the partition's structure and bindings stay. When no cut fits every known
minimum, the lines that can still move do and the rest stay. The window grows across
the cut that splits its own band (the cut no longer than the tile's side), keeping
the edges it does not share, so it overlaps only the windows that cut separates;
when that region cannot hold it, it grows from the display edges it touches over its
neighbours. Only a minimum larger than the display falls back to an overload leaf. Manual move or resize operations
never increase how far a window extends outside its tile; with no feasible cut they
refuse without changing the layout.

Close/minimize/removal reclaims only the affected owner using the fixed even
policy, subject to geometry, minima, pinned boundaries and conservation. Preserve
valid managed focus; otherwise prefer the eligible absorber, then the most recently
confirmed eligible survivor. See [reclaim](reclaim-policy.md).

## Geometry and borders

The border width is fixed at 1 point. This reserves 1 point at the display perimeter
and one shared point between adjacent windows. The active outside stroke fits that
shared buffer. Nested owners apply no additional spacing. OFF Spaces have no
management borders. Target origins and opposite edges are rounded together.

The tiling canvas covers the display below the menu bar/notch and includes the
Dock area; a visible Dock may overlay it. Border decoration derives current window
identity, frame, role and Space activation from the same committed revision.
Ignored, minimized, destroyed, stale and OFF windows receive no management border.

## Interactive operations

Directional focus ranks eligible presented windows across the stitched visible
display surface, direct before wrap, with deterministic ties. Success requires
confirmed target focus. See [spatial navigation](spatial-nav-algorithm-spec.md).

Resize moves a complete collinear shared boundary by 40 points per admitted nudge.
At a canvas wall it uses the opposite interior face with the same signed direction.
At most one effect and one accumulated desired-state intent are outstanding. Key-up
preserves already admitted displacement; Escape retains completed steps.

Move captures a managed source and a useful legal destination context. Cursor,
swap, single-edge insertion, contiguous-span insertion, commit and cancel share
one immutable candidate. The preview and commit use exactly its rounded target
frames, participant identities and base provenance. A changed base removes the
preview; at most one safe rederivation can publish a replacement requiring fresh
confirmation. See [move mode](move-mode-spec.md).

Hyper + A toggles only the captured focused Space and remains available there
while OFF, under complete trusted observation. A held chord toggles once. A queued
press cannot retarget a newly focused Space. Global OFF releases management input,
active observation, effects and overlays while keeping the resident menu available.

## Commit, effects and results

A journaled transition establishes the authoritative intended model. External AX
writes are bounded attempts, not proof of a landed frame or focus. Effect readback
must match the original lifetime/context and requested compound goal. Multi-window
writes are not physically simultaneous merely because their logical plan is atomic.
Partial effects retain their actual outcome and committed checkpoint.

Public results are `accepted`, `noop`, `refused` or `failed`. Refusal makes no
mutation. Failure identifies genuine unlanded effects rather than pretending to
roll back the world. Request replay is idempotent. Corrupt durable state blocks
authority; hard reset quarantines it through the resident maintenance owner.

A newly learned minimum requires actual per-axis shrink progress followed by a
separate later identical confirmation. Cached no-op values, early mismatch and
observation failures cannot teach a floor. A known-floor self-heal requires actual
successful writes and later exact-identity observations. At most one bounded
constraint replan follows the original failure.

A window that refuses its tile's shape through a refused identical rewrite,
staying above the target on one axis and below it on the other (a fixed aspect
ratio such as the iOS Simulator's device window), fails `fixed_aspect_constraint`
and adds its application to the durable `fixed_aspect_apps` set. Those
applications' windows stay untiled. A shortfall in only one direction is never
this evidence.

## Evidence boundaries

Keep input receipt, complete observation, pure plan, journaled commit, issued
setter, verified readback, renderer submission and physically visible change
separate. Readback does not certify a visible frame; test fixtures do not certify
physical input or live recovery timing. See [model/layout correspondence](../model-layout-correspondence.md)
and [responsiveness requirements](event-driven-responsiveness.md).

Recovery remains independent of the resident socket and preserves local durable
state. Unsupported behavior includes inactive-Space transfer, non-resizable/system
windows, programmatic OS Space transfer, discretionary floating, manual stacking,
and a general desktop/widget/picker shell.
