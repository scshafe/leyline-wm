# Parcel engine — pure projection, identity resolution, invariant checker, ops.
#
# This is the Phase 1–2 core of the Parcel window-layout model
# (docs/parcel-model-design.md). It is PURE: zero backend calls, no window
# moves. It maps a tree + an observed display topology to a desired frame-map
# plus diagnostics, and binds leaf descriptors to live windows. The reconcile
# loop that drives a real backend (Phase 3) consumes this output; it does not
# live here.
#
# ─────────────────────────────────────────────────────────────────────────
# DATA MODEL
# ─────────────────────────────────────────────────────────────────────────
#
# A Parcel TREE is an id-keyed node table (same shape family as tree.jq):
#
#   { "root_id": "<id>", "nodes": { "<id>": <node>, ... } }
#
# A NODE is one of:
#   internal: { id, mode, frame_source?, ratios?, ratio_source?, top?,
#               children:[<id>...], display_id?, frame? }
#   leaf:     { id, binding?, window_id?, conformance?, min_size?, frame? }
#             (a leaf has NO children)
#
#   mode          : "row" | "col" | "stack" | "fill" | "region"  (default region)
#   frame_source  : "computed" | "pinned" | "authored"           (default computed)
#                   pinned   → frame is the observed display rect (display_id),
#                              never computed (I4); the mount-point role.
#                   authored → frame is the node's stored absolute rect.
#                   computed → frame is derived from parent mode + ratios.
#   ratios        : child split proportions for row/col (default equal).
#   ratio_source  : "computed" | "pinned"                        (default computed)
#                   pinned   → ratios were hand-set; auto-layout must NOT
#                              re-snap them — the split analogue of a pinned
#                              frame (I4). Stamped "pinned" by op_set_ratio.
#                   computed → ratios are auto-derived (equal, or re-flowed by
#                              auto-layout). The default when the field is absent.
#   top           : for stack mode, the id of the presented child (default
#                   first child). Switching context = retarget this.
#   window_id     : a leaf's resolved live window (null/absent ⇒ vacant if a
#                   binding is present). Identity resolution is Phase 2; here a
#                   leaf is "bound" iff window_id != null.
#
# An observed TOPOLOGY:
#   { "displays": [ { "id", "frame":[x,y,w,h]|{x,y,w,h},
#                     "usable":[x,y,w,h]? } ... ],
#     "dead_zones": [ [x,y,w,h] | {x,y,w,h} ... ] }
#   frame  = physical display rect (used for the I5 dead-zone test).
#   usable = the rect Parcels are laid into (menu-bar floor subtracted);
#            defaults to frame. A pinned mount point projects onto usable.
#   Frames accept either [x,y,w,h] arrays or {x,y,w,h} objects.
#
# ─────────────────────────────────────────────────────────────────────────
# project($tree; $topo) →
#   { leaves: { "<leaf_id>": { presented, desired_frame|null,
#                              conformance, overflow, vacant } },
#     contention:     [ <leaf_id> ... ],   # I3: claimed by >1 presented path
#     vacant:         [ <leaf_id> ... ],   # binding kept, no live window
#     dead_zone_hits: [ <leaf_id> ... ] }  # I5: placed off every display
#
# validate($tree) → { ok, violations: [ {invariant, ...} ... ] }
#   I1 acyclic · I2 single-parent leaves · I7 one window ↔ one leaf ·
#   I8 no duplicate child edge (same child twice in one parent) ·
#   I9 no orphan (every node reachable from root).
#   (I3/I5 are projection-time, reported by project; I4 holds by construction
#   — pinned frames are read from topology; I6 is reconcile-only, Phase 3.)
#
# resolve($tree; $observed) → { tree, bound, vacant, unmanaged }   (Phase 2, §7)
#   Binds each leaf's volatile window_id from the observed window set by app
#   (bundle_id) then document_path → title_pattern → ordinal. Sticky: a leaf
#   stays on its current window while it is still present. One window ↔ one leaf
#   (I7). Unmatched descriptors go vacant; unclaimed windows are unmanaged.
#   Idempotent — re-resolution IS the lifecycle model (created/destroyed/
#   launched/terminated all reduce to "the observed set changed, resolve again").
#
# apply_op($tree; $op; $args) → { ok, tree?, reason? }
#   guarded mutations: link, unlink_edge, delete_node, set_mode, set_ratio,
#   retarget_stack. link enforces I1 (no cycle) + I2 (no leaf multi-parent).
# ─────────────────────────────────────────────────────────────────────────

import "geometry" as G;
import "frame_ops" as F;

# ── frame coercion ────────────────────────────────────────────────────────
# as_frame / round_frame now live in frame_ops.jq (imported as F) — the
# designated shared frame-helpers module. reconcile.jq and autotile.jq are the
# other consumers; promoted there so they needn't reach into parcel for them.

