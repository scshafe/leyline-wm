# Parcel arrangement — a PURE, read-only LINE-PRIMARY derived lens.
#
# The line-centric tiling backbone's derivation core, ported from the FEEL
# prototype (experiments/line-model/arrangement.py) into pure jq. Where the BSP
# tree stores the SLICES and derives the lines, the arrangement stores a bag of
# LINE SEGMENTS and DERIVES the cells: coordinate-compress every segment coord
# into an atom grid, then union-find adjacent atoms across any border NO segment
# covers — a connected component is a cell. This is genuinely lines-primary (no
# slicing tree), handles T-junctions and non-slicing "pinwheel" layouts the tree
# cannot express, and makes a snap-join trivial (adding/removing a segment just
# changes which atoms merge).
#
# Like floorplan.jq / reconcile.jq, this is a SIBLING module that COMPOSES the
# engine's primitives by import (the build-DRY/modular directive) — it imports
# `geometry` as G and `parcel` as P and reuses G::TOL, G::inset_frame,
# P::canvas_rect, etc. It must NEVER reimplement geometry / min-size / canvas math
# (forking a second clamp dialect is the rollout's #1 named hazard — a window
# would settle differently under bsp vs arrangement and reintroduce a thrash).
#
# It is strictly READ-ONLY and HARNESS-ONLY: NOTHING in the engine imports it,
# exactly as floorplan.jq is unwired. The `guard/read-only-lenses` gate in
# parcel/tests.sh fails the suite if any engine file gains a top-level
# `import "arrangement"`, making "revertible by deleting the module" a TESTED
# property of S0–S5 — the arrangement store does not go live until the S6 cutover
# deliberately wires it through the strategy seam.
#
# ─────────────────────────────────────────────────────────────────────────
# SEGMENT shape (the prototype's `Line` minus the gesture-only fields id/pinned):
#   { axis: "v"|"h",   # "v" = vertical (constant x); "h" = horizontal (constant y)
#     coord,           # the constant coordinate (x for v, y for h) — the gridline
#     lo, hi }         # the span on the PERPENDICULAR axis (y for v, x for h)
#
# CELL shape (geometry-only — NO leaf_id; identity is S2, not S0):
#   { frame: {x,y,w,h}, atoms: [[i,j]…], i0,i1,j0,j1 }   (atoms carried so valid()
#   and incident() can read the atom-grid extent without recompressing).
#
# cells($arr; $canvas)     → [ cell … ]   the derived partition (any order)
# valid($arr; $canvas)     → { ok, components }  every component a FILLED rect
# incident($arr; $line)    → [ cell … ]   the pub->sub subscriber set of a line
# from_floorplan($t; $topo)→ [ segment … ] the SLICING-subset equivalence ADAPTER
#
# THE SLICING/NON-SLICING ASYMMETRY (the rollout's justification). `from_floorplan`
# can only derive a segment bag for layouts the BSP tree CAN express (it reads
# floorplan's merged edges, which are tree-node-derived). Non-slicing pinwheel /
# span-insert layouts have NO tree to derive from — which is exactly why
# from_floorplan bridges only the slicing subset, and why S1's pinwheel validity
# proof must be hand-authored. That asymmetry is not a gap; it IS why the
# arrangement store is strictly more expressive than the tree.
#
# THE COVERED-vs-CENTRELINE TOLERANCE (the S0 open question, settled by fixtures).
# from_floorplan hands segments at the gutter CENTRELINE (floorplan's edge.coord),
# and `cells` compresses those centrelines into atom borders — so the derived cells
# abut EDGE-TO-EDGE at the centreline (a gutterless partition), whereas floorplan's
# cells are gap-INSET (faces at the gutter edges, gap/2 short of the centreline).
# They are therefore set-equal ONLY at gap=0; under gap>0 each interior face
# differs by gap/2. This is faithful to the line-primary model (in a line store the
# gap is a RENDER inset applied downstream, exactly as the tree's split_slots
# applies the inner gap — the cells themselves share their boundary). The `equiv`
# oracle bridges the two by re-applying the gap inset (gutter()), so the rect SETS
# compare exactly; the equiv_gapless_grid (gap=0, raw match) and equiv_grid_2x2
# (gap=8, inset-bridged) fixtures bracket and SETTLE this. See module footer.
# ─────────────────────────────────────────────────────────────────────────

import "geometry" as G;
import "parcel" as P;
import "floorplan" as FP;
import "balance" as B;     # S5 (R2): the crowding valve, COMPOSED verbatim — never forked.
include "arrangement_helpers";   # leaf primitives (consolidation)

# Tolerance — aliased to the engine's shared frame tolerance (geometry.jq:12,
# default 4). The prototype's EPS=1e-6 becomes G::TOL: project's frames are
# rounded ints and the reachable-target bump only ever GROWS them, so the slicing
# case is exact within G::TOL.
def TOL: G::TOL;

# The canvas rect the arrangement tiles its cells over — COMPOSED from the shared
# helper, never re-derived. $T is a normalized topology (P::norm_topology output).
def canvas($T): P::canvas_rect($T);


def compress($arr; $canvas):
  ($arr | map(select(.axis == "v"))) as $vs
  | ($arr | map(select(.axis == "h"))) as $hs
  | (G::frame_min_x($canvas)) as $x0 | (G::frame_max_x($canvas)) as $x1
  | (G::frame_min_y($canvas)) as $y0 | (G::frame_max_y($canvas)) as $y1
  | { xs: _dedup_sorted([$x0, $x1] + ($vs | map(.coord)) + ($hs | map(.lo, .hi))),
      ys: _dedup_sorted([$y0, $y1] + ($hs | map(.coord)) + ($vs | map(.lo, .hi))) };

# ── covered: is an atom border cut by a segment? (arrangement.py:103) ─────────
# The open border [lo,hi] at `coord` on `axis` is covered iff some segment ON THAT
# AXIS sits at `coord` (within TOL) and spans the border's MIDPOINT (within TOL).
# Keying off the midpoint (not endpoint containment) is what makes a segment that
# only PARTIALLY covers a long border leave the uncovered part merge-able — the
# T-junction case. The `coord` passed is an atom-grid line (== a segment centreline
# on the slicing subset), so the TOL match is exact there: this is the predicate
# the covered-vs-centreline open question turns on, and it keys consistently off
# the SEGMENT coord (same coords compress gathered xs/ys from).
def covered($arr; $axis; $coord; $lo; $hi):
  (($lo + $hi) / 2) as $mid
  | any( $arr[] | select(.axis == $axis);
         (G::fabs(.coord - $coord) <= TOL)
         and (.lo - TOL <= $mid) and ($mid <= .hi + TOL) );



