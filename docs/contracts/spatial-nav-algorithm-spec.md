# Spatial-navigation algorithm

[SpatialNav.swift](../../leylined/Sources/LeylineModel/SpatialNav.swift) is the pure
ranker. Independent frozen scenes under `tests/oracles` verify its ordering.
The resident supplies identity-bound presented managed windows from enabled visible
Spaces; ignored, minimized, hidden and OFF windows are excluded before ranking.
Focus-only commands rank current observed frames and bind the selected target to
its current lifetime. They do not require a reconciled layout checkpoint and
cannot replay saved frame targets. Complete observation, trust and actual Space
membership remain required. Recovery rebuilds a partition with no surviving
lifetimes without reclaiming its old tiles one by one.

## Surface and phases

The display frames form one stitched surface: their rectangular union. Display
identity does not create a same-display preference or a separate ranking tier.
All coordinates share the native global, top-down coordinate system.

Inputs are a source window ID, candidate IDs/frames, display frames and one of
north/east/south/west. Missing source returns `noFocus`. Remove the source from the
candidate pool, then evaluate two phases:

1. **Direct:** choose candidates in the direction (beyond the source's facing
   edge, or overlapping it with area past that edge) with strictly positive
   perpendicular overlap. Return the lexicographically best direct candidate if
   any exists.
2. **Wrap:** otherwise choose candidates with positive rectangular intersection
   with the opposite-edge band and strictly positive perpendicular overlap. Return
   the best wrap candidate, or `noCandidate` if the pool is empty.

Each explanation carries direction, outcome, winner and ranked IDs. The caller
verifies actual focus; a pure winner is not proof that focus changed.

## Direct viability

For source `s` and destination `d`, `d` lies in the direction when it is beyond
the facing edge, or when it overlaps the source and its far edge reaches more than
4 points past the facing edge:

| Direction | Beyond | Reaches past |
|---|---|---|
| East | `d.x >= s.x + s.w` | `d.x + d.w > s.x + s.w + 4` |
| West | `d.x + d.w <= s.x` | `d.x < s.x - 4` |
| South | `d.y >= s.y + s.h` | `d.y + d.h > s.y + s.h + 4` |
| North | `d.y + d.h <= s.y` | `d.y < s.y - 4` |

Touching edges count as beyond. Overlap happens when an application cannot
shrink to its tile; the neighbour it covers keeps its area past the source and
stays reachable instead of being skipped by a wrap. The 4-point floor absorbs
frame rounding. Perpendicular overlap is:

- East/west: `max(0, min(s.y+s.h, d.y+d.h) - max(s.y, d.y))`.
- North/south: `max(0, min(s.x+s.w, d.x+d.w) - max(s.x, d.x))`.

Overlap must be positive; corner-only contact does not qualify.

## Wrap bands

Let `u` be the display union. For east/west, band depth is the largest display
width. East wraps to the leftmost band; west to the rightmost band. For north/south,
depth is the largest display height. North wraps to the bottom band; south to the
top band. Bands span the full perpendicular dimension of `u`.

Intersection requires positive area. Edge-only contact with a band does not
qualify. No tolerance or display-adjacency graph changes this predicate.

## Deterministic score

Both phases sort ascending by this tuple:

```text
(edge_distance, -perpendicular_overlap, border_proportion,
 perpendicular_center_distance, window_id)
```

Direct edge distance is the signed gap from the source's facing edge to the
destination's near edge: nonnegative beyond the edge, negative for an overlapping
destination, which therefore ranks first. Wrap edge distance is measured from the opposite surface
edge to the destination's far edge:

| Direction | Wrap edge distance |
|---|---|
| East | `d.x - u.x` |
| West | `u.x + u.w - (d.x + d.w)` |
| South | `d.y - u.y` |
| North | `u.y + u.h - (d.y + d.h)` |

`border_proportion = 1 - overlap / destination_border_length`, where border length
is destination height for east/west and width for north/south. Smaller means more
of the destination border overlaps the source. Center distance is the absolute
perpendicular center difference. Window ID is the final deterministic tie-break.

For example, eastward from `(100,100,600,400)` to destination 200 at
`(1700,200,800,600)`, the tuple is `(1000,-300,0.5,200,200)`. With equal gaps, an
overlap of 400 ranks before 300 because its negated overlap is smaller.

The ranker owns geometry only. Space eligibility, trustworthy membership,
application focus effects and durable state belong to the resident.