# ── node helpers ───────────────────────────────────────────────────────────
def is_leaf($n): (($n.children // []) | length) == 0;
def node_mode($n): ($n.mode // "region");

# ── topology ────────────────────────────────────────────────────────────────
def norm_topology($topo):
  { displays:
      [ ($topo.displays // [])[]
        | { id: .id,
            frame:  F::round_frame(F::as_frame(.frame)),
            usable: F::round_frame(F::as_frame(.usable // .frame)),
            # Carry the CGDisplayIsMain flag (dropped pre-resilience) so the
            # absent-display remap can re-home pinned mounts to the MAIN display.
            main:   (.main // false) } ],
    dead_zones:
      [ ($topo.dead_zones // [])[] | F::round_frame(F::as_frame(.)) ],
    # Layout gap (px) carried in the normalized topology so it threads through
    # project → child_slots with NO signature change. Default 0 ⇒ behaviour-
    # preserving (split_slots/inset_frame at gap 0 == the pre-gap output). The
    # live value is stamped onto the topology by wm_parcel_topology (= the
    # configured border width); fixtures set it inline.
    gap: ($topo.gap // 0) };

def display_usable($T; $disp_id):
  ([ $T.displays[] | select(.id == $disp_id) ][0] // null)
  | if . == null then null else .usable end;

# Re-home pinned mounts whose display is NOT currently present: rewrite their
# display_id to the MAIN display's id (fallback: the first present display) so an
# unplugged display degrades to the main panel instead of dropping its windows
# (null frame) or hitting an unguarded null-frame arithmetic. Pure + NON-DESTRUCTIVE:
# rewrites the projection's LOCAL node map, never the stored tree — so the authored
# display_id survives and a replug restores the window to its home on the next settle.
# Present-display mounts are untouched (byte-identical projection ⇒ golden-equiv safe).
# Covers frame_source=="pinned" only — `authored` frames are read-side-only today (no minter),
# and the authored arm reads $cn.frame directly (no display_usable arithmetic ⇒ no crash); if a
# future op ever mints `authored`-on-a-display, extend this to re-home those too.
# $nodes = tree.nodes ; $T = normalized topology (carries .main per display).
def remap_absent_displays($nodes; $T):
  ([ $T.displays[] | .id ]) as $live
  | (([ $T.displays[] | select(.main) ][0] // $T.displays[0] // null) | .id) as $main
  | if $main == null then $nodes
    else
      ( $nodes | to_entries
        | map( .value.display_id as $did
               | if (.value.frame_source == "pinned")
                    and ($did != null)
                    and (($live | index($did)) == null)
                 then (.value.display_id = $main) else . end )
        | from_entries )
    end;

# A frame intersects some physical display (I5 — not a dead-zone hit).
def covers_any($f; $displays):
  if $f == null then false
  else any($displays[];
        (G::frame_overlap_x($f; .frame) > 0) and
        (G::frame_overlap_y($f; .frame) > 0))
  end;

# ── canvas seed ──────────────────────────────────────────────────────────────
# The root rect project tiles its children over: the USABLE union (menu-bar/Dock
# subtracted) inset by the layout gap (the OUTER gutter). Seeding over .usable
# (not the raw display frame) keeps tiling out of the menu-bar strip windows can
# never reach (endless reframe). Extracted here (Stage-7 DRY paydown, FOLLOWUPS
# canvas_rect item) so project, floorplan.jq, AND arrangement.jq all COMPOSE the
# one expression instead of forking it (the build-DRY directive). $T is the
# already-normalized topology (norm_topology output); behaviour-preserving by
# construction — it is the verbatim expression that lived inline at project's seed.
def canvas_rect($T):
  G::inset_frame((G::frames_union([$T.displays[].usable]) // {x:0,y:0,w:0,h:0}); ($T.gap // 0));

# ── proportional row/col split with a GAP gutter (edge-rounded) ──────────────
# Returns a per-child {lo, hi} pair (not shared boundaries) because a gap means
# child i's far edge no longer equals child i+1's near edge. Reserve (cnt-1)*gap of
# gutter, divide the REMAINING space by ratio, and offset each child by i*gap — so
# consecutive children sit exactly `gap` apart and each width is gap-reduced-
# proportional. $gap = 0 reproduces the old split_positions output exactly
# (avail==size, no offset → lo/hi are the old rounded boundaries).
def split_slots($lo; $size; $ratios; $gap):
  ($ratios | length) as $cnt
  | ($ratios | add) as $sum
  | (if $sum == 0 then 1 else $sum end) as $tot
  | ([($size - ($gap * ([$cnt - 1, 0] | max))), 0] | max) as $avail
  | ([0] + [foreach $ratios[] as $r (0; . + $r; .)]) as $cum
  | [ range(0; $cnt) as $i
      | { lo: (($lo + ($avail * $cum[$i]     / $tot) + ($gap * $i)) | round),
          hi: (($lo + ($avail * $cum[$i + 1] / $tot) + ($gap * $i)) | round) } ];

# ── min-size-aware fit (min-fit) ─────────────────────────────────────────────
# A window can refuse to shrink below an internal minimum (Chrome). These pure
# helpers make the SPLIT honour that floor where it can, so the desired frame
# becomes reachable and reconcile settles (the diff layer is untouched — the
# residual impossible case is handled by project's reachable-target bump). The
# min used here is the leaf's ACTUAL min_size (learned + stamped by minsize.jq,
# or authored), each axis defaulting to 0 — NOT frame_ops' 160x120 diagnostic
# default — so an unconstrained / empty-store tree is bit-identical to the
# pre-fit split (behaviour-preserving). split_slots itself is never modified.
def leaf_fit_min($n):
  ($n.min_size // $n.binding.min_size // {}) as $ms
  | { w: ($ms.w // 0), h: ($ms.h // 0) };

# The reachable-target bump (project's "Piece 3", factored out as THE single clamp
# dialect). A window can't be smaller than its own floor, so never TARGET a frame
# smaller than $min on either axis — grow the frame up to $min per axis. Origin is
# preserved; only size grows. Idempotent (max(max(w,m),m)==max(w,m)) → fixpoint-safe.
# THE one min-size arithmetic in the author path: P::project AND the line-native
# author (strategies/arrangement.jq) both call THIS — never re-coded (the #1 hazard).
def reach_bump($frame; $min):
  $frame | .w = ([.w, ($min.w // 0)] | max) | .h = ([.h, ($min.h // 0)] | max);

# slide_under (z-demotion Z-1): the DEMOTED frame author. A cell squeezed below
# its floor gets a min-sized frame anchored to overlap ACROSS $face into the
# expanding same-app neighbour — reach_bump cannot author this (it preserves
# ORIGIN, which for a +δ squeeze pokes AWAY from the neighbour; design doc 12,
# M1) — then slid back inside $R (the display bag rect) so a demoted frame
# never crosses a seam or a reserved edge (the D-fix thrash class). $face names
# the NEIGHBOUR's direction ("left"|"right"|"above"|"below", the reclaim-dir
# vocabulary): the frame's opposite edge stays anchored to the cell. The
# non-squeezed axis is untouched (min ≤ cell there, so the max is the identity).
# (NB the floor param is $mn, not $min: a jq def parameter `$min` ALSO defines a
# zero-arity function `min` that SHADOWS the builtin — the in-display clamp below
# calls bare `min`, which would silently return the floor object.)
def slide_under($cell; $mn; $face; $R):
  ([($mn.w // 0), ($cell.w // 0)] | max) as $w
  | ([($mn.h // 0), ($cell.h // 0)] | max) as $h
  | ( if   $face == "left"  then { x: ($cell.x + $cell.w - $w), y: $cell.y, w: $w, h: $h }
      elif $face == "right" then { x: $cell.x, y: $cell.y, w: $w, h: $h }
      elif $face == "above" then { x: $cell.x, y: ($cell.y + $cell.h - $h), w: $w, h: $h }
      else                       { x: $cell.x, y: $cell.y, w: $w, h: $h } end )
  | .x = ([ ([.x, ($R.x + $R.w - .w)] | min), $R.x ] | max)
  | .y = ([ ([.y, ($R.y + $R.h - .h)] | min), $R.y ] | max);

# Effective minimum of a whole subtree on each axis: row sums child widths
# (+ inner gaps) and maxes heights; col is the transpose; stack/region/fill
# overlap their children, so both axes max. Leaf → its fit-min. (Assumes an
# acyclic tree — every tree reaching project is validate-checked, I1.)
def subtree_min($nodes; $id; $gap):
  ($nodes[$id] // null) as $n
  | if   ($n == null) then {w:0, h:0}
    elif is_leaf($n)  then leaf_fit_min($n)
    else
      ($n.children // []) as $kids
      | ($kids | length) as $cnt
      | node_mode($n) as $mode
      | [ $kids[] | subtree_min($nodes; .; $gap) ] as $cm
      | if   ($cnt == 0)    then {w:0, h:0}
        elif $mode == "row" then { w: (([$cm[].w] | add) + ($gap * ($cnt - 1))), h: ([$cm[].h] | max) }
        elif $mode == "col" then { w: ([$cm[].w] | max), h: (([$cm[].h] | add) + ($gap * ($cnt - 1))) }
        else                     { w: ([$cm[].w] | max), h: ([$cm[].h] | max) } end
    end;

# 1-D min-fit solver. Given sibling sizes along an axis (summing to the gap-
# reduced available space) and each child's min on that axis, return adjusted
# sizes: grow every under-min child up to its min and reclaim the deficit from
# the above-min children in proportion to their slack (each donor floors at its
# own min — slack ≥ deficit is guaranteed once the mins fit). Two pass-through
# cases keep it behaviour-preserving: NO mins (sum 0) or mins that CANNOT all
# fit (sum > available) return the input unchanged — the impossible case stays
# stable-with-overlap and project hands each window a reachable target.
def fit_sizes($sizes; $mins):
  ($sizes | add) as $avail
  | ([$mins[]] | add) as $tmin
  | if ($tmin <= 0) or ($tmin > $avail) then $sizes
    else
      ([ range(0; ($sizes|length)) as $i | (($mins[$i] - $sizes[$i]) | if . > 0 then . else 0 end) ] | add) as $deficit
      | if $deficit <= 0 then $sizes
        else
          ([ range(0; ($sizes|length)) as $i | (($sizes[$i] - $mins[$i]) | if . > 0 then . else 0 end) ]) as $slacks
          | ([$slacks[]] | add) as $tslack
          | [ range(0; ($sizes|length)) as $i
              | if   (($mins[$i] - $sizes[$i]) > 0)              then $mins[$i]
                elif (($tslack > 0) and ($slacks[$i] > 0))       then ($sizes[$i] - ($deficit * ($slacks[$i] / $tslack)))
                else                                                  $sizes[$i] end ]
        end
    end;

# Slots for each child of an internal node, given the node's assigned frame.
# Returns [ {child_id, frame, selected} ]. `selected` is the stack gate:
# true for every mode except stack, where only `top` is selected.
def child_slots($nodes; $T; $n; $frame):
  ($n.children // []) as $kids
  | ($kids | length) as $cnt
  | node_mode($n) as $mode
  | ($T.gap // 0) as $gap
  | ( ($n.ratios // null)
      | if (type == "array" and length == $cnt and $cnt > 0)
        then . else [range(0; $cnt) | 1] end ) as $ratios
  | ( if   $mode == "row" then split_slots($frame.x; $frame.w; $ratios; $gap)
      elif $mode == "col" then split_slots($frame.y; $frame.h; $ratios; $gap)
      else null end ) as $slots0
  # Min-fit re-lay (Piece 2b): honour each child subtree's minimum on the split
  # axis. VETOED when ratios are hand-pinned (I4 — the user's split wins; an
  # overflow there falls through to project's reachable target). Inert when no
  # child carries a min ⇒ $slots is bit-identical to $slots0 (the rounded slot
  # sizes telescope back to split_slots' boundaries exactly). pinned/authored
  # children are held inert (min = their current slot) — they bypass the computed
  # slot below, so they neither grow nor donate.
  | ( if ($slots0 != null) and (($n.ratio_source // "computed") != "pinned")
      then
        ([ $slots0[] | (.hi - .lo) ]) as $sizes
        | ([ range(0; $cnt) as $i
             | (($nodes[$kids[$i]].frame_source // "computed")) as $fs
             | if $fs == "computed"
               then (if $mode == "row" then subtree_min($nodes; $kids[$i]; $gap).w
                                       else subtree_min($nodes; $kids[$i]; $gap).h end)
               else $sizes[$i] end ]) as $mins
        | fit_sizes($sizes; $mins) as $adj
        | (if $mode == "row" then $frame.x else $frame.y end) as $origin
        | [ foreach range(0; $cnt) as $i ({cum:0};
              (.cum) as $b
              | { cum: ($b + $adj[$i]),
                  lo:  (($origin + $b + ($gap * $i)) | round),
                  hi:  (($origin + $b + $adj[$i] + ($gap * $i)) | round) };
              {lo, hi}) ]
      else $slots0 end ) as $slots
  | [ range(0; $cnt) as $i
      | $kids[$i] as $cid
      | $nodes[$cid] as $cn
      | ($cn.frame_source // "computed") as $fs
      | ( if   $mode == "row"
          then {x: $slots[$i].lo, y: $frame.y, w: ($slots[$i].hi - $slots[$i].lo), h: $frame.h}
          elif $mode == "col"
          then {x: $frame.x, y: $slots[$i].lo, w: $frame.w, h: ($slots[$i].hi - $slots[$i].lo)}
          else $frame end ) as $computed
      # A pinned mount tiles its display's usable rect — inset by the gap so the
      # OUTER edge keeps a border-width margin (the inner gaps come from split_slots
      # above as the mount's own children are divided). authored frames are read as-is.
      | ( if   $fs == "pinned"   then G::inset_frame(display_usable($T; $cn.display_id); $gap)
          elif $fs == "authored" then F::round_frame(F::as_frame($cn.frame))
          else $computed end ) as $slot
      | { child_id: $cid,
          frame: $slot,
          selected: (if $mode == "stack"
                     then ($cid == ($n.top // $kids[0]))
                     else true end) } ];

# ── the walk: enumerate every root→leaf PATH ────────────────────────────────
# Multi-parent internal nodes mean a leaf can be reached by several paths;
# I3 (one presented place per leaf) is checked by aggregating these. A cheap
# path-membership guard makes a malformed cyclic tree terminate (validate
# reports the cycle separately).
def project_walk($nodes; $T; $id; $frame; $presented; $path):
  if ($path | index($id)) != null then []
  else
    $nodes[$id] as $n
    | ($path + [$id]) as $p
    | if is_leaf($n)
      then [ {leaf_id: $id, node: $n, frame: $frame, presented: $presented, path: $p} ]
      else
        ( child_slots($nodes; $T; $n; $frame) ) as $slots
        | reduce $slots[] as $s ([];
            . + project_walk($nodes; $T; $s.child_id; $s.frame;
                             ($presented and $s.selected); $p))
      end
  end;

def project($tree; $topo):
  norm_topology($topo) as $T
  | (remap_absent_displays(($tree.nodes // {}); $T)) as $nodes
  | ($tree.root_id) as $root
  # Seed the root over the USABLE union (menu-bar/Dock subtracted), not the raw
  # display frame: a computed root (e.g. an auto-tiled tree) tiles its children
  # across this rect directly, and windows can't occupy the menu-bar strip — so
  # tiling into .frame would set targets the windows can never reach (endless
  # reframe). Pinned mount-point children still read display_usable themselves;
  # .usable defaults to .frame when there's no inset (norm_topology).
  | (canvas_rect($T)) as $canvas
  | ( if ($root == null) or (($nodes[$root] // null) == null) then []
      else project_walk($nodes; $T; $root; $canvas; true; []) end ) as $visits
  | ($visits | group_by(.leaf_id)) as $groups
  | reduce $groups[] as $g (
      {leaves: {}, contention: [], vacant: [], dead_zone_hits: []};
      ($g[0].leaf_id) as $lid
      | ($g[0].node)  as $ln
      | ([ $g[] | select(.presented == true) ]) as $pres
      | ($pres | sort_by(.path | join("/"))) as $ps
      | ($ps[0] // null) as $win
      | (($pres | length) > 1)   as $contended
      | (($pres | length) >= 1)  as $is_pres
      | (($ln.window_id // null) != null) as $bound
      | (($ln | has("binding")) and (($ln.window_id // null) == null)) as $is_vacant
      | ($win.frame // null) as $wf
      | ($bound and $is_pres and ($wf != null)) as $placeable
      | (F::min_size($ln.min_size // $ln.binding.min_size // {})) as $m
      | (if $placeable then (($wf.w < $m.w) or ($wf.h < $m.h)) else false end) as $ovf
      | (if $placeable then (covers_any($wf; $T.displays) | not) else false end) as $dead
      # Reachable-target bump (Piece 3): a window can't be smaller than its own
      # floor, so never TARGET smaller than it — grow the slot up to the leaf's
      # min on each axis (fit-min, default 0 ⇒ no-op when unconstrained). In the
      # common case Piece 2b already grew the slot to its min (no change); for the
      # genuinely-impossible case (Σ mins > display) or an I4-vetoed pinned split,
      # this hands the window its HONEST achievable frame, so observed == desired
      # → frame_eq settles → it drops out of the circuit-breaker's rediff sig.
      # Origin is kept; only the size grows (the window overlaps a neighbour —
      # physics — but reconcile no longer thrashes). The diff layer is untouched.
      | (if $placeable then reach_bump($wf; leaf_fit_min($ln)) else null end) as $reach
      | .leaves[$lid] = {
          presented:     $is_pres,
          desired_frame: $reach,
          conformance:   ($ln.conformance // "conforming"),
          overflow:      $ovf,
          vacant:        $is_vacant }
      | (if $contended  then .contention     += [$lid] else . end)
      | (if $is_vacant  then .vacant         += [$lid] else . end)
      | (if $dead       then .dead_zone_hits += [$lid] else . end) )
  | .contention     |= (unique | sort)
  | .vacant         |= (unique | sort)
  | .dead_zone_hits |= (unique | sort);

# ── identity resolution (Phase 2): descriptor ↔ live window (§7) ─────────────
def win_app($w):  ($w.bundle_id // $w.app // null);
def desc_app($b): ($b.bundle_id // $b.app // null);

def descriptor_specificity($b):
  if   ($b | has("document_path")) then 3
  elif ($b | has("title_pattern")) then 2
  elif ($b | has("ordinal"))       then 1
  else 0 end;

# Stamp each observed window with a within-app input-order ordinal when absent
# — launch/stacking order, the stable disambiguator (never frame-proximity,
# which is circular: the engine *sets* the frames).
def norm_windows($observed):
  reduce (($observed // []) | to_entries[]) as $e (
    {out: [], counts: {}};
    (win_app($e.value) // "?") as $app
    | (.counts[$app] // 0) as $idx
    | .counts[$app] = ($idx + 1)
    | .out += [ $e.value + {ordinal: ($e.value.ordinal // $idx)} ])
  | .out;

def leaf_descriptors($nodes):
  [ $nodes | to_entries[]
    | select(.value | has("binding"))
    | {leaf_id: .key, binding: .value.binding, window_id: (.value.window_id // null)} ];

def resolve($tree; $observed):
  ($tree.nodes // {}) as $nodes
  | norm_windows($observed) as $wins
  | leaf_descriptors($nodes) as $descs
  | ( $wins | map({key: (.window_id | tostring), value: .}) | from_entries ) as $win_by_id
  # Pass A — sticky: keep a leaf on its current window if still present + same app.
  | ( reduce $descs[] as $d (
        {claimed: {}, byleaf: {}};
        ($d.window_id) as $wid
        | ($win_by_id[$wid | tostring] // null) as $w
        | if ($wid != null) and ($w != null)
             and (win_app($w) == desc_app($d.binding))
             and ((.claimed[$wid | tostring] // false) | not)
          then .claimed[$wid | tostring] = true
               | .byleaf[$d.leaf_id] = {window_id: $wid, tier: "sticky"}
          else . end ) ) as $stateA
  # Pass B — tiered match for the rest; highest-specificity descriptors claim first.
  | ( [ $descs[] | select(($stateA.byleaf[.leaf_id]) == null) ]
      | sort_by([ (0 - descriptor_specificity(.binding)),
                  (.binding.ordinal // 1000000), .leaf_id ]) ) as $rest
  | ( reduce $rest[] as $d ($stateA;
        . as $st
        | desc_app($d.binding) as $app
        | ( [ $wins[]
              | select((win_app(.) == $app)
                       and (($st.claimed[.window_id | tostring] // false) | not)) ] ) as $avail
        | ( if   ($d.binding | has("document_path"))
            then ($avail | map(select(.document_path == $d.binding.document_path)) | .[0])
            elif ($d.binding | has("title_pattern"))
            then ($avail | map(select((.title // "") | test($d.binding.title_pattern))) | .[0])
            elif ($d.binding | has("ordinal"))
            then ($avail | map(select(.ordinal == $d.binding.ordinal)) | .[0])
            else ($avail | sort_by(.ordinal) | .[0]) end ) as $cand
        | if $cand != null
          then .claimed[$cand.window_id | tostring] = true
               | .byleaf[$d.leaf_id] =
                   { window_id: $cand.window_id,
                     tier: (if   ($d.binding | has("document_path")) then "document"
                            elif ($d.binding | has("title_pattern")) then "title"
                            elif ($d.binding | has("ordinal"))       then "ordinal"
                            else "ordinal_auto" end) }
          else . end ) ) as $state
  | ($state.byleaf)  as $bl
  | ($state.claimed) as $claimed
  | { tree: ( $tree
              | .nodes = ( .nodes | with_entries(
                  if (.value | has("binding"))
                  then .value.window_id = ($bl[.key].window_id // null)
                  else . end )) ),
      bound:     ( [ $bl | to_entries[]
                     | {leaf_id: .key, window_id: .value.window_id, tier: .value.tier} ]
                   | sort_by(.leaf_id) ),
      vacant:    ( [ $descs[] | .leaf_id | select($bl[.] == null) ] | sort ),
      unmanaged: ( [ $wins[] | select(($claimed[.window_id | tostring] // false) | not)
                     | .window_id ] | sort ) };

# ── structural invariants (I1, I2, I7) ──────────────────────────────────────
# Iterative DFS closure following children from a seed set. Guarded by `seen`,
# so it terminates even on a cyclic table. Returns { "<id>": true }.
def closure($nodes; $seeds):
  { seen: {}, stack: ($seeds // []) }
  | until((.stack | length) == 0;
      (.stack[-1]) as $x
      | (.stack[0:-1]) as $rest
      | if (.seen[$x] // false)
        then { seen: .seen, stack: $rest }
        else { seen: (.seen + {($x): true}),
               stack: ($rest + ($nodes[$x].children // [])) }
        end)
  | .seen;

def parent_count($nodes; $id):
  reduce ($nodes | to_entries[]) as $e (0;
    if (($e.value.children // []) | index($id)) != null then . + 1 else . end);

def validate($tree):
  ($tree.nodes // {}) as $nodes
  # I1: a node reachable from its own children is on a cycle.
  | ([ $nodes | keys[] as $id
       | select((closure($nodes; ($nodes[$id].children // [])))[$id] // false)
       | $id ] | sort) as $i1
  # I2: a leaf must have at most one parent.
  | ([ $nodes | keys[] as $id
       | select(is_leaf($nodes[$id]) and (parent_count($nodes; $id) > 1))
       | $id ] | sort) as $i2
  # I7: a live window id maps to at most one leaf.
  | ( reduce ($nodes | to_entries[]) as $e ({};
        ($e.value.window_id // null) as $w
        | if $w == null then . else .[$w | tostring] += [$e.key] end) ) as $w2l
  | ([ $w2l | to_entries[] | select((.value | length) > 1)
       | {window_id: .key, leaves: (.value | sort)} ]) as $i7
  # I8: a parent must not list the same child twice (a DUPLICATED edge). Distinct
  # from I2 (a leaf with two DISTINCT parents): this is the same (parent,child)
  # edge appearing twice, which parent_count's index()-based count cannot see.
  # Legal multi-parent INTERNAL sharing (a child under several different parents)
  # is untouched — only intra-parent duplicates are flagged.
  | ([ $nodes | to_entries[]
       | ((.value.children // [])) as $kids
       | select(($kids | length) != ($kids | unique | length))
       | .key ] | sort) as $i8
  # I9: every node must be reachable from the root (no orphans). The op layer
  # prunes unreachable nodes (prune_unreachable), so an orphan is a malformation
  # — and an orphan focus target used to crash adopt's parent lookup. Empty tree
  # (no root_id) ⇒ no nodes ⇒ vacuously satisfied.
  | (closure($nodes; (if ($tree.root_id // null) != null then [$tree.root_id] else [] end))) as $reach
  | ([ $nodes | keys[] | select((($reach[.]) // false) | not) ] | sort) as $i9
  | ( []
      + (if ($i1 | length) > 0 then [{invariant:"I1", detail:"cycle", nodes:$i1}]  else [] end)
      + (if ($i2 | length) > 0 then [{invariant:"I2", detail:"leaf multi-parent", leaves:$i2}] else [] end)
      + (if ($i7 | length) > 0 then [{invariant:"I7", detail:"window shared by leaves", collisions:$i7}] else [] end)
      + (if ($i8 | length) > 0 then [{invariant:"I8", detail:"duplicate child edge", parents:$i8}] else [] end)
      + (if ($i9 | length) > 0 then [{invariant:"I9", detail:"unreachable node", nodes:$i9}] else [] end)
    ) as $violations
  | { ok: (($violations | length) == 0), violations: $violations };

# ── guarded operations ──────────────────────────────────────────────────────
def prune_unreachable($tree):
  # Guard the root seed exactly as validate's I9 does: closure(nodes; [null]) is a
  # hard error, so a null-root tree (e.g. after the last node is unlinked) prunes
  # to empty rather than crashing.
  (closure($tree.nodes; (if ($tree.root_id // null) != null then [$tree.root_id] else [] end))) as $live
  | $tree | .nodes = (.nodes | with_entries(select(.key as $k | $live[$k] // false)));

def op_link($tree; $parent; $child):
  ($tree.nodes) as $nodes
  | if   (($nodes[$parent] // null) == null) then {ok:false, reason:"no such parent: \($parent)"}
    elif (($nodes[$child]  // null) == null) then {ok:false, reason:"no such child: \($child)"}
    elif (($nodes[$parent].children // []) | index($child)) != null
      then {ok:false, reason:"edge exists"}
    elif (is_leaf($nodes[$child]) and (parent_count($nodes; $child) >= 1))
      then {ok:false, reason:"I2: leaf already has a parent"}
    elif ($parent == $child) or ((closure($nodes; [$child]))[$parent] // false)
      then {ok:false, reason:"I1: would create a cycle"}
    else {ok:true, tree: ($tree | .nodes[$parent].children = ((.nodes[$parent].children // []) + [$child]))}
    end;

def op_unlink_edge($tree; $parent; $child):
  if (($tree.nodes[$parent] // null) == null) then {ok:false, reason:"no such parent: \($parent)"}
  else
    ($tree | .nodes[$parent].children = ((.nodes[$parent].children // []) | map(select(. != $child))))
    | {ok:true, tree: prune_unreachable(.)}
  end;

def op_delete_node($tree; $node):
  if (($tree.nodes[$node] // null) == null) then {ok:false, reason:"no such node: \($node)"}
  else
    ( $tree
      | .nodes = (.nodes | with_entries(.value.children = ((.value.children // []) | map(select(. != $node)))))
      | del(.nodes[$node]) )
    | {ok:true, tree: prune_unreachable(.)}
  end;

def op_set_mode($tree; $node; $mode):
  if (($tree.nodes[$node] // null) == null) then {ok:false, reason:"no such node: \($node)"}
  else {ok:true, tree: ($tree | .nodes[$node].mode = $mode)} end;

# Setting a ratio is, by definition, a hand-set ratio: stamp ratio_source
# "pinned" so auto-layout (autotile.jq) leaves it alone — the split analogue of
# how an authored/pinned frame is read, never recomputed (I4).
def op_set_ratio($tree; $node; $ratios):
  if (($tree.nodes[$node] // null) == null) then {ok:false, reason:"no such node: \($node)"}
  else {ok:true, tree: ($tree
                        | .nodes[$node].ratios = $ratios
                        | .nodes[$node].ratio_source = "pinned")} end;

def op_retarget_stack($tree; $stack; $child):
  ($tree.nodes[$stack] // null) as $sn
  | if   ($sn == null) then {ok:false, reason:"no such node: \($stack)"}
    elif (node_mode($sn) != "stack") then {ok:false, reason:"not a stack: \($stack)"}
    elif (($sn.children // []) | index($child)) == null then {ok:false, reason:"\($child) is not a child of \($stack)"}
    else {ok:true, tree: ($tree | .nodes[$stack].top = $child)}
    end;

# All root→leaf id-paths from $root reaching $target (structural; multi-parent
# safe, cycle-guarded). Each path is [root_id, …, target]; [] if unreachable.
def paths_to($nodes; $root; $target):
  def go($id; $seen):
    if ($seen | index($id)) != null then []                       # cycle guard
    elif $id == $target then [[$id]]
    else ($seen + [$id]) as $s
      | [ ($nodes[$id].children // [])[] | go(.; $s)[] ] | map([$id] + .)
    end;
  go($root; []);

# E1 (§10): reveal a leaf — retarget EVERY stack-ancestor on the chosen
# (lexicographically-first, matching the I3 §13#7 winner policy) root→leaf path
# so the leaf becomes presented. Composes op_retarget_stack; non-stack ancestors
# (region/row/col/fill) are passed through. Idempotent: revealing an
# already-presented leaf sets tops that are already set.
def op_reveal_leaf($tree; $leaf):
  if (($tree.nodes[$leaf] // null) == null) then {ok:false, reason:"no such node: \($leaf)"}
  else
    (paths_to($tree.nodes; $tree.root_id; $leaf) | sort_by(join("/")) | .[0]) as $path
    | if ($path == null) then {ok:false, reason:"leaf not reachable from root: \($leaf)"}
      else
        reduce range(0; ($path | length) - 1) as $i
          ({ok:true, tree:$tree};
           if .ok then
             .tree as $t
             | (if (node_mode($t.nodes[$path[$i]]) == "stack")
                then op_retarget_stack($t; $path[$i]; $path[$i+1])
                else {ok:true, tree:$t} end)
           else . end)
      end
  end;

# op_stack_leaves($tree; $leaves): MANUAL stack — group a set of SIBLING leaves (≥2,
# one common parent) into a new stack node in their parent's slot. The hand-driven peer
# of the autotile valve's fold: it stamps stack_source:"manual" (NOT "valve"), so the
# balanced valve's un-fold-all-valve-first sweep (lib/jq/balance.jq) leaves it ALONE — a
# manual stack coexists with the auto valve and is reversed only by the operator. Guarded
# like the other ops (no such leaf / not-a-leaf / not-siblings / <2 / dup → {ok:false}).
# The new node N takes the parent-children slot of the EARLIEST stacked leaf (parent
# order); the others are removed; N's children + top follow PARENT order (top = earliest),
# so cycle/reveal switch a deterministic presented child. The parent's ratios (if any) are
# kept for the survivors and the stacked leaves' entries MERGED (summed) into N's single
# entry. On a PINNED parent this means no sibling resizes (I4 respected — a manual
# restructure merges within the pinned split, never re-snaps it); on a COMPUTED parent the
# merged ratios are transient (auto_proportion re-equalizes survivors next settle — the
# intended computed-node behavior). A length-mismatched ratios array is DROPPED (→ equal)
# rather than carried stale onto the new child list. If the parent is ITSELF a stack
# presenting an absorbed leaf, its now-dangling top is retargeted to N (else the subtree
# would go dark — the symmetric hazard to remove's autotile.jq:319 repair). The id is
# "s:<parent-order-first>" (== top; collision-safe, tree-deterministic) — a label, not
# load-bearing.
def op_stack_leaves($tree; $leaves):
  ($tree.nodes) as $nodes
  | ($tree.root_id) as $root
  | if (($leaves | type) != "array") or (($leaves | length) < 2)
    then {ok:false, reason:"stack_leaves: need >= 2 leaf ids"}
    elif (($leaves | unique | length) != ($leaves | length))
    then {ok:false, reason:"stack_leaves: duplicate leaf id"}
    elif any($leaves[]; ($nodes[.] // null) == null)
    then {ok:false, reason:"stack_leaves: a leaf id is not in the tree"}
    elif any($leaves[]; is_leaf($nodes[.]) | not)
    then {ok:false, reason:"stack_leaves: a target is not a leaf"}
    else
      ( [ $leaves[] | (paths_to($nodes; $root; .) | sort_by(join("/")) | .[0]) | (if (. == null) or ((. | length) < 2) then null else .[-2] end) ] ) as $parents
      | if any($parents[]; . == null) then {ok:false, reason:"stack_leaves: a leaf has no parent (root leaf / orphan)"}
        elif (($parents | unique | length) != 1) then {ok:false, reason:"stack_leaves: leaves are not siblings (need one common parent)"}
        else
          ($parents[0]) as $P
          | ($nodes[$P].children) as $pk
          | ([ range(0; ($pk | length)) as $i | select(($leaves | index($pk[$i])) != null) | $i ] | sort) as $idxs
          | ($idxs[0]) as $minpos
          | ([ $pk[] | . as $c | select(($leaves | index($c)) != null) ]) as $ordered   # leaves in PARENT order
          # The new node's id is keyed off the PARENT-order first leaf (== its top), so the
          # id names the presented child and is tree-deterministic regardless of arg order
          # (matching _split_node_id's scheme); collision-disambiguated like split.
          | ("s:" + ($ordered[0] | tostring)) as $S0
          | (if (($nodes[$S0]) // null) == null then $S0
             else (first(range(1; 1000000) | ($S0 + "." + tostring) | select((($nodes[.]) // null) == null)) // ($S0 + ".x")) end) as $N
          | ($nodes[$P].ratios // null) as $pr
          | ( $tree
              | .nodes[$N] = {id:$N, mode:"stack", stack_source:"manual", top:$ordered[0], children:$ordered}
              | .nodes[$P].children =
                  [ range(0; ($pk | length)) as $i
                    | if $i == $minpos then $N
                      elif (($leaves | index($pk[$i])) != null) then empty
                      else $pk[$i] end ]
              # If the PARENT is itself a stack presenting one of the absorbed leaves, its
              # `top` now dangles (no longer a child) → child_slots' fallback fires only when
              # top is ABSENT, so a stale top selects NOTHING and the whole subtree goes dark.
              # Retarget it to the new node so the freshly-stacked group becomes presented.
              # Mirrors the remove-path repair (autotile.jq:319-320) — the symmetric hazard.
              | (if (($leaves | index($nodes[$P].top // null)) != null) then .nodes[$P].top = $N else . end)
              # Parent ratios: MERGE (sum) the absorbed entries into the new node's single
              # entry, preserving survivors — but only when the original array is well-formed
              # (length == child count). On a length mismatch, DROP the stale array (→ equal)
              # rather than carry it stale onto a now-misaligned child list.
              | (if ($pr | type) == "array" and (($pr | length) == ($pk | length))
                 then .nodes[$P].ratios =
                   [ range(0; ($pk | length)) as $i
                     | if $i == $minpos then ([ $idxs[] | $pr[.] ] | add)
                       elif (($leaves | index($pk[$i])) != null) then empty
                       else $pr[$i] end ]
                 elif ($pr | type) == "array"
                 then (.nodes[$P] |= del(.ratios))
                 else . end) )
          | {ok:true, tree:.}
        end
    end;

def apply_op($tree; $op; $args):
  if   $op == "link"           then op_link($tree; $args.parent; $args.child)
  elif $op == "unlink_edge"    then op_unlink_edge($tree; $args.parent; $args.child)
  elif $op == "delete_node"    then op_delete_node($tree; $args.node)
  elif $op == "set_mode"       then op_set_mode($tree; $args.node; $args.mode)
  elif $op == "set_ratio"      then op_set_ratio($tree; $args.node; $args.ratios)
  elif $op == "retarget_stack" then op_retarget_stack($tree; $args.stack; $args.child)
  elif $op == "reveal_leaf"    then op_reveal_leaf($tree; $args.leaf)
  elif $op == "stack_leaves"   then op_stack_leaves($tree; $args.leaves)
  else {ok:false, reason:"unknown op: \($op)"} end;
