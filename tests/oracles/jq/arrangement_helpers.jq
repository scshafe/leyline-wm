# arrangement_helpers.jq — leaf primitives extracted from arrangement.jq
# (consolidation: the bottom numeric/set-utility layer). These are PRIVATE
# helpers (no AR::/A:: caller); arrangement.jq `include`s this file so they
# remain callable there. Kept private by jq's include-doesn't-re-export rule.
#
import "geometry" as G;
import "parcel" as P;
import "floorplan" as FP;

# The shared frame-tolerance alias these leaves use (same def as arrangement.jq's
# public `TOL`). Local here because jq's `include` does not re-export across the
# `import as AR` boundary, so the includer's `TOL` is not visible in this file.
def TOL: G::TOL;

# ── atom grid: coordinate-compress (arrangement.py:88) ────────────────────────
# Gather every coordinate that can BOUND a cell edge into a sorted, de-duplicated
# axis. For xs: the two canvas x-faces, every v segment's coord, and every h
# segment's lo/hi endpoints (an h segment that starts/ends mid-canvas creates a
# vertical atom boundary there). Symmetric for ys. Dedup is within TOL — two
# coords closer than TOL are the same gridline (rounded-int frames make this exact
# on the slicing subset). The atom grid is then the (|xs|-1) × (|ys|-1) lattice of
# rects [xs[i],xs[i+1]] × [ys[j],ys[j+1]].
def _dedup_sorted($coords):
  ($coords | sort) as $s
  | reduce $s[] as $c ([];
      if (length == 0) or (G::fabs($c - .[-1]) > TOL)
      then . + [$c] else . end);

