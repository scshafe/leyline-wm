# Parcel — INTENT-LEVEL layout authors (P-VERBS P1; the audit's ws5 proposal).
#
# Goal-level verbs that author a whole per-display layout in one pass:
#   arrange_grid — "these windows in an N×M grid" (the four-equal-tiles episode's
#                  missing verb), now NO-HOLE (Wave 2, fork 4): underflow
#                  stretches-to-fill, overflow rejects-with-count.
#   arrange_auto — "fit these windows, no holes, aspect-optimal" — consumes a
#                  partition chosen by the pluggable arrange-optimizer registry
#                  (parcel/arrange-optimizers/) and lowers it the same way.
#
# DIALECT DISCIPLINE (the #1 hazard is a forked geometry dialect): this module
# mints NO segment math of its own. Both verbs lower through one shared author,
# _arrange_partition, which builds a synthetic BSP tree (a pinned per-display
# mount — the exact shape the cold author's _prior_tree uses) and lowers it
# through the CANONICAL AR::bridge_arrangement, so segments, gap insetting,
# anchor keys, and the binding shape are byte-compatible with every other author
# by construction.
#
# NO HOLES (Wave 2, fork 4): an author binds EVERY leaf to a real window
# (sum(parts) == window count); a band with fewer cells stretches each cell to
# fill its extent, and an empty trailing band simply does not exist. There is no
# {reserved} placeholder and no negative-sentinel leaf — the universal no-holes
# invariant (the organic adopt/prune path already re-proportions on close).
#
# Relationship to docs/ideal-wm/plans/tree-intent-api.md: these ARE that design's
# first concrete Intents, lowered directly (caller → pure author → single writer)
# without the queue/dispatch envelope — deferred until a second consumer needs it.

import "arrangement" as AR;
import "parcel" as P;
import "geometry" as G;