# ── components: union-find over un-covered borders (arrangement.py:111-138) ────
# Build the atom grid, union right/down neighbours across any border NO segment
# covers, then gather connected components. Each component → its atom list + the
# bounding (i0,i1,j0,j1) index box + the bounding rect frame from xs/ys. `filled`
# = whether the component is a SOLID rectangle (atom count == box area); a short
# count means an L-shape / hole (valid() rejects it). Atom index = i*ny + j.
def components($arr; $canvas):
  compress($arr; $canvas) as $g
  | ($g.xs) as $xs | ($g.ys) as $ys
  | (($xs | length) - 1) as $nx | (($ys | length) - 1) as $ny
  | if ($nx <= 0) or ($ny <= 0)
    then [ { atoms: [[0,0]], i0:0, i1:0, j0:0, j1:0, filled: true,
             frame: { x: G::frame_min_x($canvas), y: G::frame_min_y($canvas),
                      w: ($canvas.w // 0), h: ($canvas.h // 0) } } ]
    else
      # union pass: thread one parent-map through every neighbour border.
      ( reduce range(0; $nx) as $i ({};
          reduce range(0; $ny) as $j (.;
            ($i * $ny + $j) as $a
            # right neighbour (vertical border at xs[i+1] over [ys[j],ys[j+1]])
            | (if ($i + 1 < $nx)
                  and ((covered($arr; "v"; $xs[$i+1]; $ys[$j]; $ys[$j+1])) | not)
               then _union(.; $a; (($i+1) * $ny + $j)) else . end)
            # down neighbour (horizontal border at ys[j+1] over [xs[i],xs[i+1]])
            | (if ($j + 1 < $ny)
                  and ((covered($arr; "h"; $ys[$j+1]; $xs[$i]; $xs[$i+1])) | not)
               then _union(.; $a; ($i * $ny + ($j+1))) else . end)
          )) ) as $parent
      # gather: root -> [[i,j]…]
      | ( reduce range(0; $nx) as $i ({};
            reduce range(0; $ny) as $j (.;
              ($i * $ny + $j) as $a
              | (_find($parent; $a) | tostring) as $r
              | .[$r] = ((.[$r] // []) + [[$i, $j]])
            )) ) as $comp
      | [ $comp | to_entries[] | .value as $atoms
          | ([ $atoms[][0] ] | min) as $i0 | ([ $atoms[][0] ] | max) as $i1
          | ([ $atoms[][1] ] | min) as $j0 | ([ $atoms[][1] ] | max) as $j1
          | { atoms: ($atoms | sort), i0:$i0, i1:$i1, j0:$j0, j1:$j1,
              filled: (($atoms | length) == (($i1 - $i0 + 1) * ($j1 - $j0 + 1))),
              frame: { x: $xs[$i0], y: $ys[$j0],
                       w: ($xs[$i1+1] - $xs[$i0]), h: ($ys[$j1+1] - $ys[$j0]) } } ]
      # Sort components by their bounding-rect origin then extent — a stable,
      # jq-object-iteration-independent order so fixtures pin a deterministic
      # output (cells() re-sorts the same way; the raw order is never load-bearing).
      | sort_by([.frame.y, .frame.x, .frame.w, .frame.h])
    end;

# ── cells: the derived partition (arrangement.py:88, public) ──────────────────
# The components' bounding rects, sorted [y,x] (the prototype's (y0,x0) label order)
# for a deterministic order. Cells are geometry-only: a `frame` plus the atom-box
# extent (i0..j1, atoms) that valid()/incident() read. NO leaf_id — identity is S2.
def cells($arr; $canvas):
  components($arr; $canvas)
  | sort_by([.frame.y, .frame.x]);

# ── _partition_facts: ONE shared derivation both halves of valid() read ───────
# Step 2 of S1 (R1, line-centric rollout). The no-gap check and the nonrect check
# must read the SAME coordinate-compress + union-find — re-compressing twice would
# fork the atom grid (the DRY/no-second-clamp-dialect directive). This helper runs
# compress() ONCE (for the grid dimensions nx,ny) and components() ONCE, then
# surfaces the atom-claim accounting both halves need:
#
#   nx, ny           the compressed atom-grid dimensions (|xs|-1, |ys|-1).
#   grid_atoms       nx*ny — the exact integer count of atoms the partition must
#                    cover. INTEGER arithmetic, NO float TOL (see the no-gap note).
#   comps            the components() output, threaded through unchanged.
#   claimed_atoms    the count of atoms covered by a FILLED-RECTANGLE cell — the
#                    union of every FILLED component's index box. The NO-GAP
#                    INVARIANT is claimed_atoms == grid_atoms (every atom claimed by
#                    exactly one valid cell). This is the AUTHORITATIVE locator, NOT
#                    the area sum: union-find always assigns every atom to SOME
#                    component, so a raw component-atom tally is the identity nx*ny
#                    and can never fail; it is the FILLED-cell coverage that drops
#                    when a non-rectangular component leaves a hole. EMPIRICALLY (an
#                    exhaustive small-bag search, 2026-05-30) a gap in this atom-grid
#                    model ALWAYS coincides with a non_rectangular component — the
#                    courtyard a ring fails to fill is exactly the ring's missing
#                    atoms — so gap and nonrect are DUAL views of one defect. The gap
#                    clause is still worth keeping: nonrect names the BROKEN
#                    component, gap names WHERE the canvas is unclaimed (its bbox).
#   unclaimed_box    the bounding {x,y,w,h} of the atoms NO filled cell covers
#                    (null when claimed_atoms == grid_atoms), so the gap violation
#                    can name the region. Computed from the SAME xs/ys as components.
#   missing_area     the summed area of the unclaimed atoms (0 when none) — the
#                    cheap area cross-check; NOT authoritative (see the no-gap note).
def _partition_facts($arr; $canvas):
  compress($arr; $canvas) as $g
  | ($g.xs) as $xs | ($g.ys) as $ys
  | (($xs | length) - 1) as $nx | (($ys | length) - 1) as $ny
  | components($arr; $canvas) as $comps
  # The set of atom [i,j] cells covered by a FILLED (valid-rectangle) component's
  # index box. A non-rectangular component contributes NOTHING here — its atoms are
  # unclaimed by any valid cell, which is the gap.
  | ( [ $comps[] | select(.filled)
        | range(.i0; .i1 + 1) as $i | range(.j0; .j1 + 1) as $j | [$i, $j] ]
      | unique ) as $claimed
  | ($claimed | length) as $claimed_atoms
  # The atoms NO filled cell covers = full grid minus the claimed set.
  | ( [ range(0; $nx) as $i | range(0; $ny) as $j | [$i, $j] ]
      - $claimed ) as $unclaimed
  | ( if ($unclaimed | length) == 0 then null
      else
        ( [ $unclaimed[][0] ] | min ) as $i0 | ( [ $unclaimed[][0] ] | max ) as $i1
        | ( [ $unclaimed[][1] ] | min ) as $j0 | ( [ $unclaimed[][1] ] | max ) as $j1
        | { x: $xs[$i0], y: $ys[$j0],
            w: ($xs[$i1 + 1] - $xs[$i0]), h: ($ys[$j1 + 1] - $ys[$j0]) }
      end ) as $unclaimed_box
  | ( [ $unclaimed[]
        | ($xs[.[0] + 1] - $xs[.[0]]) * ($ys[.[1] + 1] - $ys[.[1]]) ]
      | add // 0 ) as $missing_area
  | { nx: $nx, ny: $ny, grid_atoms: ($nx * $ny), comps: $comps,
      claimed_atoms: $claimed_atoms, unclaimed_box: $unclaimed_box,
      missing_area: $missing_area };

# ── valid: a COMPLETE planar-subdivision invariant (no-overlap AND no-gap) ─────
# S1 step 3 (R1). The arrangement is a valid partition iff BOTH:
#   (a) every connected component is a SOLID rectangle — its atom count equals its
#       index-box area (i1-i0+1)*(j1-j0+1); a short-count component is an L-shape /
#       has a hole → `non_rectangular` (the half S0 ported from arrangement.py:140);
#   (b) the FILLED-rectangle cells COVER the canvas with no gap — every
#       compressed-grid atom is claimed by exactly one filled cell → otherwise `gap`.
# Half (b) is the one guarantee the BSP tree gave for FREE (a tree's leaves partition
# by construction; a raw segment bag does not) and is the whole point of R1.
# Returns the validate/f1 {ok, violations} envelope.
#
# THE NO-GAP CHECK IS ATOM-CLAIM-COUNT-AUTHORITATIVE, NOT AREA — DO NOT "SIMPLIFY".
# The invariant is the EXACT INTEGER claimed_atoms == grid_atoms (nx*ny), computed in
# _partition_facts. A future reader MUST NOT replace it with the area identity
# `abs(sum_cell_area - canvas_area) <= TOL`: an area sum hides a +δ/−δ cancellation
# (one cell overshoots by +δ exactly as a neighbour leaves a −δ hole — the
# overlap+gap pair a partition must forbid), and TOL is a LENGTH compared against an
# AREA (a 1px-thin 4000px gap has area 4000 ≫ TOL yet is a single atom). The atom
# count is exact integer arithmetic on the compressed grid — it cannot cancel — and
# it LOCATES the unclaimed region (unclaimed_box) so the violation names WHERE. The
# area identity survives ONLY as the cheap `missing_area` cross-check field.
#
# (Empirically — exhaustive small-bag search, 2026-05-30 — a gap in this atom-grid
# model ALWAYS coincides with a non_rectangular component: the courtyard a ring fails
# to fill is exactly the ring's own missing atoms. So a hole scene emits BOTH a
# non_rectangular AND a gap violation; that co-occurrence is honest, not a bug. gap
# adds value the nonrect half lacks: it names the unclaimed REGION, not the broken
# component.)
def valid($arr; $canvas):
  _partition_facts($arr; $canvas) as $pf
  | ( [ $pf.comps[] | select(.filled | not)
        | { kind: "non_rectangular", frame, atoms: (.atoms | length),
            box: (((.i1 - .i0 + 1) * (.j1 - .j0 + 1))) } ]
      | sort_by([.frame.y, .frame.x]) ) as $nonrect
  # No-gap: claimed_atoms (atoms covered by a FILLED cell) must equal the full grid.
  # EXACT integer compare — no TOL. The frame is the bbox of the unclaimed atoms.
  | ( if $pf.claimed_atoms == $pf.grid_atoms then []
      else [ { kind: "gap", missing_area: $pf.missing_area,
               frame: $pf.unclaimed_box } ]
      end ) as $gaps
  | ($nonrect + $gaps) as $violations
  | { ok: (($violations | length) == 0), violations: $violations };

# ── incident: the pub->sub subscriber set of a line (arrangement.py:145) ──────
# The cells that TOUCH `$line` — the set a move_line would reflow (S8's bounded
# local solve stands on this). A cell touches a `v` line iff one of its x-faces
# (min_x or max_x) equals line.coord within TOL AND its y-extent OVERLAPS the
# line's perpendicular span [lo,hi] with POSITIVE width (a bare endpoint touch,
# y1==lo or y0==hi, does NOT subscribe — `not (y1 <= lo or y0 >= hi)`). Symmetric
# for `h`. $arr is the segment bag, $line a segment {axis,coord,lo,hi}. Returns the
# incident cells whole (frame + atom box) so S2 can re-home them by identity later.
def incident($arr; $canvas; $line):
  ($line.coord) as $lc | ($line.lo) as $llo | ($line.hi) as $lhi
  | [ cells($arr; $canvas)[]
      | .frame as $f
      | (if $line.axis == "v"
         then ((G::fabs(G::frame_min_x($f) - $lc) <= TOL)
                or (G::fabs(G::frame_max_x($f) - $lc) <= TOL))
              and ((G::frame_max_y($f) > $llo) and (G::frame_min_y($f) < $lhi))
         else ((G::fabs(G::frame_min_y($f) - $lc) <= TOL)
                or (G::fabs(G::frame_max_y($f) - $lc) <= TOL))
              and ((G::frame_max_x($f) > $llo) and (G::frame_min_x($f) < $lhi))
         end) as $touch
      | select($touch) ];

# ── from_floorplan: the SLICING-subset equivalence ADAPTER (the bridge) ───────
# Derive a segment bag from floorplan's MERGED gridline edges — composing
# FP::floorplan (NOT re-deriving geometry). Each edge {axis, coord, span:{lo,hi}}
# becomes a segment {axis, coord, lo:span.lo, hi:span.hi}: floorplan already did
# the collinear-merge + cross-display exclusion, so its edges ARE the slicing
# arrangement's gridlines. This lets arrangement::cells(from_floorplan(t;topo);
# canvas) be compared SET-EQUAL against floorplan's own cells — the from_floorplan
# bridge that proves the arrangement matches the tree on the slicing subset.
#
# THE ASYMMETRY (the rollout's justification): from_floorplan can bridge ONLY the
# slicing subset, because floorplan's edges are derived from BSP tree nodes (a
# divider == an LCA row/col split). Non-slicing pinwheel / span-insert layouts have
# NO tree to derive edges from — which is exactly why the arrangement store is
# strictly more expressive than the tree, and why S1's pinwheel must be
# hand-authored (cells can DERIVE it; from_floorplan can never BRIDGE it).
# THE PER-SEGMENT STICKY MARKER (S10, parcel-core). A segment carries a `relation`
# facet (spec §2.2's typed-line relation, pre-staged): `pinned` means this gridline
# `coord` is HAND-SET (op_set_ratio stamped ratio_source:"pinned" on the divider node),
# do-not-re-snap — the segment-space analogue of the I4 pinned-ratio veto. A `free`
# segment is the default and carries NO `relation` field, so the base case (no hand-set
# ratio — which is EVERY golden/reconcile fixture) bridges BYTE-IDENTICALLY: the
# arrangement-bridge + golden-equiv tripwires never see a relation field appear.
#
# The marker is DERIVED, never re-computed: floorplan already tags each edge with the
# `dividers` (the LCA split-node[s] the gridline bounds, floorplan.jq:131,145,155). A
# segment is `pinned` iff EVERY divider node it carries is ratio_source:"pinned" (a
# hand-set split). Reading ratio_source off the tree node is a pure read — ZERO frame
# math, ZERO clamp dialect (the #1 hazard is untouched; from_floorplan stays the
# slicing-subset adapter it always was, only annotated with which gridlines are sticky).
# This is the WRITE side of the round-trip the system-of-record needs: the structure-
# preserving prior-read (strategies/arrangement.jq) reads `relation:"pinned"` back into
# the reconstructed prior tree's ratio_source so the prune/adopt reproportion skips it.
def from_floorplan($tree; $topo):
  ($tree.nodes // {}) as $nodes
  | FP::floorplan($tree; $topo)
  | [ .edges[]
      # A segment is sticky iff it has divider node(s) AND every one of them is a
      # hand-set (ratio_source:"pinned") split. `dividers` carries the LCA node ids;
      # an edge with no divider (defensive) is free. Free segments omit `relation`.
      | ( (.dividers // []) ) as $divs
      | ( ($divs | length) > 0
          and (all($divs[]; ($nodes[.].ratio_source // "computed") == "pinned")) ) as $pinned
      | ( { axis, coord, lo: .span.lo, hi: .span.hi }
          + (if $pinned then { relation: "pinned" } else {} end) ) ]
  # OUTSET-INTERIOR (the coordinate-system seam fix). floorplan derives a col/row
  # edge's span over the gap/2-INSET project frames, so an INTERIOR face is pulled
  # in by gap/2 (a canvas-boundary face stays flush). The arrangement works in
  # CENTRELINE coords (cells() abut at the segment centreline), so a verbatim copy
  # of that inset span leaves the interior face gap/2 SHORT of the perpendicular
  # wall — once gap/4 > TOL (gap > 16) covered() misses the join and the column
  # fuses, dropping a window. Push each interior endpoint back OUT to the centreline
  # wall (the exact inverse of _inset_interior): if an endpoint is NOT within TOL of
  # ITS OWN DISPLAY rect's perpendicular boundary, move it outward by gap/2. The
  # display rect (per-segment bag rect) — never the global union — so a display-
  # interior wall is outset while a display-edge face stays flush (R5). At gap=0 the
  # inset is zero, so this is the IDENTITY (byte-inert on every gap=0 corpus).
  | (P::norm_topology($topo)) as $T
  | ($T.gap // 0) as $gap
  | [ .[]
      | . as $seg
      # The segment's representative point (a small TOL square at its midpoint —
      # the same homing the partition uses) and the display it homes to, then THAT
      # display's gap-inset usable rect (the per-display canvas, never the global
      # union — R5). This MIRRORS _segment_point + _canvas (the per-display bag
      # rect, defined ~140 lines below) VERBATIM; jq forbids the forward reference,
      # so it is duplicated inline from imported primitives only. The duplication is
      # LOCKED by parcel/store-adopt-column-sweep.sh's no-cross-seam assertion (a
      # drift from _bags' homing reddens it); FOLLOWUPS tracks hoisting the two
      # helpers above this def to dedup.
      | (if $seg.axis == "v"
         then { x: ($seg.coord - TOL), y: ((($seg.lo + $seg.hi) / 2) - TOL),
                w: (2 * TOL), h: (2 * TOL) }
         else { x: ((($seg.lo + $seg.hi) / 2) - TOL), y: ($seg.coord - TOL),
                w: (2 * TOL), h: (2 * TOL) }
         end) as $pt
      | (G::assign_display($pt; $T.displays)) as $home
      | (G::inset_frame(P::display_usable($T; $home); $gap)) as $r
      | if ($gap > 0 and $r != null)
        then ($gap / 2) as $hg
          | (if $seg.axis == "v"
             then { b0: G::frame_min_y($r), b1: G::frame_max_y($r) }
             else { b0: G::frame_min_x($r), b1: G::frame_max_x($r) }
             end) as $bnd
          | .lo = (if (G::fabs(.lo - $bnd.b0) <= TOL) then .lo else .lo - $hg end)
          | .hi = (if (G::fabs(.hi - $bnd.b1) <= TOL) then .hi else .hi + $hg end)
        else .
        end ]
  | sort_by([.axis, .coord, .lo]);


# ── equiv: the SET-EQUALITY oracle (arrangement::cells vs floorplan::cells) ────
# Derive the segment bag from the tree (from_floorplan), derive the arrangement's
# cells over the SAME canvas (P::canvas_rect of the normalized topology), re-apply
# the gutter inset, and return the cell rect SET sorted [x,y,w,h]. The harness
# compares this against floorplan's _cells frames (also a sorted rect set) — SET
# equality, NOT order or leaf-keyed equality (arrangement cells have no leaf_id;
# identity is S2). This is the from_floorplan equivalence proof the slicing corpus
# ranges over.
def equiv($tree; $topo):
  (P::norm_topology($topo)) as $T
  | ($T.gap // 0) as $gap
  | (canvas($T)) as $cv
  | (from_floorplan($tree; $topo)) as $segs
  | [ cells($segs; $cv)[] | _inset_interior(.; $cv; $gap) ]
  | sort_by([.x, .y, .w, .h]);

# ════════════════════════════════════════════════════════════════════════════
# PER-DISPLAY ARRANGEMENT (S4 / R5) — segment bags + structural cross-display
# edge exclusion. The arrangement becomes per-display-aware EXACTLY as the tree's
# pinned `d:<id>` mounts are: one segment bag per occupied display, cells derived
# per display THEN unioned — so no derived cell, edge, or union-find component can
# ever span a display gap, and the prior multi-display thrash structurally cannot
# return.
#
# THE STRUCTURAL (not geometric) EXCLUSION. The seductive-wrong-move is ONE global
# segment bag carrying a display_id tag: under the union-find cell derivation
# (compress → atom grid → DSU across un-covered borders), a global bag means the
# inter-display atom band — which NO segment covers when displays are FLUSH — gets
# unioned across, fusing a cell across the seam (the exact thrash precondition R5
# names). A coordinate "band-width" filter would FAIL the flush case (zero physical
# band between display frames). The fix is structural: the canvas is the LIST of
# per-display usable rects (each inset by gap), and cells are derived PER display
# then unioned — so a per-display atom grid never shares an atom across the band BY
# CONSTRUCTION. This mirrors the tree's pinned-mount cross-display exclusion
# (floorplan.jq:86-93: a divider exists only for a row/col LCA; two cells on
# SEPARATE display mounts have a region/mount LCA → no edge, surviving flush
# displays at any gap).
#
# COMPOSED primitives (imported, NEVER forked): P::norm_topology, P::display_usable,
# G::inset_frame, G::assign_display. The single-display path (cells/valid/incident/
# equiv) is UNCHANGED — a 1-display topology degenerates to ONE bag == the whole
# thing, byte-identical to the S0–S3 single-canvas output.

# ── _canvas: the per-display usable-rect SET (the bag partition key) ──────────
# Step 1 of S4. Returns a LIST [ {display_id, rect} ], rect = the same per-display
# inset the pinned mount tiles over (parcel.jq:245 — G::inset_frame(display_usable;
# gap)). DELIBERATELY a list, NEVER folded with G::frames_union: folding here is the
# seductive-wrong-move (it reintroduces the global-bag fusion R5 exists to prevent).
# The single-extent canvas($T)=P::canvas_rect($T) survives ONLY as an output
# back-compat seed (the _root union) — it MUST NEVER feed cell/edge derivation.
# $T is the already-normalized topology (P::norm_topology output).
def _canvas($T):
  [ $T.displays[]
    | { display_id: .id,
        rect: G::inset_frame(P::display_usable($T; .id); ($T.gap // 0)) } ];

# A segment's representative point — a SMALL square centered on the midpoint of its
# extent, the frame G::assign_display homes by usable-area overlap. A `v` segment is
# constant x=coord, spanning y in [lo,hi] → centre {x:coord, y:(lo+hi)/2}; an `h`
# segment is constant y=coord, spanning x → centre {x:(lo+hi)/2, y:coord}. The
# square must have POSITIVE area on BOTH axes: a degenerate zero-size frame overlaps
# NO display (area 0), so assign_display's all-zero tie-break would home EVERY
# segment to the lowest display id (the bug a point-frame hits). A 2·TOL square
# centred strictly inside one display's rect overlaps ONLY that display, so it homes
# correctly while reusing the engine's homing policy verbatim (max usable-overlap,
# ties → lowest id) — the arrangement does NOT invent a second homing rule.
def _segment_point($seg):
  (if $seg.axis == "v"
   then { cx: $seg.coord, cy: (($seg.lo + $seg.hi) / 2) }
   else { cx: (($seg.lo + $seg.hi) / 2), cy: $seg.coord }
   end)
  | { x: (.cx - TOL), y: (.cy - TOL), w: (2 * TOL), h: (2 * TOL) };


# ── _bags: partition the input segment bag by display ─────────────────────────
# Step 2 of S4. Returns [ {display_id, segments, rect} ] — one bag per display in
# topology order — PLUS a `rejected` sidecar via _bags_with_rejected (below). Each
# segment is homed to a display by its midpoint (G::assign_display over the SAME
# normalized displays the engine homes windows with), then CONFIRMED to sit wholly
# within that display's _canvas inset rect; a segment that crosses the boundary is
# dropped from every bag and recorded as rejected. Downstream derivation (cells_md,
# valid_md, edges_md) sees N independent per-display bags, never one global bag —
# the structural partition that makes a cross-seam component impossible.
def _bags_with_rejected($segments; $T):
  (_canvas($T)) as $cv
  | ( reduce ($segments // [])[] as $seg ({ homes: {}, rejected: [] };
        (G::assign_display(_segment_point($seg); $T.displays)) as $home
        | ([ $cv[] | select(.display_id == $home) ][0] // null) as $hb
        | if ($hb != null) and (_segment_in_rect($seg; $hb.rect))
          then .homes[($home | tostring)] = ((.homes[($home | tostring)] // []) + [$seg])
          else .rejected += [$seg]
          end) ) as $sorted
  | { bags: [ $cv[]
              | { display_id: .display_id,
                  segments: ($sorted.homes[(.display_id | tostring)] // []),
                  rect: .rect } ],
      rejected: $sorted.rejected };

def _bags($segments; $T):
  _bags_with_rejected($segments; $T).bags;

# ── cells_md: derive cells PER display then union ─────────────────────────────
# Step 3 of S4. For each bag, run S0's cells() over THIS bag's rect ONLY (reused
# verbatim — coordinate-compress + union-find within one display's inset rect),
# tag every derived cell with the bag's display_id, then flatten. Because each
# bag's atom grid is built over ONE display's rect, no atom spans the inter-display
# band, so NO union-find component can cross the seam BY CONSTRUCTION — the
# structural guarantee, earned not asserted. Sorted [display_id, frame.y, frame.x]
# so a fixture pins a deterministic order. Single-display degeneracy: one bag ==
# the whole canvas, so the cells are byte-identical to cells($arr; canvas($T)) with
# a display_id tag.
def cells_md($segments; $T):
  [ _bags($segments; $T)[]
    | .display_id as $did | .rect as $r
    | cells(.segments; $r)[]
    | . + { display_id: $did } ]
  | sort_by([.display_id, .frame.y, .frame.x]);

# ── valid_md: S1's full partition-validity PER bag ────────────────────────────
# Step 5 of S4. Run valid() (no-overlap AND no-gap) over EACH bag independently and
# report { ok, per_display: [ {display_id, ok, violations} ] }. A gap or overlap on
# display 1 must NOT implicate display 2 (the per-bag isolation), and an EMPTY
# display (no segments → one cell filling the rect) is VACUOUSLY valid — NOT a
# "whole-canvas gap" violation. This is the bug S4 avoids: S1's single-bag valid()
# run over the union rect would false-positive the inter-display band as a gap; here
# the band is outside every bag's rect, so it is never a region to be filled. The
# top-level ok is the AND over per-display ok.
def valid_md($segments; $T):
  ( [ _bags($segments; $T)[]
      | (valid(.segments; .rect)) as $v
      | { display_id: .display_id, ok: $v.ok, violations: $v.violations } ] ) as $pd
  | { ok: (all($pd[]; .ok)), per_display: $pd };


def edges_md($segments; $T):
  ( [ _bags($segments; $T)[]
      | .display_id as $did
      | .segments[] | . + { display_id: $did } ] ) as $edges
  | ( [ _bags($segments; $T)[]
        | .display_id as $did
        | _bag_corners(.)[] | . + { display_id: $did } ] ) as $corners
  | { edges: ($edges | sort_by([.display_id, .axis, .coord, .lo])),
      corners: ($corners | sort_by([.display_id, .x, .y])) };

# ── bridge_md_equiv: the from_floorplan bridge extended to multi-display ───────
# Step 4 of S4. The S3 from_floorplan bridge proves arrangement ≡ tree on the
# slicing subset over ONE canvas; here prove it holds when the tree has per-display
# `d:<id>` pinned mounts. Derive the segment bag from the tree (from_floorplan —
# floorplan already did the structural cross-display edge exclusion, so a flush
# 2-display tree yields an EMPTY bag), home each segment into its display bag, derive
# cells_md, and re-apply the per-display gutter inset (the same _inset_interior
# equiv() uses, but over EACH bag's OWN rect as that display's canvas). The result
# is the per-display cell rect set — byte-comparable (jq -S) against floorplan's own
# cells, tying the new per-display path back to the shipped floorplan.jq behavior.
# This RESOLVES S0's deferred equiv_multi_display.
def bridge_md_equiv($tree; $topo):
  (P::norm_topology($topo)) as $T
  | ($T.gap // 0) as $gap
  | (from_floorplan($tree; $topo)) as $segs
  | [ _bags($segs; $T)[]
      | .rect as $r
      | cells(.segments; $r)[]
      | _inset_interior(.; $r; $gap) ]
  | sort_by([.x, .y, .w, .h]);

# ── THE RECONCILE BRIDGE (S3 / R4) ────────────────────────────────────────────
# The branch-by-abstraction lever: a SECOND, equivalent producer of reconcile's
# window-keyed target map. `reconcile_targets($tree;$topo)` (reconcile.jq:194-204)
# is the only thing that builds that map from a tree today — `arrangement_targets`
# builds the BYTE-IDENTICAL map from an arrangement, so S6 can swap producers under
# an UNCHANGED diff/reactor/executor stack. Proven byte-equal on every reconcile/
# fixture by the independent tree-producer oracle parcel/arrangement-bridge.sh (the
# "never grade your own homework" pattern, sibling to landed-equiv.sh).
#
# ── THE PARTITION-vs-IMPEDANCE BOUNDARY (the rollout's #1 named hazard) ──
# The arrangement owns the PARTITION (which cell is where — the union-find cells()).
# `parcel.jq` keeps owning the frame-vs-min IMPEDANCE (the reachable-target bump at
# parcel.jq:304-328 — `.w = max(.w, fm.w)`). arrangement_targets must NEVER author a
# second min-size clamp dialect: a window settling to a DIFFERENT frame under bsp vs
# arrangement reintroduces the non-reproducible reframe-thrash already paid for once
# (memory: D-over-E reframe-thrash fix). The structural defence: the per-window FRAME
# is project's `$reach`-bumped desired_frame carried VERBATIM through the bridge —
# bridge_arrangement composes P::project and copies its desired_frame into the
# side-table; arrangement_targets re-emits it untouched. There is ZERO min_size
# arithmetic in this module. min_fit_chrome_settles byte-equality (the anti-fork
# tripwire) fails the build the instant the dialects diverge.
#
# ── THE THREE-WAY SPLIT (mirroring reconcile_targets exactly) ──
#   PRESENTED bound leaf  → { window_id, presented:true,  frame: desired_frame }
#   OFF-TOP  bound leaf   → { window_id, presented:false, frame: desired_frame } (frame may be null)
#   VACANT leaf (wid null)→ NO entry (the reconcile.jq:199 `if $wid==null then .` skip)
# keyed by `window_id | tostring`. A PRESENTED leaf has a cell in the partition (its
# desired_frame is a real rect floorplan derived an edge from); an OFF-TOP leaf (a
# non-top stack member: presented==false, frame possibly null) is NOT a cell in the
# segment-bag partition, so its binding is carried in the bridge's `off_top` list and
# merged in — the only honest way to reproduce reconcile's bound-off-top emission
# (context_switch's window 200) before S5 makes the stack a first-class cell attribute.
#
# ── bridge_arrangement: the SLICING-subset adapter (a SIBLING to from_floorplan) ──
# from_floorplan returns a BARE segment bag (its equiv/subsumption consumers depend on
# that shape — DO NOT change it). bridge_arrangement is the richer structure
# arrangement_targets needs: { segments, bindings, off_top } where
#   segments : from_floorplan's bare bag (reused verbatim — the partition).
#   bindings : anchor-keyed side-table "<i0>:<j0>" -> { window_id, presented, frame }
#              for each PRESENTED bound leaf, the cell matched by frame geometry, the
#              frame being project's desired_frame (the impedance bump already baked in).
#   off_top  : [ { window_id, presented, frame } ] for each OFF-TOP bound leaf (no cell).
# It COMPOSES P::project for the per-leaf presented bit + frame and reads the tree's
# window_id — it does NOT re-derive identity (that is S2) nor geometry (that is S0).
# The per-cell ANCHOR KEY for the binding side-table. PER-DISPLAY-QUALIFIED
# ("<display_id>:<i0>:<j0>") so two cells with the SAME local atom-box anchor on
# DIFFERENT display bags (e.g. each display's top-left cell is "0:0" locally) do not
# collide. On a single-display topology display_id is constant, so the key is just
# the prefixed "<i0>:<j0>" — still distinct per cell, and since the OUTPUT map is
# keyed by window_id (never by this anchor), the qualification is byte-invisible to
# arrangement_targets' output (single-display fixtures stay byte-equal). cells_md
# tags every cell with display_id; the single-display cells() path does not, so we
# default a missing tag to 0 (harmless — constant within one canvas).
def _anchor_key($cell):
  "\($cell.display_id // 0):\($cell.i0):\($cell.j0)";


# Geometric fallback resolution for ONE bag. Each cell in $cells carries .lk (the
# localkey the emit site looks up) and .frame; $b is that bag's binding side-table.
# Returns a { lk -> binding-entry } map for ONLY the cells whose exact key missed,
# matched to the UNCLAIMED leaf binding they overlap most — greedily over a totally
# ordered pair list (area DESC, window_id ASC, cell-key ASC), so each cell binds at
# most one window and each window at most one cell (no double-assign, deterministic
# under straddle). Empty when every cell resolves by exact key, so it is byte-inert
# on key-matching scenes. Cross-display matching is impossible by construction
# (disjoint displays have zero frame overlap -> no positive-area pair).
def _rekey_resolve($cells; $b):
  ( reduce $cells[] as $c ({};
      ($c.lk) as $k
      | ($b[$k]) as $e
      | if ($e != null) and (((($e.contents[0].window_id) // $e.window_id) // null) != null)
        then .[$k] = true else . end ) ) as $claimed
  | ( [ $cells[]
        | select( (($b[.lk]) == null)
                  or (((($b[.lk].contents[0].window_id) // $b[.lk].window_id) // null) == null) )
        | { ck: .lk, frame: .frame } ] ) as $U
  | ( [ $b | to_entries[]
        | .key as $bk | .value as $bv
        | (((($bv.contents[0].window_id) // $bv.window_id) // null)) as $wid
        | select($wid != null)
        | select(($claimed[$bk] // false) | not)
        | select(((($bv.nested.segments) // []) | length) == 0)
        | { wid: $wid, frame: (($bv.contents[0].frame) // $bv.frame), entry: $bv } ] ) as $V
  | ( [ $U[] as $c | $V[] as $v
        | { ov: _isect_area($c.frame; $v.frame), ck: $c.ck, wid: $v.wid, entry: $v.entry }
        | select(.ov > 0) ]
      | sort_by([ (- .ov), .wid, .ck ]) ) as $pairs
  | ( reduce $pairs[] as $pr ({ usedc: {}, usedw: {}, map: {} };
        if (.usedc[$pr.ck] // false) or (.usedw["\($pr.wid)"] // false) then .
        else .usedc[$pr.ck] = true
             | .usedw["\($pr.wid)"] = true
             | .map[$pr.ck] = $pr.entry
        end ) | .map );

def bridge_arrangement($tree; $topo):
  (P::norm_topology($topo)) as $T
  | (from_floorplan($tree; $topo)) as $segs
  | (P::project($tree; $topo)) as $proj
  | ($tree.nodes // {}) as $nodes
  # The derived cells (the partition) — PER DISPLAY (cells_md) so a multi-display
  # tree's per-display pinned mounts each yield their OWN cells, never one degenerate
  # canvas-spanning cell over the union. On a single-display topology this is one bag
  # == the whole canvas, byte-identical to the old cells($segs; canvas($T)) modulo the
  # display_id tag (which only feeds the per-display anchor key, not the output). This
  # is the S4 routing that flips the gapped multi_display fixture from defer to
  # byte-equal: each window's project frame min-corner now matches its OWN display's
  # cell, not a union cell.
  | (cells_md($segs; $T)) as $cells
  # Join each project leaf with the tree's window_id (the same join reconcile_targets
  # does at reconcile.jq:198). A VACANT leaf (window_id null) drops out — no binding.
  | ( [ $proj.leaves | to_entries[]
        | ($nodes[.key].window_id // null) as $wid
        | select($wid != null)
        # P-MIN M2: persist the stamped leaf floor onto the binding (the field
        # P::leaf_fit_min and lineops' _cell_min already read), refreshed each
        # cold author from the store — so the native authors' reach_bump and
        # the drag clamp are LIVE across churn, and settle-2 re-derives the
        # same bumped frame (the FOLLOWUPS min-persistence class). Key OMITTED
        # when absent: an empty minstore bridges byte-identically (the locks).
        | ($nodes[.key].min_size // null) as $ms
        | ( { window_id: $wid,
              presented: .value.presented,
              frame:     .value.desired_frame }
            + (if $ms != null then { min_size: $ms } else {} end) ) ] ) as $bound
  # PRESENTED bound leaves: a real frame → it occupies one cell of the partition.
  # Locate the home cell by CONTAINMENT of the window frame's CENTRE in the (raw, centreline)
  # cell — NOT by min-corner equality. The window frame is project's desired_frame (the rendered
  # frame, gap/2-inset on interior faces); the cells_md cell is the RAW centreline rect. On an
  # interior face the two min-corners diverge by exactly gap/2, so a min-corner ±TOL match SILENTLY
  # DROPS every interior-edge window once gap/2 > TOL (gap ≥ 10) — and a multi-display / col-mount
  # grid even at gap 8 (the latent window-loss the S-P3 impl adversarial pass localized; see
  # FOLLOWUPS, and the gap-sweep + col-mount fixtures). The CENTRE is gutter-agnostic: each presented
  # window's centre sits strictly inside exactly ONE raw cell (a vacant-slot half-window's centre is
  # still inside its full cell, and a leaf's centre — unlike its min-corner — never lands on a cell
  # boundary, so no corner ambiguity). BYTE-IDENTICAL to the old min-corner join on gap ≤ 8 (proven:
  # the golden-equiv / arrangement-bridge oracles stay green); it only RECOVERS the windows
  # min-corner silently dropped at gap ≥ 10 / col-mount. The FRAME the bridge carries is always
  # project's desired_frame (the impedance authority), never the raw cell geometry.
  # THE PER-CELL `contents` CAPACITY (S10 — the stack-structure slot). Each cell's
  # side-table entry carries, ALONGSIDE the bare { window_id, presented, frame } the
  # readers have always used, a z-ordered `contents` LIST — the persisted stack
  # structure. S10 persists a 1-DEEP contents (the single bound window IS the list's only
  # member, contents:[ the binding ]); S16 makes a deeper stack first-class. The bare
  # fields STAY so arrangement_targets reads contents[0] EXACTLY as it read the single
  # binding — a 1-deep contents bridges BYTE-IDENTICALLY at the window-keyed output (the
  # arrangement-bridge + golden-equiv tripwires), the capacity is persisted INERT. Keeps
  # the <display_id>:<i0>:<j0> anchor key (line-set re-keying is S15).
  | ( reduce ($bound[] | select(.presented == true and .frame != null)) as $b ({};
        ( ($b.frame.x + ($b.frame.w / 2)) ) as $cx | ( ($b.frame.y + ($b.frame.h / 2)) ) as $cy
        | ( [ $cells[]
              | select( (G::frame_min_x(.frame) <= $cx) and ($cx <= G::frame_max_x(.frame))
                    and (G::frame_min_y(.frame) <= $cy) and ($cy <= G::frame_max_y(.frame)) ) ][0] // null ) as $cell
        | if $cell == null then .
          else .[_anchor_key($cell)] = ($b + { contents: [ $b ] })
          end) ) as $bindings
  # OFF-TOP bound leaves: presented==false OR no frame — not a cell in the partition.
  | ( [ $bound[] | select((.presented == true and .frame != null) | not) ] ) as $off_top
  | { segments: $segs, bindings: $bindings, off_top: $off_top };

# ── bridge_arrangement_folded: the VALVE-FOLD-AS-CONTENTS sink (S16, R2 — option i) ──
# A PEER of bridge_arrangement: runs IDENTICALLY (same partition, same project frames,
# same anchor keys) EXCEPT for the stacked-cell SINK. Where bridge_arrangement homes a
# folded node's TOP to its cell (presented) and routes the SURPLUS to off_top
# (arrangement.jq:689), this variant collects the surplus into that cell's
# contents:[top, surplus…] and emits off_top:[] for that cell (the SURPLUS XOR-BUCKET
# discipline: surplus rides contents[1..] XOR off_top, NEVER both — _emit_at's off_top
# merge runs LAST and would otherwise OVERWRITE a contents entry).
#
# THE FOLD DECISION IS B::valve's, NEVER RE-DERIVED (option i — the only path that does
# not fork the valve, the #1 hazard). The input $foldedTree is B::valve's OUTPUT (its
# stack nodes ARE the fold decision, flipped mode:"stack" by _fold_node). For each stack
# node, the TOP / SURPLUS window split is read off B::valve's FACTS authority: the
# descendant bound leaves under the stack node, partitioned by P::project's presented bit
# (balance.jq:294-299 derives the facts from EXACTLY this post-reveal project) — top =
# the presented descendant leaf's window, surplus = the hidden descendant leaves' windows
# sorted. This is the SAME node→window mapping bridge_arrangement does (project + the
# node.window_id join). The z-ORDER (top first, then surplus) follows B::valve's facts,
# NOT rebind's head/tail convention — a focus reveal moves WHICH node is top, and reading
# it from project (never re-deriving) pins the parity invariant. ZERO min-fit / feasibility
# / `_required` arithmetic is added — the fold DECISION is balance::'s, this is a
# representation change ONLY.
def bridge_arrangement_folded($foldedTree; $topo):
  (P::norm_topology($topo)) as $T
  | ($foldedTree.nodes // {}) as $nodes
  | (bridge_arrangement($foldedTree; $topo)) as $base
  | (P::project($foldedTree; $topo)) as $proj
  # FP::stacks reads the stack inventory straight off the folded tree (the fold DECISION);
  # for each stack node, split its descendant bound leaves by project.presented → top/surplus
  # windows. Closure-over-the-node + project's presented bit IS balance.jq:294-299's facts.
  | ( [ FP::stacks($foldedTree)[]
        | .node as $nid
        | ( [ P::closure($nodes; [$nid]) | keys[]
              | select(P::is_leaf($nodes[.]) and (($nodes[.].window_id // null) != null)) ] ) as $dleaves
        | { top:     ( [ $dleaves[] | select(($proj.leaves[.].presented // false) == true)  | $nodes[.].window_id ] | .[0] // null ),
            surplus: ( [ $dleaves[] | select(($proj.leaves[.].presented // false) != true)   | $nodes[.].window_id ] | sort ) }
        | select(.top != null and ((.surplus | length) > 0)) ] ) as $folds
  # Route each fold's surplus into the cell whose top (contents[0] // the bare window_id) is
  # the fold's top — appended as {presented:false, frame:null} (matching reconcile.jq:194 /
  # targets_stack_top_hidden). The cell with no matching fold is carried verbatim.
  | ( ($base.bindings // {}) | to_entries | map(
        . as $kv
        | ( [ $folds[] | select(.top == ((($kv.value.contents // [])[0].window_id) // $kv.value.window_id)) ] | .[0] // null ) as $f
        | if $f == null then $kv
          else ($kv | .value.contents =
                  ( ($kv.value.contents // [ ($kv.value | del(.contents) | del(.nested)) ])
                    + [ $f.surplus[] | { window_id: ., presented: false, frame: null } ] ))
          end ) | from_entries ) as $bindings2
  # XOR-bucket: strip the routed surplus windows from off_top (they now live in contents).
  | ( [ $folds[] | .surplus[] ] | unique ) as $routed
  | ( ($base.off_top // []) | map(select((.window_id) as $w | ($routed | index($w)) == null)) ) as $off_top2
  | { segments: $base.segments, bindings: $bindings2, off_top: $off_top2 };

# ── bridge_arrangement_native: the LINE-NATIVE author (segments → frames, NO tree) ──
# A PEER of bridge_arrangement / bridge_arrangement_folded (S-P2, parcel-core S18). The
# steady-state author: given the PRIOR store ({segments, bindings, off_top}) and topology,
# re-author the store DIRECTLY from the carried segments — re-deriving each cell's frame —
# WITHOUT the cold tree round-trip (_prior_tree* → A::sync → bridge_arrangement). This is
# what makes a hand-dragged GRID / mixed-axis layout PERSIST: a gesture (move_line, B1's
# drag) edits the SEGMENTS but leaves the binding's .frame STALE, and this re-derivation is
# the settle's re-stamp (it SUBSUMES B1's `sync` re-author).
#
# THE GEOMETRY HALF is the EXISTING bridge_md_equiv shape — _bags (per-display homing +
# structural cross-seam exclusion) → cells (the union-find partition) → _inset_interior (the
# gap/2 interior gutter; raw cells abut at the segment centreline). PROVEN byte-equal to the
# cold from_floorplan→cells_md→inset on the slicing subset (the 6-scene fixpoint, design-lock
# 05). Each cell is tagged with its bag's display_id and anchor-keyed so it re-joins its prior
# binding: _anchor_key is INDEX-based ("<did>:<i0>:<j0>"), so it is STABLE under a move_line
# coord edit (same cell count, same atom indices, NEW geometry) — the binding follows its
# window to the re-shaped cell.
#
# THE MIN HALF is P::reach_bump(cell_frame; P::leaf_fit_min(binding)) — THE single clamp
# dialect (S-P0), the SAME factored primitive P::project's desired_frame uses. A bare binding
# carries NO min, so leaf_fit_min = {0,0} → reach_bump is a NO-OP — which is EXACTLY what the
# cold path does too (A::sync never stamps min; the strategy's bridge projects un-stamped, so
# stored frames are RAW, verified: a Chrome min-1200 scene stores at w:960). So the two
# byte-match even on a min-bound scene; the call stays for structural parity (if a future
# author path ever stamps min, both bump identically).
#
# SCOPE — the SLICING, NO-STACK, MANAGED-SET-UNCHANGED subset (the caller's $native_noop guard
# enforces it): every bound cell is a PRESENTED top (presented:true), contents is 1-deep, and
# off_top is carried VERBATIM (it is [] in this subset — the valve is opt-in/default OFF). A
# stack / adopt / prune store takes the cold path. segments are carried verbatim, preserving
# each segment's `relation:"pinned"` stickiness (the cold path re-derives the same marker via
# _prior_tree_structured; native keeps it for free). The derived frame is stamped onto BOTH
# the binding's .frame AND its contents[0].frame (B1 leaves contents[0].frame stale).
def bridge_arrangement_native($store; $topo):
  (P::norm_topology($topo)) as $T
  | ($T.gap // 0) as $gap
  | ($store.segments // []) as $segs
  | ($store.bindings // {}) as $pri
  | [ _bags($segs; $T)[]
      | .display_id as $did | .rect as $r
      | cells(.segments; $r)[]
      | (. + { display_id: $did }) as $c
      | { anchor: _anchor_key($c), frame: _inset_interior($c; $r; $gap), rect: $r } ] as $cells
  # ── C2 fix (2026-06-22, phase5-correctness-debt): make the AUTHOR re-key-aware,
  # SYMMETRIC with the readers. The reduce below keyed bindings by the EXACT anchor
  # only ($pri[$c.anchor]); a binding whose anchor matches no derived cell — a cell
  # re-keyed by a collinear-seam-cross move (1:4:1 → 1:3:1) — emitted NOTHING and was
  # silently DROPPED, while the sibling readers carryable_windows / arrangement_targets
  # resolve it via _rekey_resolve (arrangement.jq:1366). That author-vs-reader asymmetry
  # let $live == $prior_bound hold (the rekey-aware readers recover the window, so
  # native_noop fired) while the author dropped it → window loss. Thread the SAME
  # _rekey_resolve fallback BEHIND the exact-key lookup: it is EMPTY on every key-matching
  # scene (byte-INERT — the golden/roundtrip/bridge locks hold), firing ONLY for a cell
  # whose exact key missed, matching the unclaimed binding it overlaps most. A genuinely
  # COLLAPSED cell overlaps no binding → no match → still dropped (C1's distinct zero-width
  # collapse is fixed upstream at the drag carry-gate, never resurrected here).
  | (_rekey_resolve([ $cells[] | . + { lk: .anchor } ]; $pri)) as $fallback
  | ( reduce $cells[] as $c ({};
        (($pri[$c.anchor]) // ($fallback[$c.anchor]) // null) as $b
        | if $b == null then .                       # vacant cell (no binding) — no entry
          else
            (P::leaf_fit_min($b)) as $min
            # Z-DEMOTION (Z-1, design doc 12): a cell below its floor on EXACTLY one
            # axis whose squeezed side has a settle-stamped demotable face (the
            # same-app author gate) takes a SLIDE-UNDER frame (P::slide_under —
            # min-sized, overlapping ACROSS the face into the neighbour, in-display)
            # instead of the origin-preserving reach_bump poke. demoted/under are
            # DERIVED here each re-derive — re-merge is this condition going false
            # (cell regrows ≥ min), no special path. `under` = the across-face
            # neighbour's WINDOW id (the diff's assert_under pair + the executor's
            # raise target). No demotable_faces stamped (the gate off) → the
            # reach_bump arm below → byte-identical to pre-Z1 (the locks).
            | (($b.demotable_faces // [])) as $dfaces
            | (($c.frame.w + TOL) < $min.w) as $below_w
            | (($c.frame.h + TOL) < $min.h) as $below_h
            | ( if ($dfaces | length) > 0 and ($below_w != $below_h)   # exactly one axis squeezed
                then ( if $below_w then [ $dfaces[] | select(. == "left" or . == "right") ]
                       else            [ $dfaces[] | select(. == "above" or . == "below") ] end ) | .[0] // null
                else null end ) as $dface
            | ( if $dface == null then null
                else
                  ($c.frame) as $cf
                  # the probe steps PAST the inset gutter: bridge cells are
                  # gap/2-inset, so adjacent inset frames sit $gap apart —
                  # +1 alone would land in the gutter and miss the neighbour.
                  | ($gap + 1) as $step
                  | ( if   $dface == "left"  then { x: ($cf.x - $step),          y: ($cf.y + $cf.h / 2) }
                      elif $dface == "right" then { x: ($cf.x + $cf.w + $step),  y: ($cf.y + $cf.h / 2) }
                      elif $dface == "above" then { x: ($cf.x + $cf.w / 2),  y: ($cf.y - $step) }
                      else                        { x: ($cf.x + $cf.w / 2),  y: ($cf.y + $cf.h + $step) } end ) as $p
                  | ( [ $cells[] | select( (.anchor != $c.anchor)
                          and ((.anchor | split(":")[0]) == ($c.anchor | split(":")[0]))
                          and (.frame.x - TOL <= $p.x) and ($p.x <= .frame.x + .frame.w + TOL)
                          and (.frame.y - TOL <= $p.y) and ($p.y <= .frame.y + .frame.h + TOL) ) ][0] // null ) as $nc
                  | ( if $nc == null then null else (($pri[$nc.anchor] // {}).window_id // null) end )
                end ) as $under
            | ( if ($dface != null) and ($under != null)
                then { f: P::slide_under($c.frame; $min; $dface; $c.rect),
                       dx: { demoted: true, under: $under } }
                else { f: P::reach_bump($c.frame; $min), dx: {} } end ) as $fd
            | ($fd.f) as $f | ($fd.dx) as $dx
            # P-MIN M2: RE-EMIT the prior binding's persisted floor (it was
            # already CONSUMED by the bump/slide above — dropping it here made
            # the very next native settle clamp-blind and re-derive the raw
            # frame, the FOLLOWUPS settle-2 class). Key omitted when absent:
            # a min-less store rebuilds byte-identically (the locks). The
            # demotable_faces stamp re-emits the SAME way (the Z-1 keystone —
            # the native author would otherwise silently strip it each settle);
            # demoted/under ride contents[0] too, so arrangement_targets carries
            # them to the diff with no emitter change.
            | (($b.min_size // (($b.contents // [])[0].min_size) // null)) as $ms
            | (if $ms != null then { min_size: $ms } else {} end) as $msx
            | (if ($dfaces | length) > 0 then { demotable_faces: $dfaces } else {} end) as $dfx
            | .[$c.anchor] = ( { window_id: $b.window_id, presented: true, frame: $f,
                                 contents: [ ({ window_id: $b.window_id, presented: true, frame: $f } + $msx + $dx) ] }
                               + $msx + $dx + $dfx )
          end) ) as $bindings
  | { segments: $segs, bindings: $bindings, off_top: ($store.off_top // []) };

# ── stamp_demotable (z-demotion Z-1, the M5 author gate): settle-stamped faces ──
# For each bound cell, mark the faces whose ACROSS-the-line neighbour shares an
# app identity (pid // bundle_id // app from $obs) — the only sides a divider may
# demote past, evaluated FRESH each settle (the M2 min-stamp pattern: stamped
# onto the pre-bridge store, re-emitted by the native author, naturally re-derived
# after any cold rebuild). Gated by the strategy ($cfg.demote): never called when
# the zdemote knob is off, so an off store is byte-identical. Face names are the
# reclaim-dir vocabulary (the neighbour's direction). Identity-less windows and
# vacant/reserved cells never stamp.
def stamp_demotable($store; $obs; $T):
  (cells_md(($store.segments // []); $T)) as $cells
  | ($store.bindings // {}) as $binds
  | ( reduce (($obs // [])[]) as $w ({};
        if ($w.window_id // null) == null then .
        else .[$w.window_id | tostring] = ($w.pid // $w.bundle_id // $w.app // null) end) ) as $ident
  | ($store
     | .bindings = ( $binds | with_entries(
         .key as $ak
         | (.value.window_id // null) as $wid
         | ( [ $cells[] | select(_anchor_key(.) == $ak) ][0] // null ) as $cell
         | ($ident[$wid | tostring] // null) as $me
         | ( if ($wid == null) or ($cell == null) or ($me == null) then []
             else
               ($cell.frame) as $f
               | ($ak | split(":")[0]) as $did
               | [ [ [ "left",  { x: ($f.x - 1),         y: ($f.y + $f.h / 2) } ],
                     [ "right", { x: ($f.x + $f.w + 1),  y: ($f.y + $f.h / 2) } ],
                     [ "above", { x: ($f.x + $f.w / 2),  y: ($f.y - 1) } ],
                     [ "below", { x: ($f.x + $f.w / 2),  y: ($f.y + $f.h + 1) } ] ][]
                   | .[0] as $face | .[1] as $p
                   | ( [ $cells[] | select( ((.display_id | tostring) == $did)
                           and (_anchor_key(.) != $ak)
                           and (.frame.x - TOL <= $p.x) and ($p.x <= .frame.x + .frame.w + TOL)
                           and (.frame.y - TOL <= $p.y) and ($p.y <= .frame.y + .frame.h + TOL) ) ][0] // null ) as $nc
                   | ( if $nc == null then null
                       else ($ident[(($binds[_anchor_key($nc)] // {}).window_id // null) | tostring] // null) end ) as $other
                   | ( if ($other != null) and ($other == $me) then $face else empty end ) ]
             end ) as $faces
         | .value |= ( del(.demotable_faces)
                       + (if ($faces | length) > 0 then { demotable_faces: $faces } else {} end) ) )));

# ════════════════════════════════════════════════════════════════════════════
# S-P3 — THE NATIVE PRUNE AUTHOR ("reclaim where clean"). See
# docs/history/parcel-core/06-sp3-prune-design-lock.md. A managed window LEFT a MIXED-AXIS
# (grid) store; reclaim its space line-natively (so the grid SURVIVES, where the cold
# path flattens it). The strategy's $native_prune guard restricts the input to: ONE
# goner, no newcomer, the goner's display mixed-axis, no stack/promotion/nested. This
# author composes the SAME substrate as bridge_arrangement_native — cells_md / incident
# / _anchor_key / valid_md + the reach_bump clamp via bridge_arrangement_native — and
# adds NO geometry/clamp dialect.
#
# THE MECHANIC (per the design-lock): collapse the goner's cell into a neighbour by
# editing ONE divider's span (drop a LOCAL divider, or shrink/split a SHARED gridline so
# a neighbour absorbs the freed cell), then RE-KEY survivors by display-constrained
# geometric containment, then DERIVE frames via bridge_arrangement_native. If no clean
# reclaim edit yields a valid partition, leave a RESERVED HOLE (vacate the goner's cell —
# the next window fills it, S-P4). Three safety teeth return null → the strategy routes
# the whole settle to COLD: (1) re-key MISS (0 cells), (2) re-key COLLISION (>1 cells or
# two survivors → one anchor), (3) valid_md failure. Tooth (2) — survivor-conservation —
# is the keystone the adversarial pass added: the cold path NEVER loses a window, so a
# native author that might must fall back rather than silently drop.




# ── _prune_rekey: display-constrained geometric re-key of survivors onto a new bag ─
# Each survivor's PRIOR frame centre → the new cell (on its OWN prior display) that
# contains it. Returns the re-keyed bindings object, or null on MISS / COLLISION /
# non-conservation (design Amend. A + B). $surv = survivor binding ENTRIES (goner removed).
def _prune_rekey($new_segs; $T; $surv):
  (cells_md($new_segs; $T)) as $nc
  | ( reduce $surv[] as $b ({ ok: true, m: {} };
        if (.ok | not) then .
        else
          ($b.value.frame) as $f
          | (($f.x + ($f.w / 2))) as $cx | (($f.y + ($f.h / 2))) as $cy
          | ($b.key | split(":")[0]) as $did
          | ( [ $nc[]
                | select( ((.display_id | tostring) == $did)
                          and (G::frame_min_x(.frame) <= $cx) and ($cx <= G::frame_max_x(.frame))
                          and (G::frame_min_y(.frame) <= $cy) and ($cy <= G::frame_max_y(.frame)) ) ] ) as $cand
          | if ($cand | length) != 1 then { ok: false, m: {} }          # 0 = MISS, >1 = COLLISION
            else (_anchor_key($cand[0])) as $ak
              | if (.m | has($ak)) then { ok: false, m: {} }              # two survivors → one cell
                else { ok: true, m: (.m + { ($ak): $b.value }) }
                end
            end
        end ) ) as $r
  | if ($r.ok and (($r.m | length) == ($surv | length))) then $r.m else null end;

# ════════════════════════════════════════════════════════════════════════════
# RECLAIM POLICY `even` (reclaim-policy-even-default). See
# docs/contracts/reclaim-policy.md. The default reclaim policy:
# split the goner's freed span EQUALLY across the run of survivor cells sharing
# its top+bottom gridlines (a row-run, spread "h"), else — when the goner spans a
# full row edge-to-edge — across the column-run sharing its left+right gridlines
# (spread "v"). These three helpers compose a NEW candidate generator for
# bridge_arrangement_native_prune, layered IN FRONT of the existing absorber pool;
# if none of them yields a valid candidate the dispatch falls through to the
# proven _reclaim_edit → _reclaim_grow_edit → COLD chain, so `even` can never hole
# or drop a window (it reuses valid_md + the exact-cell-count gate + a
# conservation-checked rekey, exactly like the absorber generators).

# ── _reclaim_run: the run of cells sharing the goner's two perpendicular gridlines ─
# $spread "h" → row-run (cells sharing the goner's TOP+BOTTOM gridlines, spread the
# freed width horizontally); "v" → column-run (LEFT+RIGHT gridlines, spread vertically).
# Returns { spread, gdid, plo, phi (the two shared gridline coords), lo, hi (the run's
# extent along the spread axis), survivors (the run cells MINUS the goner, in spread
# order), count } — or null when there is no CLEAN run with ≥1 survivor (no neighbour
# shares both gridlines = a full-row goner on this axis; or the strip is non-contiguous,
# i.e. a neighbour of a different height interleaves → leave it to the other axis / absorber).
def _reclaim_run($segs; $g; $gdid; $T; $spread):
  (cells_md($segs; $T)) as $cells
  # CELL CONVENTION (empirical): a cell edge sits EXACTLY on an interior gridline (adjacent cells
  # abut, edge_i.max == edge_{i+1}.min == coord) and is inset by the gap only at a canvas/gutter
  # edge. So cell edges ARE the divider coords at interior gridlines — no offset, and the even
  # midpoint of the cell-edge extent is the correct new divider coord.
  | (G::frame_min_x($g)) as $gx0 | (G::frame_max_x($g)) as $gx1
  | (G::frame_min_y($g)) as $gy0 | (G::frame_max_y($g)) as $gy1
  # the STRIP: every cell on the goner's display whose two perpendicular faces == the goner's
  # (shares BOTH gridlines), sorted along the spread axis.
  | ( [ $cells[]
        | select((.display_id | tostring) == $gdid)
        | .frame as $f
        | select( if $spread == "h"
                  then (G::fabs(G::frame_min_y($f) - $gy0) <= TOL) and (G::fabs(G::frame_max_y($f) - $gy1) <= TOL)
                  else (G::fabs(G::frame_min_x($f) - $gx0) <= TOL) and (G::fabs(G::frame_max_x($f) - $gx1) <= TOL) end ) ]
      | sort_by( if $spread == "h" then G::frame_min_x(.frame) else G::frame_min_y(.frame) end ) ) as $strip
  | if ($strip | length) < 2 then null                            # goner alone in its band → no run on this axis
    else
      # CONTIGUITY: consecutive strip cells ABUT at a gridline (far edge == next near edge). A
      # gap here = a different-height neighbour interleaves (non-clean strip) → decline → absorber.
      ( [ range(0; ($strip | length) - 1) as $i
          | (if $spread == "h" then G::frame_max_x($strip[$i].frame)   else G::frame_max_y($strip[$i].frame)   end) as $cur
          | (if $spread == "h" then G::frame_min_x($strip[$i+1].frame) else G::frame_min_y($strip[$i+1].frame) end) as $nxt
          | select(G::fabs($nxt - $cur) > TOL) ] | length ) as $breaks
      | if $breaks > 0 then null
        else
          # the run's perpendicular band ($plo,$phi = the two shared gridlines) and spread extent
          # ($lo,$hi = first cell near edge .. last cell far edge) — all cell-edge coords.
          (if $spread == "h" then $gy0 else $gx0 end) as $plo
          | (if $spread == "h" then $gy1 else $gx1 end) as $phi
          | (if $spread == "h" then G::frame_min_x($strip[0].frame)  else G::frame_min_y($strip[0].frame)  end) as $lo
          | (if $spread == "h" then G::frame_max_x($strip[-1].frame) else G::frame_max_y($strip[-1].frame) end) as $hi
          # survivors = strip minus the goner (the cell whose origin == the goner's)
          | ( [ $strip[]
                | select( (G::fabs(G::frame_min_x(.frame) - $gx0) > TOL) or (G::fabs(G::frame_min_y(.frame) - $gy0) > TOL) ) ] ) as $survc
          | if (($strip | length) - ($survc | length)) != 1 then null      # exactly the goner removed
            else { spread: $spread, gdid: $gdid, plo: $plo, phi: $phi, lo: $lo, hi: $hi, survivors: $survc, count: ($survc | length) }
            end
        end
    end;

# ── _reclaim_spread_edit: re-space a run across N survivors → edited segment bag ──
# The shared SPREAD generator for `even` and `proportional`. Compose _reclaim_run, then rewrite
# the run's interior dividers so the N survivors partition the run extent by WEIGHT: $mode "even"
# → equal weights (each grows by freed/N); "proportional" → weight = each survivor's CURRENT size
# along the spread axis (each grows in proportion, preserving the size hierarchy; degrades to even
# when the survivors started equal). Returns { segs, local:false, run } — the same { segs, local }
# candidate shape _reclaim_edit/_reclaim_grow_edit return (the caller validates end-to-end + rekeys),
# plus `run` for the ordinal rekey. Returns null when: there is no clean run; an interior divider is
# hand-PINNED (relation=="pinned" → respect it); a divider span extends past the band (collinear with
# another band); or any survivor's WEIGHTED share would drop below its learned min floor
# (SPREAD-WHERE-FEASIBLE — declined → the absorber path, which only grows, handles it). $binds = the
# current bag's bindings (the per-survivor min lookup, anchor-keyed like the cells _reclaim_run returns).
def _reclaim_spread_edit($segs; $g; $gdid; $T; $spread; $binds; $mode):
  (_reclaim_run($segs; $g; $gdid; $T; $spread)) as $run
  | if $run == null then null
    else
      ($run.lo) as $lo | ($run.hi) as $hi | ($run.plo) as $plo | ($run.phi) as $phi | ($run.count) as $N
      | (if $spread == "h" then "v" else "h" end) as $dax           # the divider axis we re-space
      | ($T.gap // 0) as $gap
      # the run's interior dividers (between its cells): axis $dax, coord strictly inside the run's
      # spread-extent, span OVERLAPPING the band. (Segment spans are gap-INSET at gutter/canvas
      # edges — e.g. a full right-column divider is [960,1912] for a [960,1920] band — so match by
      # OVERLAP, not full coverage.)
      | ( [ $segs | to_entries[]
            | select( (.value.axis == $dax)
                      and (.value.coord > $lo + TOL) and (.value.coord < $hi - TOL)
                      and (.value.lo < $phi - TOL) and (.value.hi > $plo + TOL) ) ] ) as $interior
      | if ($interior | length) == 0 then null
        elif any($interior[]; .value.relation == "pinned") then null                              # respect pinned
        elif any($interior[]; (.value.lo < $plo - $gap - TOL) or (.value.hi > $phi + TOL)) then null  # a span past the band = a collinear divider shared with another band → decline
        else
          # WEIGHTS along the spread axis: even = equal; proportional = current cell sizes.
          ( [ $run.survivors[] | (if $spread == "h" then .frame.w else .frame.h end) ] ) as $sizes
          | ( if $mode == "proportional" then $sizes else [ range(0; $N) | 1 ] end ) as $weights
          | ( [ $weights[] ] | add ) as $wsum
          | ( [ range(0; $N) | (($hi - $lo) * ($weights[.] / $wsum)) ] ) as $newsizes
          # SPREAD-WHERE-FEASIBLE: decline if any survivor's weighted share drops below its floor.
          | ( [ range(0; $N) as $k
                | (($binds[_anchor_key($run.survivors[$k])].min_size)
                   // (($binds[_anchor_key($run.survivors[$k])].contents // [])[0].min_size) // {}) as $ms
                | { ns: $newsizes[$k], mn: (if $spread == "h" then ($ms.w // 0) else ($ms.h // 0) end) } ] ) as $fit
          | if any($fit[]; (.ns + TOL) < .mn) then null
            else
              ($interior | map(.key)) as $ikeys
              # new dividers carry the band SPAN of the removed interior dividers (copy, don't
              # recompute — preserves the gap-inset-at-edges convention exactly); coords are the
              # cumulative survivor sizes from $lo (N-1 interior dividers).
              | { lo: ([ $interior[].value.lo ] | min), hi: ([ $interior[].value.hi ] | max) } as $span
              # interior divider coords. even uses the DIRECT formula ($lo + i*W) — byte-identical to
              # the Phase-1 author (a cumulative reduce drifts ~1 ULP for non-terminating shares, which
              # falsifies the even-byte-unchanged provenance even though it's <1e-13px; adversarial-
              # review LOW). proportional needs the cumulative running sum of its unequal shares.
              | ( if $mode == "even"
                  then [ range(1; $N) | $lo + (. * (($hi - $lo) / $N)) ]
                  else ( reduce range(0; $N - 1) as $k ({ acc: $lo, ds: [] };
                           (.acc + $newsizes[$k]) as $c | { acc: $c, ds: (.ds + [$c]) } ) | .ds ) end ) as $coords
              | { run: $run, local: false,
                  segs: ( [ $segs | to_entries[] | select(.key as $k | ($ikeys | index($k)) == null) | .value ]
                          + [ $coords[] | { axis: $dax, coord: ., lo: $span.lo, hi: $span.hi } ] ) }
            end
        end
    end;

# thin wrapper: `even` = the equal-weight spread (Phase-1 default; the unit harness calls this name).
def _reclaim_even_edit($segs; $g; $gdid; $T; $spread; $binds):
  _reclaim_spread_edit($segs; $g; $gdid; $T; $spread; $binds; "even");

# ── bridge_arrangement_native_prune: the S-P3 author (returns null → cold) ─────
# Returns { arr: <bridged store>, absorber: <wid|null> } or null. `absorber` is the
# survivor whose post-reclaim cell contains the goner cell's centre — i.e. the window
# that took the freed space (null on the reserved-hole branch, where the space stays
# vacant). It rides OUTSIDE the store so the persisted arrangement stays byte-identical;
# the strategy threads it into the prune fact (close-refocus A1).
def _reclaim_even_rekey($new_segs; $T; $surv; $run):
  ($run.gdid) as $gdid | ($run.spread) as $spread
  | ($run.plo) as $plo | ($run.phi) as $phi | ($run.lo) as $lo | ($run.hi) as $hi
  | (cells_md($new_segs; $T)) as $nc
  # _prune_rekey's centre-containment is WRONG for `even` — every run survivor MOVES, so
  # their old centres collide. Re-key the RUN survivors ORDINALLY (the equal re-spacing
  # preserves left→right / top→bottom order, so survivor i → new run cell i); the NON-run
  # survivors (untouched cells) by centre-containment. Same conservation teeth as _prune_rekey.
  # The new run cells = the (inset) cells wholly inside the TRUE run rect [lo,hi]x[plo,phi];
  # only run cells lie there (gap-agnostic — no inset-vs-gridline coincidence assumed).
  # spread "h": run extends along X (lo,hi), perpendicular Y (plo,phi). "v" swaps the axes.
  | ( [ $nc[] | select((.display_id | tostring) == $gdid)
        | .frame as $f
        | select( if $spread == "h"
                  then (G::frame_min_x($f) >= $lo - TOL) and (G::frame_max_x($f) <= $hi + TOL)
                       and (G::frame_min_y($f) >= $plo - TOL) and (G::frame_max_y($f) <= $phi + TOL)
                  else (G::frame_min_y($f) >= $lo - TOL) and (G::frame_max_y($f) <= $hi + TOL)
                       and (G::frame_min_x($f) >= $plo - TOL) and (G::frame_max_x($f) <= $phi + TOL) end ) ]
      | sort_by( if $spread == "h" then G::frame_min_x(.frame) else G::frame_min_y(.frame) end ) ) as $runcells
  | ( [ $run.survivors[] | _anchor_key(.) ] ) as $ranch          # run survivors (current anchors), run order
  | if ($runcells | length) != ($ranch | length) then null
    else
      ( reduce range(0; ($ranch | length)) as $i ({};
          ( [ $surv[] | select(.key == $ranch[$i]) ][0] ) as $sb
          | if $sb == null then . else . + { (_anchor_key($runcells[$i])): $sb.value } end ) ) as $runmap
      | if ($runmap | length) != ($ranch | length) then null     # a run survivor had no binding → bail
        else
          ( [ $surv[] | select(.key as $k | ($ranch | index($k)) == null) ] ) as $rest
          | ( reduce $rest[] as $b ({ ok: true, m: $runmap };
                if (.ok | not) then .
                else
                  ($b.value.frame) as $f | (($f.x + ($f.w / 2))) as $cx | (($f.y + ($f.h / 2))) as $cy
                  | ($b.key | split(":")[0]) as $did
                  | ( [ $nc[] | select( ((.display_id | tostring) == $did)
                          and (G::frame_min_x(.frame) <= $cx) and ($cx <= G::frame_max_x(.frame))
                          and (G::frame_min_y(.frame) <= $cy) and ($cy <= G::frame_max_y(.frame)) ) ] ) as $cand
                  | if ($cand | length) != 1 then { ok: false, m: {} }       # 0 = MISS, >1 = COLLISION
                    else (_anchor_key($cand[0])) as $ak
                      | if (.m | has($ak)) then { ok: false, m: {} } else { ok: true, m: (.m + { ($ak): $b.value }) } end
                    end
                end ) ) as $r
          | if ($r.ok and (($r.m | length) == ($surv | length))) then $r.m else null end
        end
    end;

# ── _absorber_of: which survivor took the goner's space (goner-centre containment) ──
# Shared by the `absorber` pick (the window the freed cell merged into) and the `focus` policy
# (pick the candidate whose absorber IS the focused window). Returns the window_id or null.
def _absorber_of($cand; $gf; $gdid; $T):
  (($gf.x + ($gf.w / 2))) as $gcx | (($gf.y + ($gf.h / 2))) as $gcy
  | ( [ cells_md($cand.segs; $T)[]
        | select( ((.display_id | tostring) == $gdid)
                  and (G::frame_min_x(.frame) <= $gcx) and ($gcx <= G::frame_max_x(.frame))
                  and (G::frame_min_y(.frame) <= $gcy) and ($gcy <= G::frame_max_y(.frame)) ) ][0] // null ) as $acell
  | if $acell == null then null else ($cand.binds[_anchor_key($acell)].window_id // null) end;

def bridge_arrangement_native_prune($store; $goners; $focused; $topo; $policy):
  (P::norm_topology($topo)) as $T
  | ($policy // "absorber") as $pol
  | (($focused | tostring | ltrimstr("w:") | (tonumber? // null))) as $fw   # focused window_id (for `focus`)
  | ($store.segments // []) as $segs
  | ($store.bindings // {}) as $binds
  | if ($goners | length) != 1 then null                                 # one goner only (Amend. C)
    else
      ($goners[0]) as $gw
      | ( [ $binds | to_entries[] | select(.value.window_id == $gw) ][0] // null ) as $ge
      | if $ge == null then null                                         # goner not bound → cold
        else
          ($ge.key) as $gk
          | (cells_md($segs; $T)) as $cur_cells
          | ( [ $cur_cells[] | select(_anchor_key(.) == $gk) ][0] // null ) as $gcell
          | if $gcell == null then null                                  # goner cell not found → cold
            else
              ($gcell.frame) as $gf
              | ($cur_cells | length) as $ncells0
              | ( [ $binds | to_entries[] | select(.value.window_id != $gw) ] ) as $surv
              | ($gk | split(":")[0]) as $gdid
              # SPREAD POLICIES (`even` | `proportional`): a PREFERRED candidate layered IN FRONT of
              # the absorber pool. Try the row-run ("h") then the column-run ("v"); each spread edit
              # goes through the SAME valid_md + exact-cell-count gates, plus the ordinal spread-rekey
              # (conservation-checked; order is preserved by weighted placement). Empty when $pol is
              # neither spread mode or no clean run applies → the absorber pool below is used UNCHANGED.
              | ( if ($pol == "even" or $pol == "proportional")
                  then [ "h", "v"
                         | . as $sp | (_reclaim_spread_edit($segs; $gf; $gdid; $T; $sp; $binds; $pol)) as $e
                         | select($e != null)
                         | (valid_md($e.segs; $T)) as $v | select($v.ok)
                         | select((cells_md($e.segs; $T) | length) == ($ncells0 - 1))
                         | (_reclaim_even_rekey($e.segs; $T; $surv; $e.run)) as $rk
                         | select($rk != null)
                         # N==1 (single run survivor) degenerates to absorber geometry — name that lone
                         # survivor so the close-refocus A1 fact keeps its absorber (else null = no single
                         # absorber, the genuine N>=2 spread). Adversarial-review LOW finding.
                         | ( if $e.run.count == 1 then ($binds[_anchor_key($e.run.survivors[0])].window_id // null) else null end ) as $sabs
                         | { dir: ("spread-" + $sp), local: false, segs: $e.segs, binds: $rk, spread_absorber: $sabs } ]
                  else [] end ) as $spread_cands
              # candidate reclaim edits (one per interior face), validated end-to-end
              | ( [ ("below","above","right","left")
                    | . as $dir | (_reclaim_edit($segs; $gf; $dir)) as $e
                    | select($e != null)
                    | (valid_md($e.segs; $T)) as $v
                    | select($v.ok)
                    | select((cells_md($e.segs; $T) | length) == ($ncells0 - 1))   # exactly the goner cell merged
                    | (_prune_rekey($e.segs; $T; $surv)) as $rk
                    | select($rk != null)
                    | { dir: $dir, local: $e.local, segs: $e.segs, binds: $rk } ] ) as $simple_cands
              # GRID-PRESERVING GROW (no-holes): when NO single-face merge is valid — the goner
              # sits against a SUBDIVIDED neighbour, so dropping the shared divider would dangle
              # its perpendiculars — grow the sub-cells INTO the freed space (extend those
              # perpendiculars). Tried ONLY as a fallback, so every clean single-face case stays
              # byte-identical (simple_cands non-empty ⇒ grow_cands empty ⇒ $valid_cands unchanged).
              | ( if ($simple_cands | length) > 0 then []
                  else [ ("below","above","right","left")
                         | . as $dir | (_reclaim_grow_edit($segs; $gf; $dir)) as $e
                         | select($e != null)
                         | (valid_md($e.segs; $T)) as $v
                         | select($v.ok)
                         | select((cells_md($e.segs; $T) | length) == ($ncells0 - 1))
                         | (_prune_rekey($e.segs; $T; $surv)) as $rk
                         | select($rk != null)
                         | { dir: $dir, local: false, segs: $e.segs, binds: $rk } ] end ) as $grow_cands
              | ( if ($simple_cands | length) > 0 then $simple_cands else $grow_cands end ) as $valid_cands
              # PICK: prefer LOCAL (cleanest), then vertical-first (below>above>right>left).
              # The dir order is TOTAL (one candidate per dir) so no tie survives — the
              # design's larger-area/lowest-wid tie-break (Amend. E) is therefore vacuous here.
              | ( [ $valid_cands[] | select(.local) ] ) as $loc
              | ( if ($loc | length) > 0 then $loc else $valid_cands end ) as $pool
              | ( { below: 0, above: 1, right: 2, left: 3 } ) as $ord
              # `focus`: pick the absorber candidate that grows the FOCUSED window (_absorber_of == $fw);
              # null when focus isn't selected, $fw is unknown, or the focused window isn't a goner-
              # neighbour → fall through to the default absorber pick.
              | ( if ($pol == "focus") and ($fw != null)
                  then ( [ $pool[] | select(_absorber_of(.; $gf; $gdid; $T) == $fw) ][0] // null )
                  else null end ) as $focus_pick
              # PICK: prefer a SPREAD candidate (row-run first, then column-run) when it cleanly applies;
              # else the `focus` candidate; else the proven local-then-vertical absorber pick.
              | ( ( if ($spread_cands | length) > 0 then $spread_cands[0]
                    elif $focus_pick != null then $focus_pick
                    else ($pool | sort_by($ord[.dir]) | .[0]) end ) // null ) as $pick
              # ABSORBER: a spread pick has no single absorber (N==1 names the lone survivor); an
              # absorber/focus pick names the survivor the freed cell merged into (goner-centre).
              | ( if $pick == null then null
                  elif ($pick.dir | startswith("spread")) then ($pick.spread_absorber // null)
                  else _absorber_of($pick; $gf; $gdid; $T) end ) as $absorber
              | ( if $pick != null
                  then { segments: $pick.segs, bindings: $pick.binds, off_top: [], promotions: [] }
                  else null    # NO clean reclaim AND no valid grow → route to COLD (no-hole re-tile).
                               # NOT a reserved hole: Wave-1 retired the adopt fill-hole arm (a newcomer
                               # splits a real cell, never fills a hole), so a reserved hole is now
                               # PERMANENT — inconsistent with no-holes. Cold re-tiles the survivors
                               # gap-free (window-conserving), flattening the grid only in this last-
                               # resort case (the grow above preserves the grid whenever it can).
                  end ) as $authored
              | if $authored == null then null
                else { arr: bridge_arrangement_native($authored; $topo), absorber: $absorber }
                end
            end
        end
    end;

# ════════════════════════════════════════════════════════════════════════════
# S-P4 — THE NATIVE ADOPT AUTHOR (the newcomer twin of S-P3 prune). See
# docs/history/parcel-core/07-sp4-adopt-design-lock.md. A managed window ARRIVES into a
# MIXED-AXIS (grid) store; place it line-natively so the grid SURVIVES + GROWS,
# where the cold path flattens AND loses windows. The strategy's $native_adopt guard
# restricts input to: ONE newcomer, no goner, the newcomer's-display mixed-axis, no
# stack/promotion/nested. EVERYTHING is scoped to the newcomer's HOME display $ndid
# (Amend. A–D — never touch a sibling display, mirroring S-P3's display-constrained
# re-key). INSERT a split segment at the anchor cell (focused-on-$ndid else
# lex-first-on-$ndid), occupant→before / newcomer→after — the newcomer ALWAYS splits
# a real bound cell and the grid re-stretches; there is NO hole-first fill (fork 4,
# no-holes — the adopt fill-hole bias was retired in Wave 1). Safety teeth → null → cold:
# re-key MISS/COLLISION (_prune_rekey), FULL-SET conservation (Amend. E — catches the
# by-containment occupant, which the hit-count tooth is blind to), valid_md, and the
# newcomer-lands-on-$ndid belt (Amend. D). NO new clamp dialect, NO lineops (coord-wise
# id-less insert, byte-consistent with cold's bridge + S-P3).

# ── home_display: the display the engine homes a window to (THE canonical rule) ─
# Wraps G::assign_display for the strategy (which imports AR, not G), so $ndid agrees with the
# SAME homing $live/$newcomers use via A::partition→assign_display (max usable-overlap → frame-
# overlap → lowest-id). A bespoke center-containment rule diverges on a seam / an inter-display
# gap / usable≠frame and would home a newcomer to a DIFFERENT display than the rest of the engine
# (a wrong-display adopt; the impl adversarial pass's CRITICAL-1). Accepts a frame [x,y,w,h] or
# {x,y,w,h}; assign_display's own lowest-id fallback handles a null/degenerate frame.
def home_display($frame; $T):
  ( if ($frame | type) == "array" then { x: $frame[0], y: $frame[1], w: $frame[2], h: $frame[3] } else $frame end ) as $f
  | G::assign_display($f; $T.displays) ;

# @canonical observed_bindings_stay_on_display -- native steady-state authors must
# use this predicate before treating an unchanged managed window set as a no-op.
# A window can keep the same identity while a mouse drag changes its observed home
# display. In that case the stored binding key is stale and the strategy must fall
# through to A::sync, whose rehome path removes it from the source mount and adopts
# it into the destination mount. Require one observation and one binding per managed
# window so malformed/ambiguous input fails closed to the cold author. Display homing
# delegates to home_display above, preserving the canonical max-overlap/lowest-id seam
# rule rather than inventing a strategy-local center test.
def observed_bindings_stay_on_display($store; $observed; $managed; $T):
  ( reduce ((($store.bindings // {}) | to_entries[])) as $binding ({};
      ($binding.value.window_id // null) as $wid
      | if $wid == null then .
        else ($wid | tostring) as $key
          | .[$key] = {
              count: ((.[$key].count // 0) + 1),
              display: ($binding.key | split(":")[0])
            }
        end) ) as $bound
  | ( reduce $observed[] as $window ({};
      ($window.window_id // null) as $wid
      | if $wid == null then .
        else ($wid | tostring) as $key
          | .[$key] = {
              count: ((.[$key].count // 0) + 1),
              display: (home_display($window.frame; $T) | tostring)
            }
        end) ) as $seen
  | all($managed[];
      (tostring) as $key
      | ($bound[$key].count == 1)
        and ($seen[$key].count == 1)
        and (($bound[$key].display | tostring) == $seen[$key].display));

# ── _strip_binds: reduce a binding map to bare { anchor: {window_id} } ─────────
# bridge_arrangement_native re-derives frame/contents/presented from window_id, so the
# adopt author only needs to key window_ids onto the right cells; the rest is derived.
def _strip_binds($m):
  [ $m | to_entries[] | select(.value.window_id != null) | { key, value: { window_id: .value.window_id } } ] | from_entries;

# ── bridge_arrangement_native_adopt: the S-P4 author (returns null → cold) ─────
# Experimental D15 policy: raw allocated area, then top/left/stable anchor.
# These tie details are proposals; the live five-argument author keeps its policy.
# Shared native-author admission predicate (also used by the live strategy).
def is_flat($t):
  ((($t.off_top // []) | length) == 0)
  and (all(($t.bindings // {})[]?; (((.contents // [.]) | length) <= 1)))
  and ((($t.promotions // []) | length) == 0)
  and (all(($t.bindings // {})[]?; (has("nested") | not)));

# @canonical largest_first_insertion_target -- rank bound raw cells, never AX frames.
def _largest_first_insertion_target($bound_cells):
  $bound_cells | sort_by([-(.c.frame.w * .c.frame.h), .c.frame.y, .c.frame.x, .k]) | .[0];

def bridge_arrangement_native_adopt($store; $newcomers; $ndid; $focused; $topo; $policy; $new_minimums):
  (P::norm_topology($topo)) as $T
  | ($store.segments // []) as $segs
  | ($store.bindings // {}) as $binds
  | ($ndid | tostring) as $nds
  | if ($policy != "focus_chain") and ($policy != "largest_first") then null
    elif ($policy == "largest_first") and (
      (($newcomers | length) == 0)
      or (($newcomers | unique | length) != ($newcomers | length))
      or any($newcomers[]; (type != "number") or (. <= 0) or (floor != .))
      or ([ $binds[] | .window_id // empty ] | any(. as $w | $newcomers | index($w) != null))
      or (is_flat($store) | not)
      or ([ $binds[] | .window_id // empty ] | length != (unique | length))
      or (valid_md($segs; $T).ok | not)
    ) then null  # nested/stacked authoring remains a separate acceptance slice
    elif ($policy == "largest_first") and (($newcomers | length) > 1) then
      reduce $newcomers[] as $w ($store;
        if . == null then null
        else bridge_arrangement_native_adopt(.; [$w]; $ndid; $focused; $topo; $policy; $new_minimums) end)
    elif ($newcomers | length) != 1 then null                            # legacy: one newcomer only
    else
      ($newcomers[0]) as $nw
      | (cells_md($segs; $T)) as $cells
      | ( [ $binds | to_entries[] | select(.value.window_id != null) ] ) as $surv
      | ( ([ $surv[] | .value.window_id ] + [ $nw ]) | sort ) as $want    # full-set target (Amend. E)
      # INSERT on $ndid (Amend. C): the newcomer ALWAYS splits a real bound cell and the grid
      # re-stretches — NO hole-first fill (fork 4, no-holes; the adopt fill-hole bias is RETIRED).
      # A pre-existing arrange {reserved} hole (Wave-2 surplus) is NOT sought as a landing site;
      # it is not a survivor, so it drops to a vacant cell via _strip_binds. The full-set
      # conservation tooth (below) is window-id-only, so such a hole is admissible (it carries no
      # window-id). anchor = focused-on-$ndid else lex-first-on-$ndid.
      | ( ( $focused | tostring | ltrimstr("w:") | (tonumber? // null) ) as $fw
            | ( [ $cells[] | select((.display_id | tostring) == $nds)
                  | { c: ., k: _anchor_key(.), w: (($binds[_anchor_key(.)].window_id) // null) }
                  | select(.w != null) ] ) as $bnd
            | ( if $policy == "largest_first" then _largest_first_insertion_target($bnd)
                else ( ( [ $bnd[] | select(.w == $fw) ][0] ) // ( $bnd | sort_by(.k) | .[0] ) ) end ) as $anchor
            | if $anchor == null then null                               # empty home display → cold
              else
                ($anchor.c.frame) as $af
                | (if ($af.w >= $af.h) then "v" else "h" end) as $axis    # _split_axis: w>=h → v divider
                | (if $axis == "v" then { coord: ($af.x + $af.w/2), lo: $af.y, hi: ($af.y + $af.h) }
                                   else { coord: ($af.y + $af.h/2), lo: $af.x, hi: ($af.x + $af.w) } end) as $sp
                | ($segs + [ { axis: $axis, coord: $sp.coord, lo: $sp.lo, hi: $sp.hi } ]) as $segs2
                | (cells_md($segs2; $T)) as $nc
                | ( [ $nc[] | select(.frame.x >= $af.x - TOL and .frame.y >= $af.y - TOL
                                     and (.frame.x + .frame.w) <= $af.x + $af.w + TOL
                                     and (.frame.y + .frame.h) <= $af.y + $af.h + TOL) ]
                    | sort_by(if $axis == "v" then .frame.x else .frame.y end) ) as $ord
                | if ($ord | length) != 2 then null                      # split did not cleanly halve → cold
                  else
                    # occupant by CONTAINMENT of its stored centre in the anchor cell (Amend. E —
                    # NOT .bindings[$anchor.k], which carried-store anchor drift can null).
                    ( [ $surv[] | (.value.frame) as $f
                        | select( (($f.x + $f.w/2) >= $af.x) and (($f.x + $f.w/2) <= $af.x + $af.w)
                                  and (($f.y + $f.h/2) >= $af.y) and (($f.y + $f.h/2) <= $af.y + $af.h) ) ][0] ) as $occ
                    | if $occ == null then null
                      else
                        ( [ $surv[] | select(.value.window_id != $occ.value.window_id) ] ) as $others
                        | (_prune_rekey($segs2; $T; $others)) as $om      # re-key others (MISS/COLLISION → null)
                        | if $om == null then null
                          else { segs2: $segs2,
                                 binds2: ( _strip_binds($om)
                                           + { (_anchor_key($ord[0])): { window_id: $occ.value.window_id } }
                                           + { (_anchor_key($ord[1])): { window_id: $nw } } ) }
                          end
                      end
                  end
              end
        ) as $cand
      | if $cand == null then null
        else
          (if $policy != "largest_first" then $cand else
             $cand | .binds2 |= with_entries(
               .value.window_id as $id
               | ($new_minimums[($id|tostring)] //
                  ([$binds[] | select(.window_id == $id) |
                    (.min_size // .binding.min_size // .contents[0].min_size // .contents[0].binding.min_size)][0])) as $minimum
               | if $minimum == null then .
                 elif ($minimum | type) != "object" or
                      ($minimum | all(to_entries[]; (.key == "w" or .key == "h") and
                          (.value|type) == "number" and (.value|isinfinite|not) and (.value|isnan|not) and .value >= 0) | not)
                   then error("largest_first_minimum_invalid")
                 elif ($minimum|length) == 0 then . else .value.min_size=$minimum end)
           end) as $cand
          | ( [ $cand.binds2[] | .window_id ] | sort ) as $got
          | ( [ cells_md($cand.segs2; $T)[] | _anchor_key(.) ] ) as $cell_anchors
          | if $got != $want then null                                   # FULL-SET conservation (Amend. E)
            elif (valid_md($cand.segs2; $T).ok | not) then null
            elif ((($cand.binds2 | keys) - $cell_anchors) | length > 0) then null   # every key is a real cell anchor (fail-closed; no post-tooth drop)
            else
              ( bridge_arrangement_native( { segments: $cand.segs2, bindings: $cand.binds2,
                                             off_top: [], promotions: [] }; $topo ) ) as $out
              # Amend. D belt: the newcomer must land on $ndid.
              | ( [ $out.bindings | to_entries[] | select(.value.window_id == $nw) | .key | split(":")[0] ][0] ) as $nw_did
              | if ($nw_did != $nds) then null
                elif $policy == "largest_first" and
                     (all(cells_md($cand.segs2;$T)[];
                       . as $cell | ($out.bindings[_anchor_key(.)]) as $binding
                       | if $binding == null then true else
                         ($binding.contents[0].frame // $binding.frame) as $frame
                         | P::leaf_fit_min($binding) as $minimum
                         | $frame.w >= $minimum.w and $frame.h >= $minimum.h
                           and $frame.x >= ($cell.frame.x - 0.5) and $frame.y >= ($cell.frame.y - 0.5)
                           and ($frame.x+$frame.w) <= ($cell.frame.x+$cell.frame.w+0.5)
                           and ($frame.y+$frame.h) <= ($cell.frame.y+$cell.frame.h+0.5)
                         end) | not) then null
                else $out end
            end
        end
    end;

def bridge_arrangement_native_adopt($store; $newcomers; $ndid; $focused; $topo; $policy):
  try bridge_arrangement_native_adopt($store; $newcomers; $ndid; $focused; $topo; $policy; {}) catch null;

# Compatibility entrypoint: all current production callers retain focus anchoring.
def bridge_arrangement_native_adopt($store; $newcomers; $ndid; $focused; $topo):
  bridge_arrangement_native_adopt($store; $newcomers; $ndid; $focused; $topo; "focus_chain");

# ── arrangement_targets: emit reconcile's exact target map FROM the arrangement ──
# Derive the partition from the bridge's segment bag, read each cell's binding from
# the anchor-keyed side-table, and emit the window-keyed map — mirroring
# reconcile_targets' three-way split + `window_id | tostring` key + vacant skip. The
# PRESENTED entries come from the cells (the partition the arrangement owns); the
# OFF-TOP entries (bound non-top stack members with no cell) are merged from the
# bridge's off_top list. NO min-size math here — every frame is project's, carried
# through the bridge (the partition-vs-impedance boundary stays in ONE module).
def arrangement_targets($bridge; $topo):
  (P::norm_topology($topo)) as $T
  | ($bridge.bindings // {}) as $bindings
  # PER-DISPLAY cells (cells_md) — same partition bridge_arrangement keyed the
  # side-table from, so the anchor keys line up. On single-display this degenerates to
  # one bag == the whole canvas (byte-equal output, the map is window_id-keyed).
  | ([ cells_md($bridge.segments; $T)[] | . + { lk: _anchor_key(.) } ]) as $cells
  | (_rekey_resolve($cells; $bindings)) as $fallback
  # Presented cell bindings: for each cell, its anchor's side-table entry (if any).
  # A cell with no binding (a VACANT face) contributes nothing — the reconcile.jq:199
  # null skip, expressed as the absence of an anchor entry.
  #
  # THE PER-CELL `contents` SLOT (S10). The emitter reads the cell's TOP binding —
  # contents[0], the z-ordered list's first member — exactly as it read the single bare
  # binding before contents existed. A 1-deep contents (the S10 default) reads back the
  # SAME { window_id, presented, frame } the bare entry carried, so the window-keyed
  # output is BYTE-IDENTICAL (the `contents` capacity is persisted but the emitter reads
  # contents[0], never the wrapper). A legacy store WITHOUT contents falls back to the
  # bare entry (minus the wrapper), so an old store reads cleanly. Deeper-than-1 contents
  # is S16's first-class stack; here only the TOP presents (the surplus rides off_top).
  | ( reduce $cells[] as $c ({};
        (($bindings[$c.lk]) // $fallback[$c.lk] // null) as $entry
        | ( if $entry == null then null else ($entry.contents // null) end ) as $cs
        # THE CONTENTS-AUTHORITATIVE PRESENT/HIDE ARM (S16, R2) — the depth-0 twin of
        # _emit_at's leaf arm. When (contents|length)>1, present contents[0] AND emit
        # contents[1..] as {presented:false, frame:null} (the SAME slot the off_top
        # merge fills). GATED on length>1 so a 1-deep contents (the S10 default) takes
        # the identical contents[0] / bare-entry path → BYTE-INERT (the off_top merge
        # below runs LAST; bridge_arrangement_folded routes surplus to contents XOR
        # off_top, never both).
        | if (($cs | type == "array") and (($cs | length) > 1))
          # SYMMETRIC null-skip (S16, the arm-asymmetry fix): the TOP and EVERY surplus
          # member skip when window_id is absent — EXACTLY as the length<=1 else-arm does
          # (a reserved slot / degenerate {} contents member emits no target, the
          # reconcile.jq:199 vacant skip). Without this the length>1 arm would emit a
          # spurious "null"-keyed target for a window_id-less member (reachable via a
          # rebind that demotes a degenerate empty-nested {} into contents[1..]).
          then ( (if (($cs[0].window_id // null) == null) then .
                  else .["\($cs[0].window_id | tostring)"] = $cs[0] end)
                 | reduce $cs[1:][] as $s (.;
                     if (($s.window_id // null) == null) then .
                     else .["\($s.window_id | tostring)"] = ($s + { presented: false, frame: null }) end) )
          else ( ( if $entry == null then null
                   else ($cs | if (type == "array" and length > 0) then .[0]
                               else ($entry | del(.contents)) end)
                   end ) as $b
                 # null-skip: a VACANT face OR a RESERVED SLOT (window_id absent) emits no
                 # target (the reconcile.jq:199 vacant skip). Byte-inert pre-S16.
                 | if ($b == null) or (($b.window_id // null) == null) then .
                   else .["\($b.window_id | tostring)"] = $b
                   end )
          end ) ) as $presented
  # Off-top bound members (no cell in the partition) — keyed identically.
  | ( reduce ($bridge.off_top // [])[] as $o ($presented;
        .["\($o.window_id | tostring)"] = $o) )
  # P-MIN M2 contract guard: the persisted floor lives on the STORE binding;
  # the TARGETS map keeps its minimal {window_id, presented, frame} shape
  # (reconcile_diff / learn / the equivalence oracles all consume it). del on
  # an absent key is identity → byte-inert for a min-less store.
  | map_values(del(.min_size));

# ════════════════════════════════════════════════════════════════════════════
# S16 (R2) — THE UNIVERSAL CONTAINER: contents IS the present/hide authority.
# As of S16 the present/hide authority for EVERY cell is uniformly the `contents`
# z-list (arrangement_targets / _emit_at's S16 arm): contents[0] presents,
# contents[1..] off-top {presented:false, frame:null}. A tiled window IS a 1-stack;
# a multi-window stack is a deep contents — there is NO separate stacked-vs-non-
# stacked OUTPUT code path. `rebind` (lineops.jq, the 5th primitive) is the universal
# contents op that authors them; bridge_arrangement_folded (above) re-expresses
# B::valve's fold as contents (option i — the fold DECISION stays B::valve's).
#
# The S5 block BELOW is KEPT — NOT deleted. It is (1) the tree-side DECISION oracle
# (cells_stack / valid_stack / arrangement::valve / arrangement::conservation compose
# FP::stacks + B::valve + B::conservation VERBATIM — the fold/feasibility authority),
# (2) the `ley parcel explain` legibility surface, and (3) the byte-COMPARISON oracle
# the S16 parity fixtures compare against (valve_via_rebind_parity byte-equals
# arrangement_targets(bridge_arrangement(folded)) — the off_top path — against the
# contents path). The "special case is GONE" at the OUTPUT layer (contents is the
# present/hide authority), NOT by deleting the oracle: deleting it would orphan
# valve_matches_tree and make S16's revert an un-delete-then-restore. NB the S5
# `stack` attribute carries members/top as NODE-ids; contents + the target map are
# WINDOW-id keyed — so the S16 PARITY byte-compare is on the WINDOW-KEYED TARGET MAP,
# never a node-id stack-descriptor member compare.
# ════════════════════════════════════════════════════════════════════════════
# THE STACK CONTAINMENT ATTRIBUTE (S5 / R2) — the crowding valve as a per-cell
# attribute, COMPOSING balance.jq WHOLESALE. This is the rollout's #1 hazard zone:
# the valve already exists and is correct on the tree side (balance.jq) — S5 does
# NOT reimplement it. arrangement::valve and arrangement::conservation call
# B::valve / B::conservation VERBATIM on the bridge tree and ONLY re-express the
# result over cells. There is ZERO min-fit / feasibility / `_required` / "explained"
# arithmetic in this S5 block — every such decision is balance::'s. Forking a second
# clamp dialect would settle a window differently under bsp vs arrangement and
# reintroduce the non-reproducible reframe-thrash R2 exists to prevent (memory:
# reframe-thrash fix D-over-E). The stack attribute is DERIVED by composing
# FP::stacks; the fold is DERIVED by composing B::valve.
#
# R2 DOES NOT GET CLEANER in the new model — the cell `stack` attribute is as
# bolted-on as the tree's `mode:"stack"`. Success here is PARITY (catch a silent
# drop EXACTLY as the tree does), NOT elegance; there is no line-native stack (the
# prototype README + the review both warn against chasing one).
#
# A stacked node presents EXACTLY its top // first child (parcel.jq:250); project
# emits the surplus members as presented:false. So a stacked cell counts as ONE
# cell to the S1 partition invariant (the surplus contribute no frame) — UNAFFECTED
# by stacks. That is the claim S5 holds (step 3).



# ── cells_stack: the cell schema EXTENDED with the optional stack attribute ───────
# S5 step 2. Derive the partition from the bridge tree S3 already threads
# (from_floorplan → cells_md, the SAME partition arrangement_targets keys from), then
# attach each cell the FP::stacks-derived stack attribute whose top-region origin
# equals the cell's min-corner (within TOL). A non-stacked cell carries stack:null.
# A 3-deep stack of leaves presents exactly its top → ONE cell carrying
# stack.depth==3, stack.members the three descriptors, stack.source carried through.
# PURE COMPOSITION: cells_md (S4) ⊕ _stack_cell_attrs (FP::stacks ⊕ P::project). No
# new geometry, no feasibility math.
def cells_stack($tree; $topo):
  (P::norm_topology($topo)) as $T
  | (from_floorplan($tree; $topo)) as $segs
  | (cells_md($segs; $T)) as $cells
  | (_stack_cell_attrs($tree; $topo)) as $attrs
  | [ $cells[]
      | .frame as $f
      | ( [ $attrs[]
            | select(.origin != null
                     and (G::fabs(.origin.x - G::frame_min_x($f)) <= TOL)
                     and (G::fabs(.origin.y - G::frame_min_y($f)) <= TOL)) ][0] // null ) as $hit
      | . + { stack: (if $hit == null then null else $hit.stack end) } ]
  | sort_by([.display_id, .frame.y, .frame.x]);

# ── valid_stack: S1's partition invariant over a STACK-bearing scene ──────────────
# S5 step 3. A stacked cell counts as ONE cell — the surplus members contribute no
# frame (project hides them, parcel.jq:250; from_floorplan draws no divider for a
# stack node). So validity is just valid_md over the from_floorplan bag of the tree:
# a clean 3-deep stack scene reports a VALID partition (no overlap, no gap). The RED
# companion (f1_stack_dangling_overlaps) leaks a surplus frame by injecting a stray
# segment into the raw bag → the atom grid splits → a non-rectangular/gap violation
# the check catches. valid_stack composes valid_md verbatim; the stack-as-one-cell
# claim is inherited from from_floorplan emitting NO edge for a stack.
def valid_stack($tree; $topo):
  (P::norm_topology($topo)) as $T
  | valid_md(from_floorplan($tree; $topo); $T);

# ── valve: the COMPOSITION — B::valve projected through the lens (NOT a forked fold)
# S5 step 5. arrangement::valve(tree; topo; foc; config) is a PURE PASS that:
#   (a) maps the arrangement back to its bridge tree (on the slicing subset the input
#       tree IS the bridge tree — from_floorplan derives the segment bag from it),
#   (b) calls B::valve VERBATIM → the folded tree + facts (the unfold-first sweep,
#       the bottom-up fold, the focus reveal, idempotence — ALL inherited free),
#   (c) re-derives cells_stack from the FOLDED tree (so a folded region surfaces as a
#       stacked cell, source:"valve"),
#   (d) returns { arrangement: <cells_with_stack>, facts: B::valve's facts }
#       preserving B's stack_source/valve_from provenance AND fact order.
# S5 ADDS ZERO FEASIBILITY MATH. A roomy (feasible) scene → B::valve returns the tree
# byte-unchanged → cells_stack is identical to the un-valved arrangement.
def valve($tree; $topo; $foc; $config):
  (B::valve($tree; $topo; $foc; $config)) as $v
  | { arrangement: cells_stack($v.tree; $topo),
      facts: $v.facts };

# ── conservation: B::conservation projected over cells ────────────────────────────
# S5 step 8. arrangement::conservation composes B::conservation VERBATIM on the bridge
# tree (so the routing-away-from-a-real-top "explained" logic at balance.jq:326 is the
# AUTHORITY — S5 does NOT re-derive "explained"), then re-expresses its sets over the
# arrangement so every bound window is PRESENTED, STACKED, or VACANT and nothing
# vanishes. `ok`/`unexplained`/`managed`/`overflowing` pass through B::conservation
# UNCHANGED — so a dangling-top stack (top → non-child → project drops all children →
# unexplained) REDs in the arrangement EXACTLY as the tree does (step 9). The slice
# adds ZERO "explained" / feasibility logic.
#
# THE SET RE-EXPRESSION over cells (leaf-keyed, to align with balance's leaf-keyed
# `managed`/`presented`/`hidden`):
#   bound     = $c.managed   (every window-carrying leaf — what the partition must hold)
#   presented = $c.presented (the top each PRESENTED cell shows; on the folded tree the
#               presented leaves ARE the cell tops, so this set IS the cells' shown
#               windows — composed, not re-derived)
#   stacked   = $c.hidden    (the SURPLUS members of stacked cells — the bound leaves a
#               stack routes away from; these contribute no cell, exactly as balance's
#               `hidden`)
#   vacant    = []           (a VACANT cell carries NO bound window — the tree model has
#               no bound-vacant leaf, so the leaf-keyed vacant set is empty; a window-less
#               cell contributes nothing to `bound`, the reconcile.jq:199 vacant skip)
# So `presented ∪ stacked ∪ vacant == bound` is balance's `presented ∪ hidden == managed`
# (balance.jq:339) re-expressed — the M1 silent-drop invariant, NOT a fresh one.
def conservation($tree; $topo; $foc; $config):
  (B::conservation($tree; $topo; $foc; $config)) as $c
  | { ok:          $c.ok,
      bound:       $c.managed,
      presented:   $c.presented,
      stacked:     $c.hidden,
      vacant:      [],
      unexplained: $c.unexplained,
      overflowing: $c.overflowing };

# ════════════════════════════════════════════════════════════════════════════
# THE RECURSIVE LIFTS (S11 / R-lift) — cells_rec / valid_rec / arrangement_targets_rec
# / edges_rec. Pure read lenses. LIVE STATUS (S-P1, 2026-05-31): arrangement_targets_rec
# (composed with derive_nested) is now the LIVE reconcile + state read producer
# (lib/parcel/reconcile.sh + state.sh) — replacing the non-rec arrangement_targets. The
# swap is byte-identical on every store authored today (flat/zero-promotion: derive_nested
# is identity and arrangement_targets_rec degenerates statement-for-statement to the non-rec
# ancestor; the *_flat_eq fixtures + golden/bridge/roundtrip prove it). cells_rec/edges_rec
# remain harness-only for now. Each *_rec lifts the recursion SITE — the per-display fan-out
# (cells_md = [ per-display bag | cells ]) IS the recursive combinator applied once; these
# generalize the iteration target from "per-display bags" to "cells whose binding is a
# nested arrangement."
#
# ── THE RECURSION-INPUT CONTRACT (the nested `nested` view-key) ──────────────────
# A nested arrangement attaches as a SEPARATE optional key `nested` on a binding
# side-table entry — NOT overloaded onto the S10 `contents[0]` z-stack slot (that is
# S16's domain). The value of `nested` is itself a bridge-shaped triple
# { segments, bindings, off_top } over the PARENT CELL's frame, recursively:
#
#   { "bindings": {
#       "<display_id>:<i0>:<j0>": { "nested": {
#         "segments": [ {axis,coord,lo,hi} … ],          # ABSOLUTE coords over the parent cell.frame
#         "bindings": { "<i0>:<j0>": { window_id, presented, frame, contents } … },  # CHILD-LOCAL keys
#         "off_top": [] } },
#       "<display_id>:<i0>:<j0>": { window_id, presented, frame, contents } } }  # a LEAF binding
#
# This is the DERIVED-VIEW attach point; the system of record stays flat segments +
# promotions (S10). S14b's `promote` will DERIVE exactly this nested view from the flat
# segments + a promotion record (so neither the hand-authored `nested` key here nor
# `contents[0]` is the eventual machine-authored shape — S14b authors a promotion, the
# derivation produces this `nested` view). S11 is hand-authored fixtures, NO derivation.
#
# CHILD-LOCAL KEYS: a child binding is keyed by its BARE local anchor "<display_id>:<i0>:<j0>"
# in the CHILD grid (display_id defaults to 0 for a bare-rect child). The PATH that
# disambiguates same-(i0,j0) child cells under DIFFERENT parents lives ONLY in the
# anchor-key STRING the recursion assembles in-flight (the @-joined path-anchor scheme,
# below) — it is NEVER a stored child key and NEVER a depth-0 cell field.
#
# THE PATH-ANCHOR SCHEME: the shipped 1-arg _anchor_key($cell) = "<display_id>:<i0>:<j0>"
# is the depth-0 builder, kept TEXTUALLY UNCHANGED (bridge_arrangement + arrangement_targets
# call it verbatim — that is the byte-equality bridge). The recursion builds a nested key by
# string concat, appending one "@<i0>:<j0>" rung per descent level
# ("<display_id>:<i0>:<j0>@<i0>:<j0>@…" — the spec's display_id:(i0,j0)@L1:(i0,j0)@L2 form).
# The @ separator is disjoint from the : field separator (ids are ints, never contain @);
# S15 replaces the (i0,j0) rung with the bounding line-set, S11 only NESTS the rung. For
# cells_rec/valid_rec/edges_rec a transient `.path` (a list of [i0,j0] rungs) is attached to
# EMITTED NESTED leaves only; arrangement_targets_rec NEVER carries path into its
# window-keyed output (the map is window_id-keyed, so the path is byte-invisible exactly as
# the shipped display_id: prefix is).
#
# ── DEPTH-0 BYTE-IDENTITY IS THE LAW (degeneration-by-construction, not stripping) ──
# Each *_rec gates its recursive arm on (.nested.segments // [] | length) > 0 — the
# INTERIOR-vs-LEAF predicate (spec §1.1: lines non-empty ⟺ interior). On a flat $arr NO
# binding satisfies it, so the recursion is inert and each function reduces
# statement-for-statement to its *_md (or non-rec) ancestor: cells_rec → cells_md verbatim
# (no path key — OMIT-WHEN-EMPTY); valid_rec → valid_md verbatim (the optional `nested`
# key OMITTED, {} not {nested:[]}); arrangement_targets_rec → arrangement_targets verbatim;
# edges_rec → edges_md verbatim. The predicate is on .nested.segments LENGTH, NOT .nested
# presence — a degenerate empty `nested` reads as a LEAF (matching cells' empty-bag 1-cell
# degenerate). Proven by the *_flat_eq fixtures + arrangement-bridge 12/0/0 + golden-equiv 5/0.
#
# ── NO CLAMP / ZERO MIN-SIZE MATH (the #1 hazard: don't fork the clamp) ──────────────
# A nested leaf's FRAME is CARRIED VERBATIM from the hand-authored contents[0].frame (or
# the bare binding frame) — there is NO min-size arithmetic and NO clamp in this module.
# cells(child.segments; cell.frame) is a LOCATOR ONLY (pure union-find over the integer atom
# grid, to find WHICH child cell each binding anchors to + the child (i0,j0) for the path) —
# NEVER a frame source. The live boundary-fixpoint / min-fit composition that WOULD compute
# nested frames is S13, not S11. INSIDE the descent the recursion uses SINGLE-BAG
# cells(child.segments; cell.frame) / valid(child.segments; cell.frame), NEVER
# cells_md/valid_md/_bags (those re-home absolute-coord child segments against the DISPLAY
# topology and corrupt nested frames). The reconcile output map shape
# { window_id: { presented, frame } } is INVARIANT (R4) at every depth.
#
# ── S13 (O2): FRAME-THREADING DETERMINISM + THE BOUNDARY FIXPOINT (§4.3 RULING) ──────
# O2 is retired by FIXTURES + this DOC ONLY — NO new lib/jq fn, NO new harness arm (the
# S12-style on-ship amendment of the plan's step-3 "Implement the two-pass": it is ALREADY
# SHIPPED). Two claims, two surfaces, both proven over the SHIPPED machinery:
#
#  (1) DETERMINISM (the view-key / carried-frame surface — THIS module).
#      arrangement_targets_rec($bridge;$topo) is FOCUS-FREE BY SIGNATURE (no focus arg) and
#      carries each leaf's frame VERBATIM from contents[0].frame over the INTEGER atom grid
#      (cells() a LOCATOR, never a frame source — the anti-fork guard above). So byte-identical
#      $bridge → byte-identical output: same parent frame ⇒ byte-identical child frames.
#      Determinism is about FRAMES, not the presented BIT: B::valve's op_reveal_leaf reveal
#      legitimately makes WHICH stack member presents focus-dependent (focus c reveals c, d
#      reveals d) — but the fold DECISION and every PRESENTED window's FRAME are focus-INVARIANT.
#      Proven: arrangement_targets/targets_rec_deterministic (the carried-frame fixture, with
#      the anti-derive trap) + cmd-test t30 (the two-focus property: presented-window frames
#      identical under any focus; the presented SET may differ — that is the reveal).
#      The I6 fixpoint holds THROUGH nesting (a settled nested arrangement re-diffs to empty):
#      reconcile_diff/nested_settled_empty + cmd-test t31 (the R4 map shape is depth-agnostic).
#
#  (2) THE BOUNDARY FIXPOINT (the TREE / min↔frame surface — balance.jq's B::valve).
#      THE §4.3 down/up/re-solve-once TWO-PASS IS THE SHIPPED B::valve, re-exposed (NOT a new
#      iterated solver): node_frames (DOWN — assign frames from current mins, computed once on
#      the unfolded clean tree; spans FROZEN for the sweep) + _fold_node's bottom-up post-order
#      (UP + RE-SOLVE-ONCE — recurse children FIRST, then decide THIS node against the already-
#      child-folded subtree_min, so a child's post-fold min reaches its parent in the SAME
#      sweep) + project (which adds NO feedback: subtree_min is FRAME-INDEPENDENT). Converges in
#      ONE sweep, idempotently. WHY ON THE TREE SIDE (not a nested view-key scene): B::valve is
#      TREE-based end to end (it walks $tree.nodes / node.children; the fold flips a node's mode
#      to "stack"); the view-key recursion is the DEFERRED S8/S9/S14b line-native authoring that
#      carries frames VERBATIM with ZERO min math (see the anti-fork guard above). The only
#      min↔frame dependency lives on the tree, so the boundary fixpoint is proven there. Proven
#      at DEPTH by a DEEP CASCADING tree root[A, mid[B, deep[c,d]]] (deep folds → its min-drop
#      sum→max makes mid infeasible → mid ALSO folds, in one post-order sweep, root preserved):
#      arrangement/nested_valve_fixpoint (fn:"valve_idempotent" → twice_eq_once:true, the
#      convergence/fixpoint witness — a THIRD pass is also a no-op) + arrangement/
#      nested_valve_conservation (fn:"conservation" → ok:true, no silent drop at depth).
#      TERMINATION: a fold only LOWERS the split-axis min (sum→max, max≤sum), bounded below by
#      leaf_fit_min (no fold shrinks a single leaf's own min) ⇒ monotone + bounded ⇒ a single
#      sweep terminates. A NON-MONOTONE scene is NOT CONSTRUCTIBLE under this valve (the only
#      transition is split-axis-monotone-down; no un-fold-then-grow within a pass — _unfold runs
#      ONCE up front; project adds no feedback edge). So the plan step-3 "(if constructible)"
#      non-monotone clause is satisfied VACUOUSLY; a non-strict/cyclic tree fails SAFE (no fold,
#      balance.jq:279) rather than diverging. Composes B::valve / B::conservation / P::project
#      VERBATIM — zero forked clamp; golden-equiv + min_fit_chrome_settles stay green BY
#      CONSTRUCTION (no executable lib/jq is touched in S13).
#
#  SIGN-OFFS: sign-off #2 (the boundary fixpoint at depth — the SETTLE runs the two-pass) is
#  ADOPTED HERE. Sign-off #1 (a parent's DRAG does NOT fire a descendant's valve mid-gesture —
#  the valve fires only on the next settle, to keep the drag bounded) is DEFERRED to S17 (it
#  bites only at the gesture stage). RESIDUAL: S13 proves O2 over the carried-frame (S11) path
#  AND the tree-valve path ONLY. S14b (promotion authoring, SHIPPED) is ALSO a CARRIED-frame
#  path: promote authors a `promotions` LABEL; derive_nested (below, above the *_rec block)
#  RELOCATES each promotion's interior segments into the child bindings, carrying their frames
#  VERBATIM (cells() a locator, ZERO min math — the same anti-fork guard above). So the nested
#  view S14b machine-authors is the IDENTICAL input S13 already proved O2 over (the
#  derived_tree_2level fixture is byte-equal to the hand-authored S11 cells_rec_depth2, and
#  derived_targets_rec_deterministic confirms targets_rec is byte-identical twice over the
#  authored path) — so O2 HOLDS UNCHANGED, no re-proof / two-pass solver needed. The genuine
#  DERIVED-frame re-proof (determinism + the boundary fixpoint over computed, not carried,
#  child frames) is needed only when promote is composed into the LIVE boundary-fixpoint settle
#  (the P::child_slots re-solve the S14b plan step explicitly DEFERS) — S14b is the test/CLI
#  carried-frame path. A future S16 (stacks-as-universal-container) deriving child frames is the
#  remaining derived-frame candidate.

# ── derive_nested: the RELOCATION lens (S14b) — flat {segments, promotions} → the nested view ──
# THE ONE genuinely-new DERIVATION (spec §1.3, §6.1 P-PROMOTE). The system of record stays
# FLAT segments + a sparse `promotions` relation (S10); derive_nested turns that flat store
# into the EXACT nested {segments, bindings(+.nested:{segments,bindings,off_top}), off_top}
# shape cells_rec / valid_rec / arrangement_targets_rec consume — so a promotion AUTHORS what
# S11 hand-authored. It is the read-only sibling of cells_md→cells_rec: lineops.promote writes
# the flat store + a promotion record; derive_nested derives the nested view; the *_rec lenses
# consume it. lineops imports arrangement (NOT the reverse) — no import cycle.
#
# ── IT IS A RELOCATION LENS, NOT A RE-KEY-ONLY LENS (the decisive mechanic) ──────────────
# For each promotion it MOVES the interior segments OUT of the flat parent bag INTO the child
# binding's .nested.segments. DECISIVE (cells_rec_depth2): for a flat bag [v@600, h@500[0,600]]
# with the LEFT column {0,0,600,1000} promoted, the interior h@500 lives EXCLUSIVELY in the
# child — the parent .segments is [v@600] ONLY. If h@500 stayed in the parent bag, cells_md
# would give 3 cells, not the 2-cell parent the nested view requires. So the interior line MUST
# leave the parent bag. (A re-key-only lens that left segments flat is WRONG.)
#
# ── ZERO FRAME ARITHMETIC — the O2 carried-frame property (S13 holds unchanged) ──────────
# derive_nested carries the interior segments VERBATIM in their existing display-absolute coords
# (which == child-local coords because coord_map IS the parent cell.frame, so NO transform). It
# computes NO frame, runs no P::project / fit_sizes / B::valve / min-fit / clamp. So the nested
# view it produces is the IDENTICAL input S13 already proved O2 (determinism + boundary fixpoint)
# over — promote+derive_nested MACHINE-AUTHOR what S11 hand-authored, byte-equal. The genuine
# derived-frame re-proof is needed only when promote is composed into the LIVE boundary-fixpoint
# settle (deferred); S14b is the test/CLI carried-frame path.
#
# ── ZERO-PROMOTION BYTE-IDENTITY (the S11 base case) ─────────────────────────────────────
# derive_nested($arr;$T) with promotions [] (the S10 default) returns $arr UNCHANGED (first arm)
# — authoring NO .nested key — so cells_rec(derive_nested(zero_promo)) == cells_rec(zero_promo)
# == cells_md (the degeneration-by-construction law above). arrangement-bridge / golden-equiv /
# store-roundtrip never call derive_nested → stay green by construction. Revert-by-deletion clean.
#
# ── NESTING (union-find over coord_map bboxes; deepest-first) ────────────────────────────
# A promotion nests inside another iff its coord_map is STRICTLY contained in the other's
# (the same containment the derived tree uses). Promotions are processed DEEPEST-FIRST (smallest
# coord_map area first) so an inner promotion's interior is authored INTO its enclosing
# promotion's child bag, not the root bag. _region_localkey composes cells_md + _anchor_key to
# locate the region's anchor cell in the parent partition over the CURRENT bag.


# _seg_interior_to: $seg strictly inside $R on its perpendicular axis, with span within $R.
# A "v" line at coord x is interior iff R.x < coord < R.x+R.w (strict, ±TOL) and its [lo,hi]
# (on y) lies within [R.y, R.y+R.h]; "h" is the transpose. The interior segments become the
# child's bag; bounding faces (coincident with an R face) stay parent gridlines.
def _seg_interior_to($seg; $R):
  if $seg.axis == "v"
  then ($R.x + TOL < $seg.coord and $seg.coord < $R.x + $R.w - TOL)
       and ($seg.lo >= $R.y - TOL and $seg.hi <= $R.y + $R.h + TOL)
  else ($R.y + TOL < $seg.coord and $seg.coord < $R.y + $R.h - TOL)
       and ($seg.lo >= $R.x - TOL and $seg.hi <= $R.x + $R.w + TOL)
  end;

# seg_touches_promotion: $seg is interior to OR face-coincident with any promotion's
# coord_map — the F7 un-draggable predicate (a move would drift the coord_map →
# derive_nested drops the region on read). The single home for the check the drag
# F7 gate and the line_at hit-test both compose (extracted from gesture.sh's inline
# jq, mouse-line-drag M0 — zero forked geometry).
def seg_touches_promotion($seg; $promos):
  any(($promos // [])[];
      (.coord_map) as $R
      | ( _seg_interior_to($seg; $R)
          or ( if $seg.axis == "v"
               then (G::fabs($seg.coord - $R.x) <= TOL) or (G::fabs($seg.coord - ($R.x + $R.w)) <= TOL)
               else (G::fabs($seg.coord - $R.y) <= TOL) or (G::fabs($seg.coord - ($R.y + $R.h)) <= TOL) end ) ) );


# _region_cell: the PARENT-partition cell whose frame min-corner == $R min-corner and whose
# w/h match $R (±TOL). At the TOP level the partition is cells_md over $T (display-qualified);
# at a NESTED level it is the SINGLE-BAG cells() over the child canvas with $did=0 (matching
# _cells_rec_at's nested arm — NEVER cells_md, which would re-home absolute child segments
# against the display topology). $top selects which; returns the tagged cell or null.
def _region_cell($segs; $R; $top; $T; $canvas):
  ( if $top
    then [ cells_md(($segs // []); $T)[] ]
    else [ cells(($segs // []); $canvas)[] | . + { display_id: 0 } ]
    end ) as $cs
  | ( [ $cs[]
        | select( (G::fabs(G::frame_min_x(.frame) - $R.x) <= TOL)
                  and (G::fabs(G::frame_min_y(.frame) - $R.y) <= TOL)
                  and (G::fabs((.frame.w // 0) - $R.w) <= TOL)
                  and (G::fabs((.frame.h // 0) - $R.h) <= TOL) ) ][0] // null );


# _rehome_block_bindings (O3, S15) — relocate each block binding into the child's
# nested.bindings under the CHILD-LOCAL single-bag anchor. $block is the list of
# { key, binding } parent entries whose frame min-corner ∈ $R; $interior is the child's
# relocated segment bag; $R is the promotion coord_map (== the child canvas). The child
# anchor is computed over the relocated interior bag with display_id=0 via SINGLE-BAG
# cells() + _anchor_key (matching _cells_rec_at's nested arm — NEVER cells_md, which
# would re-home absolute child segments against the display topology). A degenerate
# collision (two block windows homing one child cell) elects via P::descriptor_specificity
# VERBATIM (the ONE comparator). Returns { "<0:i0:j0>": <binding> }.
def _rehome_block_bindings($block; $interior; $R):
  ( [ cells(($interior // []); $R)[] | . + { display_id: 0 } ] ) as $ccells
  | reduce $block[] as $bk ({};
      ($bk.binding) as $b
      # Home the block binding into its child cell by CONTAINMENT of the binding frame's CENTRE in
      # the (raw, centreline) child cell — NOT min-corner equality. The block binding's frame is
      # project's desired_frame (gap/2-INSET on interior faces), while $ccells is the RAW centreline
      # partition, so on an interior face the min-corners diverge by gap/2 and a min-corner ±TOL match
      # SILENTLY DROPS a child window once gap/2 > TOL (gap ≥ 9) — the nested region materializes
      # EMPTY (the B2/B3 design-adversarial A6 break; the same class commit 307b95b fixed in the cold
      # bridge_arrangement join, ported here verbatim). The CENTRE is gutter-agnostic (it sits strictly
      # inside exactly one raw cell) → BYTE-IDENTICAL to min-corner at gap ≤ 8, RECOVERS gap ≥ 9.
      | ( ($b.frame.x + ($b.frame.w / 2)) ) as $bcx | ( ($b.frame.y + ($b.frame.h / 2)) ) as $bcy
      | ( [ $ccells[]
            | select( (G::frame_min_x(.frame) <= $bcx) and ($bcx <= G::frame_max_x(.frame))
                      and (G::frame_min_y(.frame) <= $bcy) and ($bcy <= G::frame_max_y(.frame)) ) ][0] // null ) as $cc
      | if $cc == null then .
        else (_anchor_key($cc)) as $ck
          # survivor collision: keep the descriptor_specificity-elected binding (verbatim ladder).
          | if (.[$ck] // null) == null then .[$ck] = $b
            else ( [ .[$ck], $b ]
                   | sort_by([ (0 - P::descriptor_specificity(.binding // {})),
                               (.binding.ordinal // 1000000), (.window_id // 1000000) ]) | .[0] ) as $win
                 | .[$ck] = $win
            end
        end );

def _derive_at($bag; $promos; $parent_id; $top; $T; $canvas):
  ( [ $promos[] | select(_promotion_parent(.; $promos) == $parent_id) ]
    | sort_by(.coord_map.w * .coord_map.h) ) as $here
  | if ($here | length) == 0 then $bag
    else
      # the segments that belong to THIS level (not interior to any promotion placed here)
      ( [ ($bag.segments // [])[]
          | . as $s | select(any($here[]; _seg_interior_to($s; .coord_map)) | not) ] ) as $level_segs
      | reduce $here[] as $p ($bag | .segments = $level_segs;
          ($p.coord_map) as $R
          | ([ ($bag.segments // [])[] | select(_seg_interior_to(.; $R)) ]) as $interior
          | (_region_cell($level_segs; $R; $top; $T; $canvas)) as $cell
          | if $cell == null then .
            else
              (_anchor_key($cell)) as $key
              # O3 (S15): the BLOCK windows — parent bindings whose frame min-corner ∈ $R
              # (presented==true && frame!=null; off_top members excluded — they have no cell).
              # These must RELOCATE into the child, not stay flat at the parent (where they
              # are no longer top-level cells and would DROP — the empirically-reproduced
              # 2-of-3-dropped wrinkle).
              | ( [ (.bindings // {}) | to_entries[]
                    | select((.value.presented == true) and (.value.frame != null)
                             and _frame_min_in_rect(.value.frame; $R)) ] ) as $block
              | ( [ $block[] | { key: .key, binding: .value } ] ) as $block_kb
              | (_rehome_block_bindings($block_kb; $interior; $R)) as $relocated
              # recurse: the child's interior may itself contain nested promotions (parent = P.id),
              # carrying the RELOCATED bindings so a grandchild block re-homes down the right level.
              | (_derive_at({ segments: $interior, bindings: $relocated, off_top: [] };
                            $promos; $p.id; false; $T; $R)) as $child
              # (3) REMOVE the block bindings from the parent top-level; (4) STRIP the parent
              # interior entry to ONLY { nested } (drop window_id/presented/frame/contents — the
              # interior cell is now a parcel, not a leaf, so _emit_at recurses instead of emitting).
              | .bindings = ( (.bindings // {})
                  | reduce ($block[].key) as $bkey (.; del(.[$bkey]))
                  | .[$key] = { nested: { segments: ($child.segments // []),
                                          bindings: ($child.bindings // {}),
                                          off_top: ($child.off_top // []) } } )
            end )
    end;

# derive_nested: the relocation lens. Zero-promotion → identity ($arr). Otherwise recurse the
# nesting forest from the root (top-level promotions have parent null), authoring each
# promotion's interior into the correct nested child bag (grandchildren land inside children,
# not the root — the depth-3 correctness). Drops the transient .promotions from the VIEW.
def derive_nested($arr; $T):
  # DEFENSIVE (S-P5 followup c; impl adversarial pass A7): drop a malformed promotion lacking a
  # numeric coord_map bbox — `_promotion_parent`'s `coord_map.w * coord_map.h` / `_bbox_contains`
  # crash on it, aborting the whole settle. Inert today (no live verb authors promotions, so [] stays
  # []) and a well-formed promotion (numeric coord_map.w/h) is untouched; this only degrades a
  # hand-fed malformed store to flat rather than crashing the lens. The `arrangement set` gate
  # (lib/parcel/store.sh) does not validate promotion shape, so this is the consumer-side backstop.
  (($arr.promotions // []) | map(select((.coord_map.w | type) == "number" and (.coord_map.h | type) == "number"))) as $promos
  | if ($promos | length) == 0 then $arr
    else
      ( _derive_at({ segments: ($arr.segments // []),
                     bindings: ($arr.bindings // {}),
                     off_top: ($arr.off_top // []) };
                   $promos; null; true; $T; null) ) as $d
      | { segments: ($d.segments // []), bindings: ($d.bindings // {}), off_top: ($d.off_top // []) }
    end;

# ── cells_rec: cells_md lifted — an interior cell recurses into its nested arrangement ──
# _cells_rec_at tiles the arbitrary rect $cv via SINGLE-BAG cells() (the LOCATOR), tags each
# located cell with $did (so its localkey matches the binding side-table's anchor — the TOP
# level is qualified by the bag's display_id exactly as _anchor_key / bridge_arrangement key
# it; a nested level's $did defaults to 0, matching cells'/_anchor_key's `// 0`), looks up
# the cell's CHILD-LOCAL anchor "<did>:<i0>:<j0>" in $bindings, and either recurses into the
# nested arrangement over cell.frame (interior) or emits the cell as a leaf. The transient
# .path of enclosing [i0,j0] rungs is attached to NESTED leaves only (omit-when-empty), never
# depth-0 cells. cells_rec fans out per display via _bags exactly as cells_md and sorts
# [display_id, frame.y, frame.x] verbatim. Flat: no $kid fires, no path attached → == cells_md.
def _cells_rec_at($arr; $cv; $did; $path):
  [ cells(($arr.segments // []); $cv)[]
    | . + { display_id: $did }
    | . as $c
    | ("\($did):\($c.i0):\($c.j0)") as $localkey
    | (($arr.bindings // {})[$localkey].nested // null) as $kid
    | if (($kid.segments // []) | length) > 0
      then _cells_rec_at({ segments: $kid.segments, bindings: ($kid.bindings // {}) };
                         $c.frame; 0; ($path + [[$c.i0, $c.j0]]))[]
      else $c + (if ($path | length) > 0 then { path: $path } else {} end)
      end ];

def cells_rec($arr; $T):
  [ _bags(($arr.segments // []); $T)[]
    | .display_id as $did | .rect as $r
    | _cells_rec_at({ segments: .segments, bindings: ($arr.bindings // {}) }; $r; $did; [])[] ]
  | sort_by([.display_id, .frame.y, .frame.x]);

# ── valid_rec: valid_md lifted — the compositional AND reaches INTO nested bindings ──
# _valid_nested_at locates the cells of one bag/sub-bag via SINGLE-BAG cells(), and for each
# INTERIOR cell (non-empty .nested.segments) emits ONE { path, ok, violations } record from
# SINGLE-BAG valid(child.segments; cell.frame) (NOT valid_md — re-running _bags at a nested
# level would re-home the absolute-coord child segments against the DISPLAY topology and
# corrupt the partition) AND recurses deeper, returning a FLAT list of every nested record.
# valid_rec assembles the depth-0 envelope { ok, per_display } byte-identically to valid_md
# (each bag's single-bag valid()), appends the flat nested records only when non-empty
# (+ (if ($n|length)>0 then {nested:$n} else {} end) — OMIT-WHEN-EMPTY, {} not {nested:[]},
# load-bearing for byte-identity), and ANDs the top per_display ok with every nested ok.
# Flat: no interior cell exists → $nested empty → {ok, per_display} == valid_md verbatim.
def _valid_nested_at($arr; $cv; $did; $path):
  [ cells(($arr.segments // []); $cv)[]
    | . as $c
    | ("\($did):\($c.i0):\($c.j0)") as $localkey
    | (($arr.bindings // {})[$localkey].nested // null) as $kid
    | select((($kid.segments // []) | length) > 0)
    | ($path + [[$c.i0, $c.j0]]) as $kpath
    | (valid(($kid.segments // []); $c.frame)) as $kv
    | ( [ { path: $kpath, ok: $kv.ok, violations: $kv.violations } ]
        + _valid_nested_at({ segments: $kid.segments, bindings: ($kid.bindings // {}) };
                           $c.frame; 0; $kpath) )[] ];

def valid_rec($arr; $T):
  ( [ _bags(($arr.segments // []); $T)[]
      | .display_id as $did | .rect as $r
      | (valid(.segments; $r)) as $v
      | { display_id: $did, ok: $v.ok, violations: $v.violations,
          nested: _valid_nested_at({ segments: .segments, bindings: ($arr.bindings // {}) };
                                   $r; $did; []) } ] ) as $bags
  | ( [ $bags[] | { display_id, ok, violations } ] ) as $pd
  | ( [ $bags[] | .nested[] ] ) as $nested
  | { ok: ((all($pd[]; .ok)) and (all($nested[]; .ok))), per_display: $pd }
    + (if ($nested | length) > 0 then { nested: $nested } else {} end);

# ── arrangement_targets_rec: arrangement_targets lifted — descend nested bindings ────
# The R4 window-keyed map { "<window_id>": { window_id, presented, frame } }, INVARIANT at
# every depth (the map is keyed by the globally-unique window_id, so the path-qualified
# internal anchor never leaks into the bytes — byte-invisible exactly as the shipped
# display_id: prefix is). _emit_at locates the cells of one bag/sub-bag via SINGLE-BAG
# cells(), reads each cell's anchor "<did>:<i0>:<j0>" in $bindings, and either RECURSES into
# the nested arrangement over cell.frame (interior) or emits the binding's top window
# (contents[0], or the bare entry minus the contents/nested wrappers) keyed by window_id —
# CARRYING THE FRAME VERBATIM (cells() is a LOCATOR, never a frame source; zero min math).
# Each level merges its own off_top. arrangement_targets_rec fans out per display via _bags
# (matching arrangement_targets / bridge_arrangement's per-display anchor keys) then merges
# the TOP off_top once. Flat: no interior fires; the leaf arm is arrangement_targets' reduce
# body verbatim (contents[0] / bare-entry + off_top merge) → byte-identical.
def _emit_at($arr; $cv; $did; $path):
  ($arr.bindings // {}) as $b
  | ([ cells(($arr.segments // []); $cv)[] | . + { lk: ("\($did):\(.i0):\(.j0)") } ]) as $cells
  | (_rekey_resolve($cells; $b)) as $fallback
  | ( reduce $cells[] as $c ({};
        ($c.lk) as $localkey
        | (($b[$localkey]) // $fallback[$localkey] // null) as $entry
        | ((($entry.nested.segments // []) | length) > 0) as $interior
        | if $interior
          then . + _emit_at({ segments: $entry.nested.segments,
                              bindings: ($entry.nested.bindings // {}),
                              off_top: ($entry.nested.off_top // []) };
                            $c.frame; 0; ($path + [[$c.i0, $c.j0]]))
          else ( if $entry == null then null else ($entry.contents // null) end ) as $cs
               # THE CONTENTS-AUTHORITATIVE PRESENT/HIDE ARM (S16, R2). A leaf cell's
               # `contents` z-list IS the universal stack: contents[0] presents (frame
               # carried verbatim from the cell), contents[1..] off-top as
               # {presented:false, frame:null} — the SAME {presented:false,frame:null}
               # the shipped off_top stream writes (targets_stack_top_hidden), into the
               # SAME window-id-keyed slot. GATED on (contents|length)>1: a 1-deep
               # contents (the S10 default) takes the identical contents[0] / bare-entry
               # path, BYTE-INERT (arrangement-bridge 12/0/0 + golden 5/0 + O0 2/0 stay
               # green by construction — no flat/golden/bridge store authors a deep
               # contents, so none reaches this arm). The surplus rides contents[1..]
               # XOR the bridge off_top, never both (bridge_arrangement_folded routes
               # surplus to contents and emits off_top:[] for the cell; the off_top
               # merge below runs LAST and would otherwise overwrite a contents entry).
               | if (($cs | type == "array") and (($cs | length) > 1))
                 # SYMMETRIC null-skip (S16, the arm-asymmetry fix): TOP + every surplus
                 # member skip when window_id is absent, EXACTLY as the length<=1 else-arm
                 # below does — a degenerate window_id-less contents member (e.g. a rebind
                 # that demotes an empty-nested {} into contents[1..]) emits no spurious
                 # "null"-keyed target.
                 then ( (if (($cs[0].window_id // null) == null) then .
                         else .["\($cs[0].window_id | tostring)"] = $cs[0] end)
                        | reduce $cs[1:][] as $s (.;
                            if (($s.window_id // null) == null) then .
                            else .["\($s.window_id | tostring)"] = ($s + { presented: false, frame: null }) end) )
                 else ( ( if $entry == null then null
                          else ($cs | if (type == "array" and length > 0) then .[0]
                                       else ($entry | del(.contents) | del(.nested)) end)
                          end ) as $win
                        # null-skip: a VACANT face (no anchor entry) OR a RESERVED SLOT
                        # (window_id ABSENT — rebind's empty arm, { reserved:true,
                        # contents:[] }) emits NO target, mirroring the reconcile.jq:199
                        # vacant skip / project's window_id-null leaf (parcel.jq:310). The
                        # partition still sees ONE cell; nothing presents. Byte-inert for
                        # every pre-S16 binding (all carry a window_id).
                        | if ($win == null) or (($win.window_id // null) == null) then .
                          else .["\($win.window_id | tostring)"] = $win end )
                 end
          end ) )
  | ( reduce (($arr.off_top // [])[]) as $o (.; .["\($o.window_id | tostring)"] = $o) );

def arrangement_targets_rec($bridge; $topo):
  (P::norm_topology($topo)) as $T
  | ( reduce _bags(($bridge.segments // []); $T)[] as $bag ({};
        . + _emit_at({ segments: $bag.segments, bindings: ($bridge.bindings // {}), off_top: [] };
                     $bag.rect; $bag.display_id; []) ) )
  | ( reduce (($bridge.off_top // [])[]) as $o (.; .["\($o.window_id | tostring)"] = $o) )
  # P-MIN M2 contract guard — same as arrangement_targets: floors persist on
  # the store, never in the targets shape.
  | map_values(del(.min_size));

# Pure admission predicate shared by the live arrangement writer and durable
# authority boundaries. The descriptive result lets each caller retain its own
# error vocabulary without reimplementing these invariants. A malformed
# promotion remains crash-safe, matching the historic writer: derive failure is
# reported as null dropped ids and does not reject by itself.
def store_valid($store):
  (valid_md(($store.segments // []); ($store.topology // {}))) as $partition
  | ([($store.bindings // {})[]
      | select((((.contents // []) | length) > 0)
               and ((.window_id // null)
                    != ((.contents[0] // {}).window_id // null)))]
     | length > 0) as $cell_inconsistent
  | ((($store.promotions // []) | length) > 0) as $has_promotions
  | (if $has_promotions then
       try (
         ([ $store | .. | objects | .window_id? | numbers ]
          | unique | sort) as $flat
         | (P::norm_topology($store.topology // {})) as $T
         | (arrangement_targets_rec(derive_nested($store; $T); $T)
            | keys | map(tonumber? // empty) | unique | sort) as $emitted
         | ($flat - $emitted)
       ) catch null
     else [] end) as $promotion_dropped_window_ids
  | {
      ok:(($partition.ok == true)
          and ($cell_inconsistent | not)
          and ($promotion_dropped_window_ids == null
               or ($promotion_dropped_window_ids | length) == 0)),
      partition:$partition,
      cell_inconsistent:$cell_inconsistent,
      has_promotions:$has_promotions,
      promotion_dropped_window_ids:$promotion_dropped_window_ids
    };

# ── is_flat / carryable_windows: native_noop's fire condition, factored for lockstep ──
# These two are the STORE-INTRINSIC half of parcel/strategies/arrangement.jq's $native_noop
# guard (and the same flat-exclusions in $native_prune / $native_adopt). They are factored
# here so the strategy AND the B1 drag gate (lib/parcel/gesture.sh) compute carryability from
# ONE source and cannot desync — the desync between a STRUCTURAL look-alike and native_noop's
# GEOMETRIC truth was exactly the S-P5 A8 false-negative (a near-wall divider admitted but
# then flattened). The gate asks "would native_noop fire on this minted store?" =
# is_flat AND (carryable_windows == the store's bound window set).
#
# is_flat — the store is a FLAT line bag: no stacked surplus (off_top), no deep stack
# (contents > 1), no promotions, no materialized nested cell. The `(.contents // [.])`
# default and the `has("nested")` PRESENCE test are LOAD-BEARING (a length-test tidy would
# silently admit the empty-nested degenerate). `promotions == []` is dead-but-defensive (no
# live authoring verb) — forward insurance, kept symmetric with native_noop.
# is_flat is defined before the native adopt author so both callers compose it.

# is_carryable — is_flat WITHOUT the promotions==[] clause (B3-1b). The native_noop author is FLAT
# (bridge_arrangement_native tiles TOP-LEVEL cells) but the dispatch CARRIES promotions verbatim
# (strategy:promotions), and a `promotion` relocates nothing in storage (promote is a pure label —
# its windows ARE top-level cells in the carried segments; the nested view is DERIVED by derive_nested,
# which B3-1a's centre-containment rehome now re-materializes inset-correctly). So a promotion store
# (no off_top stack, no deep stack, NO materialized `nested` binding) IS carryable by the flat author.
# The `nested`-binding clause STAYS: a materialized sub-arrangement IS a set of windows the flat author
# would drop (the managed-set false-positive the strategy header warns of). On a FLAT store
# (promotions==[]) is_carryable == is_flat by construction, so it is byte-inert off the promotion path.
def is_carryable($t):
  ((($t.off_top // []) | length) == 0)
  and (all(($t.bindings // {})[]?; (((.contents // [.]) | length) <= 1)))
  and (all(($t.bindings // {})[]?; (has("nested") | not)));

# ── carry_promos: the A2-safe carry-or-dissolve decision, factored for DRY (B3-4) ──
# Carry $promos onto a RE-AUTHORED $bridge ({segments,bindings,off_top}) iff derive_nested over the
# new bridge recovers the SAME window set as the flat bridge — i.e. the (possibly reshaped) region
# still cell-aligns and drops nothing on read. Else carry [] (DISSOLVE — the region genuinely can no
# longer survive this churn; the native grid is KEPT, strictly better than the cold flatten). This is
# the A2-corruption net: a churn that drifts a coord_map leaves an orphaned interior segment that
# derive_nested would relocate-then-drop a window over (the code-confirmed B3-3 corruption) — the
# set mismatch routes to [] so it NEVER ships a dropping promotion. Originally inline at the cold tail
# (parcel/strategies/arrangement.jq); the cold tail + both native churn tails (native_prune / native_
# adopt) now share this ONE decision. promotions==[] short-circuits → [] → BYTE-INERT on every flat
# store (the cold tail's old `promotions: []` literal, native_adopt's `($t.promotions//[]) == []`).
# WINDOW-SET only (not valid_rec) — DRY with the cold tail + the shipped F8 tooth; the valid_rec
# upgrade is the tracked F8 remainder. The oracle asserts valid_rec on every carry as a tripwire.
def carry_promos($bridge; $promos; $T):
  if ($promos | length) == 0 then []
  else
    (arrangement_targets_rec($bridge; $T) | keys | sort) as $flatk
    | (arrangement_targets_rec(derive_nested(($bridge + { promotions: $promos }); $T); $T) | keys | sort) as $promok
    | (if $flatk == $promok then $promos else [] end)
  end;

# carryable_windows — the window-id set the structure-preserving rec lens RECOVERS from the
# store (== native_noop's $prior_bound). GEOMETRIC: cells_md → compress TOL-dedups any coord
# within G::TOL of a wall/parallel divider, so a near-wall divider drops its cell and this set
# comes back SHORT a window. Comparing it to the store's bound window set predicts whether the
# next settle's native_noop will fire (a flat store whose lens recovers every window) or fall
# to the cold path (and flatten). Only safe to call on a flat store (derive_nested can choke on
# a malformed promotion) — callers gate it behind is_flat (jq `and` short-circuits).
def carryable_windows($t; $T):
  arrangement_targets_rec(derive_nested($t; $T); $T) | keys | map(tonumber? // .) | sort;

# ── carve_drop: the span-drop CARVE author (movemode follow-up #3 Step 3) ─────────────
# Drop $fill_wid into a full-extent COLUMN carved from the drop-side of a COLLINEAR RUN of
# spanned cells (the run lineops::extend_run staged as drop_span). The SEMANTIC is CARVE,
# not displace (the fork RESOLVED 2026-06-15): each spanned occupant keeps its FAR half
# (narrows IN PLACE — none is displaced/stacked/re-flowed), and the N empty drop-side halves
# merge into ONE column the dropped window fills. FLAT by construction (the merged halves
# were empty → no off_top, no window lost), so the next settle's native_noop carries it and
# the deliberate span is DURABLE (is_flat + carryable_windows==bound-set hold — proven by
# the keystone). This composes the SHIPPED partition/re-key substrate — cells_md, valid_md,
# _anchor_key, _prune_rekey, seg_touches_promotion — adding only the minimal span-edit the
# carve needs (shorten the run-internal seams to the carve coord + the one carve divider);
# there is NO new frame/clamp dialect, so golden-equiv stays byte-equal (carve_drop is a
# NEW path gated on drop_span|length>1, never on the cold/native authoring lines).
#
# $span_wids : the run's window ids in extend_run order (>=2; the caller branches on len>1).
#              $span_wids[0] = the staged anchor cell — the carve coord = its midpoint, so a
#              span over a uniform column splits exactly where a single-cell insert would.
# $drop_side : east|west|north|south — the side the column is carved on. east/south → the
#              column is the HIGH half (occupants keep the low/far half); west/north → low.
# $fill_wid  : the window to drop into the column — a carried float, OR a bound window the
#              CALLER has ALREADY pruned from $arr (carve_drop only PLACES it, never vacates).
# Returns { ok, reason, arr } — arr is the re-bound FLAT store. A reject is a CLEAN
# { ok:false } with NO arr (the caller no-ops byte-unchanged): a non-collinear run, a carve
# coord not interior to every spanned cell (an uneven run), a vanished/unbound spanned id, a
# pinned or promotion-touching internal seam (never silently eat a sticky size — design
# residual #3/#4), an already-bound fill, an invalid carved partition, or a re-key
# MISS/COLLISION. ALL coordinate work is centre-containment / span-shorten over the SAME raw
# cells_md frames the insert author uses — exact regardless of gap.
def carve_drop($arr; $T; $span_wids; $drop_side; $fill_wid):
  (cells_md(($arr.segments // []); $T)) as $cells
  | ($arr.bindings // {}) as $binds
  | ($arr.promotions // []) as $promos
  | (if ($drop_side == "east" or $drop_side == "west") then "v" else "h" end) as $cax    # carve-divider axis
  | (if $cax == "v" then "h" else "v" end) as $pax                                        # run-internal seam axis
  | (if ($drop_side == "east" or $drop_side == "south") then "max" else "min" end) as $faceside  # which face the column abuts
  | ( [ TOL, ($T.gap // 0) ] | max ) as $floor   # a half narrower than this collapses to <=0 after the gap inset
  # SELF-IN-SPAN (move a window to its own full edge-row): the fill window IS a member of the
  # run. Its WHOLE cell is absorbed into the carved band (it does NOT narrow); the OTHER members
  # narrow as usual. The caller does NOT pre-vacate it, so it is still bound here. Gated on this
  # flag, so a span WITHOUT the fill member is byte-identical to before.
  | (($span_wids | index($fill_wid)) != null) as $fis
  # fill must NOT already be bound — in .bindings (carry: a float; bound: the caller vacated it first)
  # OR in off_top (a stack-non-top member; misclassified as a float by _wm_parcel_movemode_bound_wids,
  # which scans only .bindings — without this it would be DUPLICATED into the column AND off_top).
  | if (any(($binds | to_entries[]); (((.value.contents[0].window_id) // .value.window_id)) == $fill_wid) and ($fis | not))
       or any(($arr.off_top // [])[]; .window_id == $fill_wid)
    then { ok: false, reason: "fill window \($fill_wid) is already bound/stacked — the caller must vacate it first" }
    elif (($span_wids | length) < 2) then { ok: false, reason: "span too short (need >= 2 cells)" }
    else
      # resolve each span wid → its current cell (post-vacate frames if the caller pruned).
      ( [ $span_wids[] as $w
          | ( [ $binds | to_entries[] | select(((.value.contents[0].window_id) // .value.window_id) == $w) ][0] ) as $be
          | ( [ $cells[] | select(_anchor_key(.) == ($be.key // "")) ][0] ) as $c
          | { wid: $w, cell: $c, bind: ($be.value // null) } ] ) as $sc
      # the NARROWING members = the span minus the fill window. In self-in-span the fill member
      # does not narrow (its whole cell is absorbed into the band); $scn == $sc otherwise.
      | ( [ $sc[] | select(.wid != $fill_wid) ] ) as $scn
      | if any($sc[]; .cell == null) then { ok: false, reason: "a spanned window is no longer bound to a cell" }
        # a spanned cell that is a z-ORDER STACK (contents>1, the crowding valve) cannot be carved
        # FLAT — its surviving stack would defeat is_flat/native_noop durability. Reject EXPLICITLY
        # (else the bash carryability gate trips with a misleading "near-wall" toast).
        elif any($sc[]; ((.bind.contents // []) | length) > 1)
          then { ok: false, reason: "a spanned cell is a stack — narrow the span (carve needs flat cells)" }
        else
          # the shared drop FACE coord — collinear run ⇒ equal within TOL, else reject.
          ( [ $sc[] | .cell.frame
              | (if $cax == "v" then (if $faceside == "max" then G::frame_max_x(.) else G::frame_min_x(.) end)
                 else (if $faceside == "max" then G::frame_max_y(.) else G::frame_min_y(.) end) end) ] ) as $faces
          | if ((($faces | max) - ($faces | min)) > TOL) then { ok: false, reason: "the run is not collinear on the drop face" }
            else
              ($faces[0]) as $face
              | ($sc[0].cell.frame) as $af                 # the anchor cell (the staged target)
              | ($sc[0].cell.display_id) as $did
              | (if $cax == "v" then ($af.x + $af.w / 2) else ($af.y + $af.h / 2) end) as $carve
              # carve coord must clear $floor (= max(TOL, gap)) on BOTH sides of every spanned cell
              # on the carve axis, so neither the occupant far half nor the column collapses to <=0
              # after the gap inset (a sub-gap half renders zero/negative-width and the durability
              # oracle — being gap-blind — would still call it carryable). At gap=0 $floor==TOL, so
              # this is identical to the old TOL-interior check (byte-inert on gapless scenes).
              | ( [ $scn[] | .cell.frame
                    | (if $cax == "v" then { lo: G::frame_min_x(.), hi: G::frame_max_x(.) }
                       else { lo: G::frame_min_y(.), hi: G::frame_max_y(.) } end) ] ) as $caxspans
              # SELF-IN-SPAN alignment: the fill member is absorbed WHOLE into the band, so its FAR
              # edge (opposite the drop face) must meet the carve line — else its far half would
              # orphan (a hole) / overlap. A mis-aligned layout rejects cleanly here.
              | ( if $fis then ( [ $sc[] | select(.wid == $fill_wid) ][0].cell.frame
                    | (if $cax == "v" then (if $faceside == "max" then G::frame_min_x(.) else G::frame_max_x(.) end)
                       else (if $faceside == "max" then G::frame_min_y(.) else G::frame_max_y(.) end) end) ) else null end ) as $fillfar
              | if any($caxspans[]; ($carve <= (.lo + $floor)) or ($carve >= (.hi - $floor)))
                then { ok: false, reason: "carve coord too close to a cell edge (would collapse a half under the gap)" }
                elif ($fis and (($fillfar | type) == "number") and (G::fabs($fillfar - $carve) > TOL))
                then { ok: false, reason: "the moved window's cell doesn't align with the carve line — can't form a clean band" }
                else
                  # the run's extent along the RUN axis (perpendicular to the carve axis).
                  ( [ $sc[] | .cell.frame | (if $cax == "v" then G::frame_min_y(.) else G::frame_min_x(.) end) ] | min ) as $run_lo
                  | ( [ $sc[] | .cell.frame | (if $cax == "v" then G::frame_max_y(.) else G::frame_max_x(.) end) ] | max ) as $run_hi
                  # the INTERNAL seams to shorten: $pax-axis segments whose coord is strictly
                  # interior to the run extent (excludes the run's OUTER boundary, which still
                  # bounds the column), that CROSS the carve coord, and REACH the drop face.
                  | ( [ ($arr.segments // [])[]
                        | select(.axis == $pax)
                        | select((.coord > ($run_lo + TOL)) and (.coord < ($run_hi - TOL)))
                        | select((.lo < ($carve - TOL)) and (.hi > ($carve + TOL)))
                        | select(if $faceside == "max" then (G::fabs(.hi - $face) <= TOL) else (G::fabs(.lo - $face) <= TOL) end) ] ) as $seams
                  # A PINNED seam is FINE — the carve SHORTENS it (trims the drop-side span,
                  # keeping its coord/sticky-size for the occupants' far halves), never deletes it;
                  # and the caller re-pins all dividers after. Only a PROMOTION (a frozen region)
                  # stops the carve.
                  | if ($seams | any(seg_touches_promotion(.; $promos)))
                    then { ok: false, reason: "a spanned seam touches a promotion — demote it first" }
                    else
                      ( [ $seams[] | "\(.coord):\(.lo):\(.hi)" ] | unique ) as $seamkeys
                      # build the new segments: non-seams verbatim; seams shortened on the FACE
                      # end to the carve coord; + the ONE carve divider over the run extent. The
                      # seam key is captured ($sk) BEFORE the index() so `.` inside it is the
                      # SEGMENT, not $seamkeys (the index input).
                      | ( [ ($arr.segments // [])[]
                            | . as $sg
                            | ("\($sg.coord):\($sg.lo):\($sg.hi)") as $sk
                            | if (($sg.axis == $pax) and (($seamkeys | index($sk)) != null))
                              then (if $faceside == "max" then ($sg | .hi = $carve) else ($sg | .lo = $carve) end)
                              else $sg end ]
                          + [ { axis: $cax, coord: $carve, lo: $run_lo, hi: $run_hi } ] ) as $nsegs
                      | (valid_md($nsegs; $T)) as $v
                      | if ($v.ok | not) then { ok: false, reason: "the carved partition is invalid (uneven run / dangling seam)" }
                        else
                          (cells_md($nsegs; $T)) as $ncells
                          | def _hit($cx; $cy):
                              ( [ $ncells[]
                                  | select(((.display_id | tostring) == ($did | tostring))
                                           and (G::frame_min_x(.frame) <= $cx) and ($cx <= G::frame_max_x(.frame))
                                           and (G::frame_min_y(.frame) <= $cy) and ($cy <= G::frame_max_y(.frame))) ][0] );
                          # each occupant → the new cell containing its FAR-HALF centre (interior,
                          # never on the carve divider — so unambiguous unlike the raw cell centre).
                          # $scn (not $sc): the fill member does not narrow — it fills the band.
                          ( [ $scn[]
                              | .cell.frame as $f
                              | ( if $cax == "v"
                                  then (if $faceside == "max" then { cx: (($f.x + $carve) / 2),               cy: ($f.y + $f.h / 2) }
                                        else                        { cx: (($carve + $f.x + $f.w) / 2),       cy: ($f.y + $f.h / 2) } end)
                                  else (if $faceside == "max" then { cx: ($f.x + $f.w / 2),                   cy: (($f.y + $carve) / 2) }
                                        else                        { cx: ($f.x + $f.w / 2),                   cy: (($carve + $f.y + $f.h) / 2) } end) end ) as $ctr
                              | { wid: .wid, bind: .bind, hit: _hit($ctr.cx; $ctr.cy) } ] ) as $occ
                          # carry the new (narrowed) cell frame so the carved store is fully framed —
                          # the author-time min-fit gate (and any consumer) sees the TRUE post-carve
                          # width, not a stale pre-carve frame / a frame-less skip. The realize re-
                          # projects regardless, so the stamped raw frame is overwritten (inert to the
                          # final geometry) — it only un-blinds the gate.
                          # the COLUMN cell → fill: centre is midway carve↔face on the carve axis,
                          # run-midpoint on the run axis.
                          | ( if $cax == "v"
                              then { cx: (($carve + $face) / 2),       cy: (($run_lo + $run_hi) / 2) }
                              else { cx: (($run_lo + $run_hi) / 2),     cy: (($carve + $face) / 2) } end ) as $colctr
                          | (_hit($colctr.cx; $colctr.cy)) as $colcell
                          | if (any($occ[]; .hit == null)) or ($colcell == null)
                            then { ok: false, reason: "could not resolve the carved cells (re-key MISS)" }
                            else
                              ( [ $occ[] | { ak: _anchor_key(.hit), wid: .wid, bind: .bind, frame: .hit.frame } ] ) as $occk
                              | (_anchor_key($colcell)) as $colak
                              # re-key the UNCHANGED windows (not spanned, not fill) by centre-
                              # containment — their cells are geometrically untouched. Stamp each
                              # one's frame from its OLD cell ($cells, raw centreline) so _prune_rekey
                              # has a centre even when the persisted binding is frame-LESS (a pre-
                              # settle store / the test harness) — the unchanged cell's raw centre is
                              # the same point either way (gap insets symmetrically).
                              | ( [ $binds | to_entries[]
                                    | (((.value.contents[0].window_id) // .value.window_id)) as $w
                                    | select(($span_wids | index($w)) == null and $w != $fill_wid)
                                    | .key as $k
                                    | ( [ $cells[] | select(_anchor_key(.) == $k) ][0] ) as $oc
                                    | { key: $k, value: (.value + (if $oc != null then { frame: $oc.frame } else {} end)) } ] ) as $others
                              | (_prune_rekey($nsegs; $T; $others)) as $om
                              | if $om == null then { ok: false, reason: "could not re-key the unchanged windows (MISS/COLLISION)" }
                                else
                                  # the carved keys must be distinct and disjoint from the re-keyed others.
                                  ( [ $occk[].ak ] + [ $colak ] ) as $newks
                                  | if (($newks | unique | length) != ($newks | length)) or any($newks[]; . as $nk | ($om | has($nk)))
                                    then { ok: false, reason: "carved cell key collision (overlapping cells)" }
                                    else
                                      ( $om
                                        + (reduce $occk[] as $o ({}; . + { ($o.ak): (($o.bind // {}) + { window_id: $o.wid, presented: true, frame: $o.frame }) }))
                                        + { ($colak): { window_id: $fill_wid, presented: true, frame: $colcell.frame } } ) as $nbinds
                                      | { ok: true, reason: "ok", arr: ($arr | .segments = $nsegs | .bindings = $nbinds) }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end;

# ── face_segment: the DROP-SIDE EDGE line of a spanned run (the bold drop-line the overlay draws) ──
# Unlike carve_segment (the interior cut divider at the cell midpoint — which read oddly mid-window),
# the operator wants the bold to be the EXISTING grid line on the cell's drop-side FACE, brightened
# and extended along the run as the cursor walks (#3 line-centric redesign 2026-06-16). The face is
# the run's SHARED outer edge (east→max_x, west→min_x, south→max_y, north→min_y; collinear ⇒ one
# coord), spanning the run perpendicular extent. The actual cut still lands at the midpoint inside
# (carve_drop) — the bold shows the edge you are building against, which is a real gridline (a seam
# or, with perimeter drawn, the display edge). Returns {axis,coord,lo,hi} or null (an unresolved /
# non-collinear span). PURE.
def face_segment($arr; $T; $span_wids; $drop_side):
  (cells_md(($arr.segments // []); $T)) as $cells
  | ($arr.bindings // {}) as $binds
  | (if ($drop_side == "east" or $drop_side == "west") then "v" else "h" end) as $cax
  | (if ($drop_side == "east" or $drop_side == "south") then "max" else "min" end) as $faceside
  | ( [ $span_wids[] as $w
        | ( [ $binds | to_entries[] | select(((.value.contents[0].window_id) // .value.window_id) == $w) ][0].key ) as $ak
        | ( [ $cells[] | select(_anchor_key(.) == ($ak // "")) ][0] ) ] ) as $sc
  | if (($sc | length) == 0) or any($sc[]; . == null) then null
    else
      ( [ $sc[] | .frame
          | (if $cax == "v" then (if $faceside == "max" then G::frame_max_x(.) else G::frame_min_x(.) end)
             else (if $faceside == "max" then G::frame_max_y(.) else G::frame_min_y(.) end) end) ] ) as $faces
      | if ((($faces | max) - ($faces | min)) > TOL) then null   # run not collinear on the face
        else
          ($faces[0]) as $coord
          | ( [ $sc[] | .frame | (if $cax == "v" then G::frame_min_y(.) else G::frame_min_x(.) end) ] | min ) as $run_lo
          | ( [ $sc[] | .frame | (if $cax == "v" then G::frame_max_y(.) else G::frame_max_x(.) end) ] | max ) as $run_hi
          | { axis: $cax, coord: $coord, lo: $run_lo, hi: $run_hi }
        end
    end;

# ── edges_rec: edges_md lifted — each nested parcel contributes its own edges/corners ──
# The gesture grab-point set, recursed. _edges_rec_at emits THIS sub-bag's segments as edges
# (tagged display_id) + its v×h crossings as corners (via _bag_corners, tagged display_id),
# then descends each INTERIOR cell to contribute the child parcel's own edges/corners WITHIN
# the child's frame (the segments are already in absolute coords over the parent cell.frame,
# so they compose directly). edges_rec fans out per display via _bags exactly as edges_md and
# sorts edges by [display_id, axis, coord, lo] / corners by [display_id, x, y] verbatim. Flat:
# no interior cell exists → the per-cell child fold contributes nothing → == edges_md.
def _edges_rec_at($arr; $cv; $did; $path):
  ( [ ($arr.segments // [])[] | . + { display_id: $did } ] ) as $own_e
  | ( [ _bag_corners({ segments: ($arr.segments // []) })[] | . + { display_id: $did } ] ) as $own_c
  | ( [ cells(($arr.segments // []); $cv)[]
        | . as $c
        | ("\($did):\($c.i0):\($c.j0)") as $localkey
        | (($arr.bindings // {})[$localkey].nested // null) as $kid
        | select((($kid.segments // []) | length) > 0)
        | _edges_rec_at({ segments: $kid.segments, bindings: ($kid.bindings // {}) };
                        $c.frame; $did; ($path + [[$c.i0, $c.j0]])) ] ) as $kids
  | { edges: ($own_e + [ $kids[].edges[] ]),
      corners: ($own_c + [ $kids[].corners[] ]) };

def edges_rec($arr; $T):
  ( reduce _bags(($arr.segments // []); $T)[] as $b ({ edges: [], corners: [] };
      (_edges_rec_at({ segments: $b.segments, bindings: ($arr.bindings // {}) };
                     $b.rect; $b.display_id; [])) as $r
      | { edges: (.edges + $r.edges), corners: (.corners + $r.corners) }) )
  | { edges: (.edges | sort_by([.display_id, .axis, .coord, .lo])),
      corners: (.corners | sort_by([.display_id, .x, .y])) };