# ── DSU (union-find) in pure jq ───────────────────────────────────────────────
# The Python mutable DSU becomes a parent-MAP (object keyed by the integer atom
# index as a string) threaded through a reduce over the union pairs. `find` walks
# parent links to the root (correctness needs only a full walk-to-root; path
# compression is an unneeded optimization in a one-shot derivation). `_union`
# points a's root at b's root. Keys are stringified ints; jq object access coerces.
def _find($parent; $a):
  # Walk to root: a node whose parent is itself (or absent → itself).
  { cur: $a }
  | until( ($parent[(.cur|tostring)] // .cur) == .cur ;
           .cur = ($parent[(.cur|tostring)]) )
  | .cur;

def _union($parent; $a; $b):
  (_find($parent; $a)) as $ra
  | (_find($parent; $b)) as $rb
  | if $ra == $rb then $parent
    else ($parent | .[($ra|tostring)] = $rb) end;

# The gutter inset that bridges centreline cells -> floorplan's gap-inset frames.
# cells() (line-primary) abut EDGE-TO-EDGE at the segment centreline; floorplan's
# cells are inset by gap/2 on each INTERIOR face (the rendered gutter). gutter()
# re-applies that inset so the equiv oracle's rect SET matches floorplan's exactly:
# a cell face that sits at the canvas boundary is left flush (it is the outer
# gap, already carved by canvas_rect); an INTERIOR face is pulled in by gap/2.
# At gap=0 this is the identity (centreline IS the face) — so equiv_gapless_grid
# matches raw and equiv_grid_2x2 matches inset-bridged, settling the open question
# with ONE consistent rule (inset every interior face by gap/2), not a per-fixture
# special case.
def _inset_interior($cell; $canvas; $gap):
  ($gap / 2) as $hg
  | ($cell.frame) as $f
  | (G::frame_min_x($f)) as $x0 | (G::frame_max_x($f)) as $x1
  | (G::frame_min_y($f)) as $y0 | (G::frame_max_y($f)) as $y1
  | (if (G::fabs($x0 - G::frame_min_x($canvas)) <= TOL) then $x0 else $x0 + $hg end) as $nx0
  | (if (G::fabs($x1 - G::frame_max_x($canvas)) <= TOL) then $x1 else $x1 - $hg end) as $nx1
  | (if (G::fabs($y0 - G::frame_min_y($canvas)) <= TOL) then $y0 else $y0 + $hg end) as $ny0
  | (if (G::fabs($y1 - G::frame_max_y($canvas)) <= TOL) then $y1 else $y1 - $hg end) as $ny1
  | { x: $nx0, y: $ny0, w: ($nx1 - $nx0), h: ($ny1 - $ny0) };

# Does a segment's FULL extent sit inside a display's inset rect (±TOL)? A valid
# authored segment lives entirely within ONE display's rect; a segment whose
# extent CROSSES a _canvas rect boundary is malformed (impossible from valid
# authoring) and is REJECTED, not homed — asserted here so a future authoring bug
# surfaces as a fixture failure, never a silent fused cell. For a `v` segment the
# coord must lie within [x0,x1] and the [lo,hi] y-span within [y0,y1]; symmetric
# for `h`.
def _segment_in_rect($seg; $rect):
  (G::frame_min_x($rect) - TOL) as $x0 | (G::frame_max_x($rect) + TOL) as $x1
  | (G::frame_min_y($rect) - TOL) as $y0 | (G::frame_max_y($rect) + TOL) as $y1
  | if $seg.axis == "v"
    then ($seg.coord >= $x0) and ($seg.coord <= $x1)
         and ($seg.lo >= $y0) and ($seg.hi <= $y1)
    else ($seg.coord >= $y0) and ($seg.coord <= $y1)
         and ($seg.lo >= $x0) and ($seg.hi <= $x1)
    end;

# ── edges_md / corners_md: the cross-gap regression-lock ──────────────────────
# Step 6 of S4. Within a bag, the homed segments ARE the gridlines (the line-primary
# edges), and a corner is a v×h crossing of two homed segments. Derived PER bag then
# unioned — so an edge or corner can only ever join structure on the SAME display.
# The derived edge/corner set is therefore STRUCTURALLY free of any artifact whose
# endpoints sit on different displays (no segment homes across the seam — _bags
# rejects a cross-seam segment), which is the precondition that would have to break
# for the old multi-display thrash to return. The flush 2-display worst case (empty
# bags → []) is the explicit anti-thrash lock. Each edge/corner carries its bag's
# display_id so the union is provably per-display.
def _bag_corners($bag):
  ($bag.segments | map(select(.axis == "v"))) as $vs
  | ($bag.segments | map(select(.axis == "h"))) as $hs
  | [ $vs[] as $v | $hs[] as $h
      # a v×h crossing: the v's coord lies within the h's [lo,hi] x-span and the
      # h's coord within the v's [lo,hi] y-span (within TOL) — both segments pass
      # through {x:$v.coord, y:$h.coord}.
      | select( ($h.lo - TOL <= $v.coord) and ($v.coord <= $h.hi + TOL)
                and ($v.lo - TOL <= $h.coord) and ($h.coord <= $v.hi + TOL) )
      | { x: $v.coord, y: $h.coord } ];

# ── carry-gate re-key tolerance (Fork A, 2026-06-14) ──────────────────────────
# When a divider crosses a bare collinear seam, a cell's atom-grid column index
# shifts (e.g. 1:4:1 -> 1:3:1), so the EXACT anchor key misses the side-table and
# the window is wrongly dropped from the carryable set — even though the partition
# is geometrically intact. These helpers resolve such RE-KEYED cells to their
# window by geometry, as an ADDITIVE fallback BEHIND the exact-key lookup: the
# geometric arm fires ONLY for a cell the exact key missed, so every key-matching
# scene (goldens, roundtrips, authoring) is byte-identical.
# Plan: docs/history/plans-retired-2026-08-11/2026-06-14-carry-gate-rekey-tolerance.md
#
# Clamped rect-intersection area of two {x,y,w,h} frames — 0 on any non-positive
# extent. A collapsed/degenerate cell (a genuinely-flattening move) overlaps
# nothing, so it forms no pair, matches no window, and the gate STILL refuses
# (the S-P5 / A8 false-negative the carry-gate exists to catch is preserved).
def _isect_area($a; $b):
  ( ([($a.x + $a.w), ($b.x + $b.w)] | min) - ([$a.x, $b.x] | max) ) as $iw
  | ( ([($a.y + $a.h), ($b.y + $b.h)] | min) - ([$a.y, $b.y] | max) ) as $ih
  | if ($iw > 0 and $ih > 0) then ($iw * $ih) else 0 end;

# ── _span_minus: a divider span [lo,hi] with the sub-interval [a,b] removed ────
# 0/1/2 sub-spans. End-removal → 1 (shrink), middle-removal → 2 (split), whole → []
# (local drop). a,b are the goner cell's own faces (existing perpendicular coords), so a
# shrunk endpoint anchors on a real gridline (no dangling). A remnant ≤ TOL is noise → dropped.
def _span_minus($lo; $hi; $a; $b):
  ( (if ($a - $lo) > TOL then [ { lo: $lo, hi: $a } ] else [] end)
  + (if ($hi - $b) > TOL then [ { lo: $b, hi: $hi } ] else [] end) );

# ── _reclaim_edit: merge the goner cell across ONE face → edited segment bag ────
# $segs the bag, $g the goner RAW cell frame, $dir "below"|"above"|"left"|"right". The
# face divider is the (single, collinear-merged) segment forming that face. Returns
# { segs, local } or null when the face is a canvas boundary (no divider → no merge) or
# the divider is ambiguous (>1 collinear segment, e.g. a prior split — conservatively skip).
def _reclaim_edit($segs; $g; $dir):
  (G::frame_min_x($g)) as $gx0 | (G::frame_max_x($g)) as $gx1
  | (G::frame_min_y($g)) as $gy0 | (G::frame_max_y($g)) as $gy1
  | ( if   $dir == "below" then { axis: "h", coord: $gy1, a: $gx0, b: $gx1 }
      elif $dir == "above" then { axis: "h", coord: $gy0, a: $gx0, b: $gx1 }
      elif $dir == "right" then { axis: "v", coord: $gx1, a: $gy0, b: $gy1 }
      else                      { axis: "v", coord: $gx0, a: $gy0, b: $gy1 } end ) as $fc
  | ( [ $segs | to_entries[]
        | select( (.value.axis == $fc.axis)
                  and (G::fabs(.value.coord - $fc.coord) <= TOL)
                  and (.value.lo <= $fc.a + TOL) and (.value.hi >= $fc.b - TOL) ) ] ) as $hits
  | if ($hits | length) != 1 then null
    else
      ($hits[0]) as $h
      | (_span_minus($h.value.lo; $h.value.hi; $fc.a; $fc.b)) as $rem
      | { segs: ( [ $segs | to_entries[] | select(.key != $h.key) | .value ]
                  + [ $rem[] | ($h.value + { lo: .lo, hi: .hi }) ] ),
          local: (($rem | length) == 0) }
    end;

# ── _reclaim_grow_edit: merge the goner cell into a SUBDIVIDED neighbour (no-holes) ─
# When the goner sits against a neighbour that is itself split (≥1 perpendicular divider
# anchored on the shared face), _reclaim_edit's plain drop leaves those perpendiculars
# DANGLING (they no longer reach a bounding gridline → invalid partition → reserved hole).
# This variant drops the face divider AND GROWS the sub-cells into the freed space by
# extending each anchored perpendicular's near endpoint to the goner's FAR edge — so the
# grid SURVIVES, no hole (the Wave-1 no-holes spirit: neighbours stretch to fill). Returns
# { segs } or null (no face divider, or NO perpendicular to grow → it would just be the plain
# drop _reclaim_edit already tried — don't duplicate). The caller validates end-to-end
# (valid_md + exact cell-count + rekey-conservation), so a bad grow falls through harmlessly.
def _reclaim_grow_edit($segs; $g; $dir):
  (G::frame_min_x($g)) as $gx0 | (G::frame_max_x($g)) as $gx1
  | (G::frame_min_y($g)) as $gy0 | (G::frame_max_y($g)) as $gy1
  | ( if   $dir == "below" then { axis:"h", coord:$gy1, sl:$gx0, sh:$gx1, pax:"v", near:$gy1, far:$gy0, ext:"lo" }
      elif $dir == "above" then { axis:"h", coord:$gy0, sl:$gx0, sh:$gx1, pax:"v", near:$gy0, far:$gy1, ext:"hi" }
      elif $dir == "right" then { axis:"v", coord:$gx1, sl:$gy0, sh:$gy1, pax:"h", near:$gx1, far:$gx0, ext:"lo" }
      else                      { axis:"v", coord:$gx0, sl:$gy0, sh:$gy1, pax:"h", near:$gx0, far:$gx1, ext:"hi" } end ) as $fc
  | ( [ $segs | to_entries[]
        | select( (.value.axis == $fc.axis) and (G::fabs(.value.coord - $fc.coord) <= TOL)
                  and (.value.lo <= $fc.sl + TOL) and (.value.hi >= $fc.sh - TOL) ) ] ) as $hits
  | if ($hits | length) != 1 then null
    else
      ($hits[0]) as $h
      | (_span_minus($h.value.lo; $h.value.hi; $fc.sl; $fc.sh)) as $rem
      # a perpendicular qualifies to grow: same perp axis, coord strictly INSIDE the goner
      # span (an interior divider, not a side wall), with the chosen endpoint AT the face.
      | ( [ $segs | to_entries[] | .value
            | select( (.axis == $fc.pax) and (.coord > $fc.sl + TOL) and (.coord < $fc.sh - TOL)
                      and ( if $fc.ext == "lo" then (G::fabs(.lo - $fc.near) <= TOL)
                                               else (G::fabs(.hi - $fc.near) <= TOL) end ) ) ] | length ) as $nperp
      | if $nperp == 0 then null                                    # nothing to grow → it's the plain drop
        else
          { segs: ( [ $segs | to_entries[] | select(.key != $h.key) | .value
                      | if ( (.axis == $fc.pax) and (.coord > $fc.sl + TOL) and (.coord < $fc.sh - TOL)
                             and ( if $fc.ext == "lo" then (G::fabs(.lo - $fc.near) <= TOL)
                                                      else (G::fabs(.hi - $fc.near) <= TOL) end ) )
                        then (if $fc.ext == "lo" then .lo = $fc.far else .hi = $fc.far end) else . end ]
                    + [ $rem[] | ($h.value + { lo: .lo, hi: .hi }) ] ) }
        end
    end;

# ── _stack_cell_attrs: project FP::stacks onto cells by the top's region ──────────
# Compose FP::stacks($tree) (the tree-side stack inventory, read straight from the
# tree — floorplan.jq:298) with P::project (the leaf dispositions). For each stack
# node, the cell it collapses to is the cell whose MIN-CORNER equals the top's
# PRESENTED frame min-corner (the same min-corner match bridge_arrangement uses to
# home a presented leaf to its cell — NOT a forked matcher). The attribute carries
# FP::stacks' members/top/source/depth VERBATIM (the descriptor agreement the oracle
# demands). A stack whose top presents NOTHING (a dangling-top stack: top resolves to
# a non-child → project drops all children, parcel.jq:250) has NO presented frame →
# it homes to no cell (frame:null), surfacing as an unattached stack the conservation
# oracle catches. Returns [ { frame, stack:{members,top,source,depth} } ] keyed for a
# min-corner join against cells.
#
# NOTE the stack's TOP may be an internal node (a row/col subtree, e.g. context_switch's
# `front`); its presented region is the UNION min-corner of its presented descendant
# leaves. We read the top's presented frame as the min over the presented frames of the
# bound leaves UNDER the top — project already laid them out from the top's slot origin,
# so the min-corner is the top region's origin (the cell's lo-corner). For a top that is
# itself a leaf this is just its own frame.
def _top_region_origin($nodes; $proj; $topid):
  ( [ (P::closure($nodes; [$topid])) | keys[]
      | select(P::is_leaf($nodes[.]) and (($proj.leaves[.].presented // false) == true)
               and (($proj.leaves[.].desired_frame // null) != null))
      | $proj.leaves[.].desired_frame ] ) as $pf
  | if ($pf | length) == 0 then null
    else { x: ([ $pf[] | G::frame_min_x(.) ] | min),
           y: ([ $pf[] | G::frame_min_y(.) ] | min) }
    end;

def _stack_cell_attrs($tree; $topo):
  ($tree.nodes // {}) as $nodes
  | (P::project($tree; $topo)) as $proj
  | [ FP::stacks($tree)[]
      | . as $s
      | (_top_region_origin($nodes; $proj; $s.top)) as $origin
      | { origin: $origin,
          stack: { members: $s.members, top: $s.top,
                   source: $s.source, depth: $s.depth } } ];

# _bbox_contains: strict containment (±TOL) for the nesting relation — strictly LARGER ⇒ proper parent.
def _bbox_contains($outer; $inner):
  ($outer.x - TOL <= $inner.x) and ($inner.x + $inner.w <= $outer.x + $outer.w + TOL)
  and ($outer.y - TOL <= $inner.y) and ($inner.y + $inner.h <= $outer.y + $outer.h + TOL)
  and (($outer.w * $outer.h) > ($inner.w * $inner.h));

# _promotion_parent: the smallest OTHER promotion whose coord_map strictly contains $p's
# coord_map — $p's nesting parent (null at top level). The union-find nesting relation
# (A nests in B iff A.coord_map ⊂ B.coord_map), the SAME containment the derived tree uses.
def _promotion_parent($p; $promos):
  ( [ $promos[] | select(.id != $p.id) | select(_bbox_contains(.coord_map; $p.coord_map)) ]
    | sort_by(.coord_map.w * .coord_map.h) | .[0].id // null );

# _derive_at: relocate the promotions whose nesting parent is $parent_id into THIS bag's
# child bindings, recursing into each child for its OWN nested promotions (DEEPEST-FIRST is
# implied by the forest recursion — a child level is authored fully before its segments are
# returned). For each such promotion P: its interior lines (strictly inside coord_map, over
# THIS bag) become the child's segments (recursively re-derived for grandchildren); they are
# REMOVED from this bag (the relocation). The child binding is keyed by P's anchor cell in the
# parent partition (the bag MINUS this level's relocated interiors). Frames are NEVER computed
# — interior segments are carried verbatim (the O2 carried-frame property).
# _frame_min_in_rect: a binding's frame min-corner lies STRICTLY inside $R's half-open
# extent [R.x, R.x+R.w) × [R.y, R.y+R.h) — the SAME frame-min-corner homing
# bridge_arrangement uses (arrangement.jq:681-687), reused not forked. The UPPER bound is
# STRICT (min_x < R.x+R.w - TOL): a window ABUTTING the block on its right/bottom face has
# its origin ON the shared boundary (e.g. 333's origin x=600 on a [0,600] block's right
# edge) and is NOT a block member — it lives in the SIBLING cell. The lower bound is
# inclusive (the block's own min-corner cell starts at R's origin). off_top members
# (frame null) have no cell and are excluded.
def _frame_min_in_rect($frame; $R):
  ($frame != null)
  and (G::frame_min_x($frame) >= $R.x - TOL) and (G::frame_min_x($frame) < $R.x + $R.w - TOL)
  and (G::frame_min_y($frame) >= $R.y - TOL) and (G::frame_min_y($frame) < $R.y + $R.h - TOL);
