# Parcel floorplan — a PURE, read-only derived lens over project's frames.
#
# floorplan re-indexes the frames `project` already computes (lib/jq/parcel.jq)
# into a spatial *view* — cells / edges / corners — and ships the F1 no-overlap
# invariant as a check beside validate(). It is the substrate the grid layers
# read (Stage 6 shared gridlines → a grab compiles to a fan-out of op_set_ratio;
# Stage 7 solidify → a first-class grid node), and F1 is the safety net the
# Stage-4 stack valve must keep green.
#
# Like reconcile.jq / scope.jq, this is split OUT as a sibling module that
# COMPOSES parcel's primitives by import (the build-DRY/modular directive), NOT
# grown into parcel.jq. It is strictly READ-ONLY: it calls P::project +
# P::norm_topology, copies desired_frames VERBATIM (it never recomputes
# geometry), and feeds NOTHING back into placement — nothing in the engine
# imports it (the behavior-preserving guarantee, enforced by the
# `guard_no_engine_import` gate in parcel/tests.sh, which fails the suite if any
# engine file gains an `import "floorplan"`). Adding a new derived field here can
# never change a window's frame.
#
# ─────────────────────────────────────────────────────────────────────────
# floorplan($tree; $topo) →
#   { root:    {x,y,w,h},                            # the canvas rect (== project's seed)
#     cells:   [ {leaf_id, frame, display_id} ... ], # presented leaves, sorted [x,y,leaf_id]
#     edges:   [ {axis, coord, band, span, low_cells, high_cells, dividers} ... ], # merged gridline dividers
#     corners: [ {coord:{x,y}, edges:[{axis,coord,span,dividers}…], cells:[…]} ... ] } # interior grab points (v×h crossings)
#
#   A CELL is one presented leaf with a real frame: project's leaves filtered to
#   presented==true AND desired_frame!=null, the frame copied verbatim. A stack
#   contributes ONE cell (its top); a vacant leaf (frame null) is NOT a cell — so
#   F1 cannot false-positive on a stacked or reserved leaf. A leaf reached by >1
#   presented path (project's contention, I3) still yields ONE cell (project picks
#   one frame), so F1 is BLIND to contention by construction — contention is
#   project's `contention[]` concern, not F1's.
#
# f1($tree; $topo) → { ok, violations: [ ... ] }
#   The no-overlap invariant, mirroring validate's {ok, violations} shape and
#   living on its own harness surface beside validate(). It reads ONLY .cells +
#   .root, so it is provably independent of the edge/corner merge policy (Step 7.2
#   can reshape edges without touching an f1 expect). Violation kinds:
#     overlap:     {kind:"overlap", a, b, overlap_x, overlap_y}  # a real 2-D intersection
#     containment: {kind:"containment", cell, frame, root}       # a cell escaping root
#   Two cells OVERLAP iff min(frame_overlap_x, frame_overlap_y) > TOL — i.e. they
#   intersect on BOTH axes beyond tolerance; a gutter-touch (overlap 0 on one
#   axis) is disjoint. A cell is CONTAINED iff it sits inside root ±TOL on every
#   side. TOL = G::TOL (mirrors frame_eq's float discipline; project's frames are
#   rounded ints but the bump at parcel.jq:313-316 only ever GROWS them, so F1 is
#   strictly more sensitive, never less — it cannot false-green on an overlap).
# ─────────────────────────────────────────────────────────────────────────

import "geometry" as G;
import "parcel" as P;

# The canvas rect project seeds the root over — now COMPOSED from the shared
# helper P::canvas_rect($T) (parcel.jq) rather than a verbatim re-derivation. The
# Fork-4 duplication this lens carried since Stage 3 was paid down in S0 of the
# line-centric rollout (FOLLOWUPS canvas_rect item); the full sync/I6 byte-equality
# lock proves the extraction behaviour-preserving. Drift is still fixture-detectable
# (gap_grid_2x2 → {8,8,984,984} must hold in both project and floorplan).
def _root($T):
  P::canvas_rect($T);

# Presented leaves with a real frame → cells, sorted [x,y,leaf_id] (deterministic;
# jq -S sorts object keys, not arrays, so the array order is ours to fix).
def _cells($proj; $T):
  [ $proj.leaves | to_entries[]
    | select(.value.presented == true and .value.desired_frame != null)
    | { leaf_id:    .key,
        frame:      .value.desired_frame,
        display_id: G::assign_display(.value.desired_frame; $T.displays) } ]
  | sort_by([.frame.x, .frame.y, .leaf_id]);