# The display's current bound windows in reading order (frame.y, frame.x, id).
def _display_order($store; $D):
  [ ($store.bindings // {}) | to_entries[]
    | select((.key | split(":")[0]) == $D)
    | (.value.contents[0] // .value)
    | select((.window_id // null) != null)
    | { window_id, frame } ]
  | sort_by([ (.frame.y // 0), (.frame.x // 0), .window_id ])
  | map(.window_id);

# _arrange_partition($store; $topo; $did; $orient; $parts; $order) → {ok, arr}
#   Build a NO-HOLE arrangement for $order across the bands described by
#   ($orient, $parts) and merge it into $store (replacing ONLY $did's content).
#   $orient ∈ {"rows","cols"}: "rows" stacks len($parts) bands vertically (mount
#   mode "col"), each band a horizontal row of parts[b] cells (mode "row");
#   "cols" places len($parts) bands side by side (mount mode "row"), each a
#   vertical column of parts[b] cells (mode "col"). $order fills the leaves
#   sequentially across bands; sum($parts) MUST equal ($order|length) — the
#   caller guarantees it, so EVERY leaf binds a real window (no sentinel, no
#   reserved hole). All new segments are PINNED (the grid survives settles).
def _arrange_partition($store; $topo; $did; $orient; $parts; $order):
  (P::norm_topology($topo)) as $T
  | ($did | tostring) as $D
  | ( [ ($T.displays // [])[] | select(((.id // .display_id) | tostring) == $D) ][0] // null ) as $disp
  | (if $orient == "cols" then "row" else "col" end) as $mount_mode
  | (if $orient == "cols" then "col" else "row" end) as $band_mode
  # cumulative leaf offset before each band (for sequential order fill)
  | ( reduce range(0; ($parts | length)) as $b ({off: 0, starts: []};
        .starts += [.off] | .off += $parts[$b]) | .starts ) as $starts
  | ( { root_id: "root",
        nodes: ( { root: { id: "root", mode: "region", children: ["d:\($D)"] },
                   "d:\($D)": { id: "d:\($D)", mode: $mount_mode, frame_source: "pinned",
                                display_id: ($disp.id // $disp.display_id),
                                children: [ range(0; ($parts | length)) | "b\(.)" ] } }
                 + ( [ range(0; ($parts | length)) as $b
                       | { ("b\($b)"):
                             { id: "b\($b)", mode: $band_mode,
                               children: [ range(0; $parts[$b]) | "b\($b)c\(.)" ] } } ] | add )
                 + ( [ range(0; ($parts | length)) as $b | range(0; $parts[$b]) as $i
                       | ($starts[$b] + $i) as $k
                       | { ("b\($b)c\($i)"): { id: "b\($b)c\($i)", window_id: $order[$k] } } ] | add ) ) } ) as $tree
  | (AR::bridge_arrangement($tree; $topo)) as $grid
  # CONSERVATION — the NO-HOLE invariant's self-witness (the Wave 2 fidelity
  # review's MAJOR): the bridge's centre-containment join DROPS a cell whose
  # centre marches off-display once interior gaps exceed the usable extent (a
  # dense band at a large gap), or a malformed partition can null/dup a leaf. If
  # the grid's bindings do not conserve $order EXACTLY (as a multiset), REJECT
  # loudly rather than persist a lossy store that still passes valid_md — the
  # same loud-reject posture as the overflow path.
  | ( [ ($grid.bindings // {})[] | .window_id // empty ] | sort ) as $bound
  | if ($bound != ($order | sort))
    then { ok: false,
           reason: "arrange: the partition \($parts) does not fit display \($D) — \((($order | length) - ($bound | length))) window(s) would be lost to cell collapse (use a smaller grid or reduce the gap)" }
    else
      # Pin every new segment (hand-managed display — survives settles).
      ( ($grid.segments // []) | map(.relation = "pinned") ) as $gsegs
      # Merge: replace ONLY this display's content; everything else verbatim. A
      # segment belongs to the display iff its midpoint is inside the display frame
      # (the insert.sh pin-pass idiom); a binding via its anchor-key prefix.
      | ($disp.frame) as $dr
      | ( ($store.segments // []) | map(select(
            ( (if .axis == "v" then [.coord, ((.lo + .hi) / 2)] else [((.lo + .hi) / 2), .coord] end) ) as $p
            | (($dr.x <= $p[0]) and ($p[0] <= ($dr.x + $dr.w))
               and ($dr.y <= $p[1]) and ($p[1] <= ($dr.y + $dr.h))) | not )) ) as $keep_segs
      | ( ($store.bindings // {})
          | with_entries(select((.key | split(":")[0]) != $D))
          # BIND-UNIQUENESS (the ws5-adversarial M3 hazard, witnessed on the 2-display
          # oracle case): a window re-homed INTO this layout must lose its old-display
          # binding — else it is bound twice. Its old cell becomes vacant (the
          # canonical absent-binding face); that display re-lays on its next settle.
          | with_entries(select(
              (((.value.contents // [])[0].window_id) // .value.window_id // null) as $w
              | ($w == null) or (($order | index($w)) == null) )) ) as $keep_binds
      # off_top: drop entries for windows the layout (re)binds; keep the rest.
      | ( ($store.off_top // []) | map(select(
            (.window_id // null) as $w | ($w == null) or (($order | index($w)) == null) )) ) as $keep_off
      | { ok: true,
          arr: { segments: ($keep_segs + $gsegs),
                 bindings: ($keep_binds + ($grid.bindings // {})),
                 off_top: $keep_off,
                 topology: ($store.topology // $T),
                 promotions: ($store.promotions // []) } }
    end;

# arrange_grid($store; $topo; $did; $n; $m; $wids) → {ok, arr} | {ok:false, reason}
#   $n,$m  : columns × rows (≥1 each). $wids : explicit order, or null → the
#            display's currently bound windows. NO-HOLE (Wave 2): the windows fill
#            the N×M grid row-major (top-pack); empty trailing rows drop so an
#            UNDERFLOW grid stretches-to-fill (no reserved holes). OVERFLOW (more
#            windows than cells) rejects with a count (the staked v1 policy).
def arrange_grid($store; $topo; $did; $n; $m; $wids):
  (P::norm_topology($topo)) as $T
  | ($did | tostring) as $D
  | ( [ ($T.displays // [])[] | select(((.id // .display_id) | tostring) == $D) ][0] // null ) as $disp
  | if $disp == null then { ok: false, reason: "no display \($D) in the topology" }
    elif ($n < 1) or ($m < 1) then { ok: false, reason: "grid wants N≥1 and M≥1 (got \($n)x\($m))" }
    elif ((($store.promotions // []) | length) > 0)
    then { ok: false, reason: "the store carries promotions — demote first (v1 promotion-touch reject)" }
    else
      ( if ($wids != null) then $wids else _display_order($store; $D) end ) as $order
      | (($n * $m)) as $cells_n
      | if (($order | length) > $cells_n)
        then { ok: false,
               reason: "\($order | length) windows exceed the \($n)x\($m) grid's \($cells_n) cells — \(($order | length) - $cells_n) surplus (pick --windows, or a bigger grid)" }
        elif (($order | length) == 0)
        then { ok: false, reason: "no windows to arrange on display \($D)" }
        else
          # Row-major TOP-PACK no-hole partition: row r gets clamp(W − r*N, 0, N)
          # cells; empty trailing rows drop (so the surviving cells stretch-to-
          # fill — the bridge re-proportions a band with fewer cells, no holes).
          ( [ range(0; $m) | (($order | length) - (. * $n))
              | if . > $n then $n elif . < 0 then 0 else . end ]
            | map(select(. > 0)) ) as $parts
          | _arrange_partition($store; $topo; $did; "rows"; $parts; $order)
        end
    end;

# arrange_auto($store; $topo; $did; $partition; $wids) → {ok, arr} | {ok:false, reason}
#   $partition : {orient, parts} chosen by an arrange-optimizer (the pluggable
#                registry). sum(parts) must equal the window count. NO-HOLE,
#                fit-all. $wids : explicit order, or null → display order.
def arrange_auto($store; $topo; $did; $partition; $wids):
  (P::norm_topology($topo)) as $T
  | ($did | tostring) as $D
  | ( [ ($T.displays // [])[] | select(((.id // .display_id) | tostring) == $D) ][0] // null ) as $disp
  | if $disp == null then { ok: false, reason: "no display \($D) in the topology" }
    elif ((($store.promotions // []) | length) > 0)
    then { ok: false, reason: "the store carries promotions — demote first (v1 promotion-touch reject)" }
    else
      ( if ($wids != null) then $wids else _display_order($store; $D) end ) as $order
      | ($partition.orient // "rows") as $orient
      | ($partition.parts // []) as $parts
      | if (($order | length) == 0)
        then { ok: false, reason: "no windows to arrange on display \($D)" }
        # The pluggable-registry TRUST BOUNDARY (the fidelity review's partition
        # MINOR): a third-party optimizer's malformed partition — an empty list, or
        # a non-positive/non-integer band — would null/dup leaves and silently lose
        # or double-bind windows. Reject it BEFORE lowering, ahead of the sum check,
        # so the failure names the cause. (The shipped aspect optimizer never trips
        # this; it guards future optimizers.)
        elif (($parts | length) == 0) or any($parts[]; (type != "number") or (. < 1) or (. != floor))
        then { ok: false, reason: "optimizer partition \($parts) has a non-positive/non-integer band — each band must hold ≥1 window" }
        elif (($parts | add // 0) != ($order | length))
        then { ok: false, reason: "optimizer partition \($parts) (sum \($parts | add // 0)) does not cover \($order | length) windows" }
        else _arrange_partition($store; $topo; $did; $orient; $parts; $order)
        end
    end;
