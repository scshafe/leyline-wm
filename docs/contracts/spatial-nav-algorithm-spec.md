# Spatial-navigation algorithm

[SpatialNav.swift](../../leylined/Sources/LeylineModel/SpatialNav.swift) is the pure
ranker. Independent JQ and frozen scenes under `tests/oracles` verify its ordering.
The resident supplies identity-bound presented managed windows from enabled visible
Spaces; ignored, minimized, hidden and OFF windows are excluded before ranking.

## Surface and phases

The display frames form one stitched surface: their rectangular union. Display
identity does not create a same-display preference or a separate ranking tier.
All coordinates share the native global, top-down coordinate system.

Inputs are a source window ID, candidate IDs/frames, display frames and one of
north/east/south/west. Missing source returns `noFocus`. Remove the source from the
candidate pool, then evaluate two phases:

1. **Direct:** choose candidates beyond the source's facing edge with strictly
   positive perpendicular overlap. Return the lexicographically best direct
   candidate if any exists.
2. **Wrap:** otherwise choose candidates with positive rectangular intersection
   with the opposite-edge band and strictly positive perpendicular overlap. Return
   the best wrap candidate, or `noCandidate` if the pool is empty.

Each explanation carries direction, outcome, winner and ranked IDs. The caller
verifies actual focus; a pure winner is not proof that focus changed.

## Direct viability

For source `s` and destination `d`, beyond the facing edge means:

| Direction | Condition |
|---|---|
| East | `d.x >= s.x + s.w` |
| West | `d.x + d.w <= s.x` |
| South | `d.y >= s.y + s.h` |
| North | `d.y + d.h <= s.y` |

Touching edges count as beyond. Perpendicular overlap is:

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

Direct edge distance is the nonnegative gap from the source's facing edge to the
destination's near edge. Wrap edge distance is measured from the opposite surface
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