# ── edges: collinear-merged gridline dividers (+ tree-node provenance) ────────
# An EDGE is the boundary line between two adjacent cell groups:
#   { axis:"v"|"h", coord:<gutter centerline>, band:{lo,hi} (gutter faces),
#     span:{lo,hi} (perpendicular extent), low_cells:[…], high_cells:[…],
#     dividers:[<node_id>…] }
# Built by (A) finding adjacent cell PAIRS separated by at most a gutter on one
# axis and overlapping on the other; (B) recording each as a raw divider — gutter
# CENTERLINE coord + band + perp span + the LCA split-node it bounds; then (C)
# collinear-MERGING raw dividers at the same (axis, coord-within-TOL) whose perp
# spans touch within gap+TOL into one gridline (an interval-merge sweep), unioning
# their cells + dividers. `dividers` (sorted-unique) is the Stage-6 op_set_ratio
# fan-out target AND the structural-vs-coincidental proof: ONE node = a true
# divider (gap_grid_2x2's vertical edge → ["d:1"]); N nodes = independent splits
# merely collinear right now (the two horizontal col-splits → ["c1","c2"]).
#
# VALIDITY GATE: a pair yields an edge only if its LCA is a row (→ vertical
# divider, cells side-by-side) or a col (→ horizontal). A region / mount / stack /
# fill LCA — e.g. two cells on SEPARATE display mounts — has no draggable split,
# so no edge. This is the robust cross-display exclusion: it survives edge-to-edge
# displays at any gap (subsuming a band-width filter), because the structural fact
# "no shared row/col split" is what actually makes a gridline meaningless there.
# gap=0 degenerates to a zero-width band (lo==hi==coord) — gap toggling changes
# only the band thickness, never edge identity.

