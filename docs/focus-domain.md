# Focus and borders

The resident timeline owns observed focus, confirmed history, interaction origin
and committed presentation. Window identity includes PID, number, lifetime,
observation epoch and stable Space/display context. Unknown or partial observation
cannot authorize focus or prove that a managed source disappeared.

Directional navigation ranks presented managed frames across visible displays.
Ignored, destroyed, minimized, inactive and OFF-Space windows are neither sources
nor destinations. See [the geometric ranker](contracts/spatial-nav-algorithm-spec.md).
Ordinary focus changes retain a valid captured move source; resize stays bound to
its original managed context. Invalidation releases the interaction.

After removal preserve valid managed focus, otherwise prefer the eligible absorber,
then a recent confirmed survivor. The history is deduplicated, most-recent-first
and bounded to 10 current typed identities. No survivor means no focus effect.
Only verified focus readback or compound completion updates it. The Windows menu
can reveal an obscured overload member and verify final front/focus without losing
other members. See [reclaim](contracts/reclaim-policy.md).

[BorderProjection](../leylined/Sources/LeylineModel/BorderProjection.swift) derives
role-colored immutable plans. Source/cursor rings are solid; exact candidate ghosts
are dashed. The selection boundary uses the candidate's canonical scope geometry.
One configured width controls the outside stroke, full perimeter allowance and
shared interior buffer. Width zero clears decoration and spacing.

Ignored/OFF windows receive no border. Projection discovers no windows, authors no
layout and issues no AX write. [BorderRenderer](../leylined/Sources/leylined/Projections/BorderRenderer.swift)
uses pooled noninteractive panels with animation disabled and submits only current
immutable plans. Submission proves an AppKit request, not physical visibility;
see [the evidence contract](contracts/event-driven-responsiveness.md).