# A root→leaf path is PRESENTABLE iff every stack-ancestor presents the path's
# child (child == top, or the first child when top is absent); non-stack parents
# present all children. Mirrors project_walk's `selected` gate (parcel.jq:250),
# so the lex-first presentable path is the one project lays the cell's frame from.
def _presentable($nodes; $path):
  all( range(0; ($path | length) - 1) as $i
       | ($nodes[$path[$i]]) as $p
       | if (($p.mode // "region") == "stack")
         then ($path[$i + 1] == ($p.top // (($p.children // [])[0])))
         else true end ; . );

# LCA of two leaves on their lex-first PRESENTED root→leaf paths — agreeing with
# project's winner policy (parcel.jq:292-294, which selects the lex-first
# presented path), so `dividers` names the node that actually GOVERNS the visible
# frames, never a hidden non-top stack branch. The LCA = last element of the
# contiguous common prefix; null if either leaf has no presentable path (then it
# is not a cell, so the pair yields no edge).
def _lca($nodes; $rootid; $a; $b):
  (P::paths_to($nodes; $rootid; $a) | map(select(_presentable($nodes; .))) | sort_by(join("/")) | .[0]) as $pa
  | (P::paths_to($nodes; $rootid; $b) | map(select(_presentable($nodes; .))) | sort_by(join("/")) | .[0]) as $pb
  | if ($pa == null) or ($pb == null) then null
    else
      ( reduce range(0; ([($pa|length), ($pb|length)] | min)) as $i ({n:0, brk:false};
          if .brk then .
          elif ($pa[$i] == $pb[$i]) then {n: ($i+1), brk:false}
          else {n:.n, brk:true} end) ) as $r
      | if $r.n == 0 then null else $pa[$r.n - 1] end
    end;

# A raw divider between two cells, or null. The LCA's mode selects the axis (row→v,
# col→h) and is the validity gate; geometry (perp overlap > TOL, facing gap in
# [-TOL, gap+TOL]) confirms true adjacency. band is normalized lo<=hi (a sub-TOL
# overlap, accepted as a touch, would otherwise invert it); coord stays the
# midpoint. For an n-ary (3+ child) row/col, two distinct edges can share one
# divider node — `dividers` identifies the NODE(s); {low_cells,high_cells}
# identify WHICH boundary in that node's ratio vector (Stage 6 needs both).
def _raw_edge($nodes; $rootid; $gap; $c1; $c2):
  G::TOL as $tol
  | _lca($nodes; $rootid; $c1.leaf_id; $c2.leaf_id) as $lca
  | (if $lca == null then "region" else ($nodes[$lca].mode // "region") end) as $lmode
  | ($c1.frame) as $fa | ($c2.frame) as $fb
  | if ($lmode == "row") and (G::frame_overlap_y($fa; $fb) > $tol)
    then
      (if (G::frame_min_x($fa) <= G::frame_min_x($fb)) then {l:$c1, r:$c2} else {l:$c2, r:$c1} end) as $p
      | (G::frame_max_x($p.l.frame)) as $lo | (G::frame_min_x($p.r.frame)) as $hi
      | if (($hi - $lo) >= (-$tol)) and (($hi - $lo) <= ($gap + $tol))
        then { axis:"v", coord: (($lo + $hi) / 2), band: {lo:([$lo,$hi]|min), hi:([$lo,$hi]|max)},
               span: {lo: ([G::frame_min_y($p.l.frame), G::frame_min_y($p.r.frame)] | max),
                      hi: ([G::frame_max_y($p.l.frame), G::frame_max_y($p.r.frame)] | min)},
               low_cells: [$p.l.leaf_id], high_cells: [$p.r.leaf_id], dividers: [$lca] }
        else null end
    elif ($lmode == "col") and (G::frame_overlap_x($fa; $fb) > $tol)
    then
      (if (G::frame_min_y($fa) <= G::frame_min_y($fb)) then {t:$c1, b:$c2} else {t:$c2, b:$c1} end) as $p
      | (G::frame_max_y($p.t.frame)) as $lo | (G::frame_min_y($p.b.frame)) as $hi
      | if (($hi - $lo) >= (-$tol)) and (($hi - $lo) <= ($gap + $tol))
        then { axis:"h", coord: (($lo + $hi) / 2), band: {lo:([$lo,$hi]|min), hi:([$lo,$hi]|max)},
               span: {lo: ([G::frame_min_x($p.t.frame), G::frame_min_x($p.b.frame)] | max),
                      hi: ([G::frame_max_x($p.t.frame), G::frame_max_x($p.b.frame)] | min)},
               low_cells: [$p.t.leaf_id], high_cells: [$p.b.leaf_id], dividers: [$lca] }
        else null end
    else null end;

# Cluster a coord-ascending edge list into co-located groups, anchored to each
# cluster's FIRST coord (NOT the running last member) — so a cluster's full width
# is bounded by TOL and a within-TOL "staircase" of genuinely-distinct gridlines
# cannot transitively chain into one over-wide cluster. Frames are floats; mirror
# frame_eq's tolerance.
def _cluster_by_coord($edges):
  reduce $edges[] as $e ([];
    if   (length == 0) then [[$e]]
    elif (G::fabs(($e.coord) - (.[-1][0].coord)) <= G::TOL)
    then (.[:-1] + [(.[-1] + [$e])])
    else (. + [[$e]]) end);

# True iff some presented cell FILLS the perpendicular gap interval (lo,hi) at the
# divider's coord — i.e. the cell sits on the divider line (its coord-axis extent
# contains coord) AND its perp-axis extent overlaps the interval with positive
# width. A real (un-split-at-coord) cell wedged between two collinear segments
# fills the gap; a genuine gutter (the perpendicular divider's track) does not,
# and a zero-width gap=0 touch (lo==hi) is never filled (overlap can't exceed 0).
def _gap_filled($cells; $axis; $coord; $lo; $hi):
  any( $cells[];
       .frame as $f
       | if $axis == "v"
         then (G::frame_contains_x($f; $coord))
              and ((([G::frame_max_y($f), $hi] | min) - ([G::frame_min_y($f), $lo] | max)) > 0)
         else (G::frame_contains_y($f; $coord))
              and ((([G::frame_max_x($f), $hi] | min) - ([G::frame_min_x($f), $lo] | max)) > 0)
         end );

# Interval-merge a co-located cluster: span-sorted, fuse two segments whose perp
# spans touch within gap+TOL into one gridline (unioning band/cells/dividers) —
# UNLESS a real cell fills the gap between them (then they are independent
# dividers that merely look collinear, e.g. a thin window wedged between two
# columns; the gap+TOL contiguity alone would wrongly fuse them). The gap+TOL
# bound (not TOL-only) is what coalesces two segments separated by a perpendicular
# GUTTER (the crossing gridline's track) into one shared gridline.
def _span_merge($cluster; $gap; $cells):
  ($cluster | sort_by(.span.lo)) as $s
  | reduce $s[] as $e ([];
      if (length == 0) then [$e]
      else
        (.[-1]) as $m
        | (($e.span.lo) - ($m.span.hi)) as $seg_gap
        | if ($seg_gap <= ($gap + G::TOL))
             and ((_gap_filled($cells; $m.axis; $m.coord; $m.span.hi; $e.span.lo)) | not)
          then (.[:-1]) + [ ($m
              | .span = {lo: ([$m.span.lo, $e.span.lo] | min), hi: ([$m.span.hi, $e.span.hi] | max)}
              | .band = {lo: ([$m.band.lo, $e.band.lo] | min), hi: ([$m.band.hi, $e.band.hi] | max)}
              | .low_cells  = ($m.low_cells  + $e.low_cells)
              | .high_cells = ($m.high_cells + $e.high_cells)
              | .dividers   = ($m.dividers   + $e.dividers)) ]
          else (. + [$e]) end
      end);

def _edges($cells; $nodes; $rootid; $gap):
  [ range(0; ($cells | length)) as $i
    | range($i + 1; ($cells | length)) as $j
    | _raw_edge($nodes; $rootid; $gap; $cells[$i]; $cells[$j])
    | select(. != null) ] as $raws
  | [ ($raws | group_by(.axis))[]
      | (sort_by(.coord)) as $bycoord
      | (_cluster_by_coord($bycoord))[]
      | (_span_merge(.; $gap; $cells))[] ]
  | map(.low_cells |= unique | .high_cells |= unique | .dividers |= unique)
  | sort_by([.axis, .coord, .span.lo]);

# ── corners: interior divider intersections (the Stage-6 grab points) ─────────
# A CORNER is where a vertical edge crosses a horizontal edge:
#   { coord:{x,y}, edges:[{axis,coord,span,dividers}…], cells:[leaf_id…] }
# A v-edge V and h-edge H cross iff V.coord lies within H's span and H.coord
# within V's span, EACH inclusive within gap+TOL — the same gutter-aware slack the
# cell test uses, because an edge's span is cell-derived (the flanking cells'
# extents) while a T-junction's stem divider sits at the GUTTER MIDPOINT, ~gap/2
# past that span end; a bare-TOL slack would silently drop every T-junction once
# gap > 2·TOL. The test counts full crosses (4 cells), T-junctions (a v-edge
# ENDING on an h-edge, 3 cells), and L-meetings (2 cells). Root's OUTER corners
# are not edges (edges are interior dividers only), so they are excluded.
#
# `edges` carries each incident edge as {axis, coord, span, dividers} — NOT a bare
# {axis,coord} key, which is non-unique whenever two collinear gridlines stay
# unmerged across a gap-filling cell (a wedge column, thin_cell): span (and the
# dividers themselves) disambiguate them and hand Stage 6 the op_set_ratio
# fan-out target directly, no join needed. `cells` is the set of presented cells
# GEOMETRICALLY incident — within gap+TOL of the corner on both axes
# (point-near-frame). Geometric incidence (not an edge-cell-set operation) is
# required for TWO reasons: it keeps a T-junction's stem cell (on V, not on H,
# which an intersection would drop) AND it LOCALIZES the grab against a merged
# full-span edge (whose low/high_cells span the WHOLE gridline, which a union
# would over-include).
def _corners($edges; $cells; $gap):
  ($gap + G::TOL) as $g
  | [ ($edges[] | select(.axis == "v")) as $v
      | ($edges[] | select(.axis == "h")) as $h
      | select( ($v.coord >= ($h.span.lo - $g)) and ($v.coord <= ($h.span.hi + $g))
                and ($h.coord >= ($v.span.lo - $g)) and ($h.coord <= ($v.span.hi + $g)) )
      | { coord: {x: $v.coord, y: $h.coord},
          edges: [ {axis:"v", coord:$v.coord, span:$v.span, dividers:$v.dividers},
                   {axis:"h", coord:$h.coord, span:$h.span, dividers:$h.dividers} ],
          cells: ( [ $cells[] | .frame as $f
                     | select( ($v.coord >= (G::frame_min_x($f) - $g)) and ($v.coord <= (G::frame_max_x($f) + $g))
                               and ($h.coord >= (G::frame_min_y($f) - $g)) and ($h.coord <= (G::frame_max_y($f) + $g)) )
                     | .leaf_id ] | unique ) } ]
  # A corner is a LOCATION, not a per-edge-pair record: coalesce crossings at the
  # same point (e.g. a v-edge meeting two same-coord-but-unmerged h-edges across a
  # filling cell) into one grab point, unioning incident edges + cells. The edges
  # carry span/dividers, so two distinct same-coord edges stay distinct under unique.
  | group_by(.coord)
  | map( { coord: .[0].coord,
           edges: ([ .[].edges[] ] | unique),
           cells: ([ .[].cells[] ] | unique) } )
  | sort_by([.coord.x, .coord.y]);

def floorplan($tree; $topo):
  P::norm_topology($topo) as $T
  | P::project($tree; $topo) as $proj
  | _cells($proj; $T) as $cells
  | ($T.gap // 0) as $gap
  | _edges($cells; ($tree.nodes // {}); ($tree.root_id); $gap) as $edges
  | { root:    _root($T),
      cells:   $cells,
      edges:   $edges,
      corners: _corners($edges; $cells; $gap) };

# ── stacks: the queryable stack inventory (Stage 4.6 — the legibility half) ────
# Every stack node, read straight from the TREE (no geometry — independent of project),
# so the operator can answer "this tile is a stack of N, showing X" and a future
# JankyBorders badge (rendering DEFERRED to the operator checkpoint) reads it:
#   { node, source:"valve"|"manual"|null, depth, nesting, top, members }
# `depth` = the CYCLE COUNT — immediate children, each a page you cycle/reveal through
# (a 3-member stack reports depth 3). `nesting` = how many stack ANCESTORS it sits under
# (a stack-in-a-stack reports nesting 1), distinguishing a flat deep stack from nested
# ones. `source` separates the auto valve fold ("valve") from a hand `op_stack_leaves`
# ("manual"); an authored stack with neither is null. A layout with NO stacks → []
# ("non-stacked reports none"). Standalone (NOT in floorplan's main output), so the
# Stage-3 floorplan/f1 fixtures are byte-unchanged.
def _stack_nesting($nodes; $rootid; $sid):
  (P::paths_to($nodes; $rootid; $sid) | sort_by(join("/")) | .[0]) as $path
  | if $path == null then 0
    else [ $path[0:-1][] | select(($nodes[.].mode // "region") == "stack") ] | length
    end;

def stacks($tree):
  ($tree.nodes // {}) as $nodes
  | ($tree.root_id) as $rootid
  | [ $nodes | to_entries[]
      | select((.value.mode // "region") == "stack")
      | .key as $sid | .value as $sn
      | ($sn.children // []) as $kids
      | { node:    $sid,
          source:  ($sn.stack_source // null),
          depth:   ($kids | length),
          nesting: _stack_nesting($nodes; $rootid; $sid),
          top:     ($sn.top // ($kids[0] // null)),
          members: $kids } ]
  | sort_by(.node);

# ── F1: the no-overlap invariant ─────────────────────────────────────────────
# Two frames intersect (a real overlap, not a gutter-touch) iff BOTH axes overlap
# beyond TOL — min of the two clamped overlaps > TOL.
def _overlaps($a; $b):
  ([ G::frame_overlap_x($a; $b), G::frame_overlap_y($a; $b) ] | min) > G::TOL;

# A frame sits inside $root on every side, within TOL.
def _contained($f; $root):
  (G::frame_min_x($f) >= G::frame_min_x($root) - G::TOL)
  and (G::frame_min_y($f) >= G::frame_min_y($root) - G::TOL)
  and (G::frame_max_x($f) <= G::frame_max_x($root) + G::TOL)
  and (G::frame_max_y($f) <= G::frame_max_y($root) + G::TOL);

def f1($tree; $topo):
  floorplan($tree; $topo) as $fp
  | ($fp.cells) as $cells
  | ($fp.root)  as $root
  # OVERLAP: every unordered cell pair that intersects on both axes. (a,b)
  # canonically leaf-id-ordered so the record is stable regardless of cell order.
  | ( [ range(0; ($cells | length)) as $i
        | range($i + 1; ($cells | length)) as $j
        | $cells[$i] as $a | $cells[$j] as $b
        | select(_overlaps($a.frame; $b.frame))
        | { kind:      "overlap",
            a:         ([$a.leaf_id, $b.leaf_id] | min),
            b:         ([$a.leaf_id, $b.leaf_id] | max),
            overlap_x: G::frame_overlap_x($a.frame; $b.frame),
            overlap_y: G::frame_overlap_y($a.frame; $b.frame) } ]
      | sort_by([.a, .b]) ) as $overlaps
  # CONTAINMENT: every cell that escapes root.
  | ( [ $cells[]
        | select((_contained(.frame; $root)) | not)
        | { kind: "containment", cell: .leaf_id, frame: .frame, root: $root } ]
      | sort_by(.cell) ) as $escapes
  | ($overlaps + $escapes) as $violations
  | { ok: (($violations | length) == 0), violations: $violations };
