# Parcel auto-tiling policy — the float predicate (Phase: keystone, §5).
#
# This module is PURE: it decides WHICH observed windows get adopted into the
# layout tree (the managed set) and which are left alone (the float set), WHERE
# a new window splits in (BSP-at-focused), how a closed/minimized window is
# unlinked (remove + collapse), and how computed ratios re-flow (auto_proportion)
# — and composes all of these into `sync`, the single reconciling pass (prune +
# adopt + reproportion) the reactor calls each cycle. It moves nothing; it maps
# observed windows (+ their caps) and a tree to tree mutations the shipped
# reconcile pipeline then projects + applies.
#
# Built per docs/parcel-architecture-endgoal.md §5 (the keystone) and the plan
# docs/history/plans-completed-through-2026-08-11/2026-05-25-parcel-auto-tiling.md. Split OUT as a sibling module
# (not grown into parcel.jq, per the build-DRY/modular directive) — the same way
# reconcile.jq and scope.jq compose parcel's primitives by import rather than
# bloating it. Step 3 landed the predicate (no parcel primitives needed); Step 4
# adds `import "parcel"` for the adopt tree surgery (paths_to / is_leaf). Steps
# 5–6 add frame_ops/geometry as the remove / re-proportion ops land.

import "parcel" as P;
import "geometry" as G;     # assign_display — the per-display mount homing (D)
import "frame_ops" as F;    # as_frame — coerce observed frames before assignment
#
# ─────────────────────────────────────────────────────────────────────────
# THE TILEABILITY PREDICATE  (§5.1)
#
# A window is ADOPTED into the tree iff it is a real, resizable, standard window
# AND no float rule says otherwise:
#
#   tileable = resizable
#            ∧ role    == "AXWindow"
#            ∧ subrole == "AXStandardWindow"
#            ∧ NOT float-allowlisted
#
# The caps (role / subrole / resizable) come from the backend READ side —
# `leyline-reframe query`'s per-window record, enriched in Step 7. Until then the
# fields are absent; the predicate's defaults are CONSERVATIVE — an unknown-caps
# window is NOT tiled (better to leave a window floating than to grab a dialog).
# So: missing resizable ⇒ false; missing/other role|subrole ⇒ not standard.
#
# FLOAT RULES  (the allowlist — lives in parcel/float-rules.json). An ORDERED
# rule list; each rule is
#   { id?, app?: <regex>, title?: <regex>, window_id?: <int>, manage: "on" | "off" }
# A rule MATCHES a window when its app-regex tests the window's `app` AND its
# title-regex tests the window's `title` AND its window_id equals the window's id
# (an omitted facet matches anything). `window_id` is the runtime-only facet manual
# float pins (S5) ride on — never present in the static file, only the in-memory
# merge; see rule_matches. The
# verdict is the manage of the LAST matching rule (default "on" = managed/tiled);
# "off" = float. Last-match-wins is load-bearing: it lets a broad float rule
# (WezTerm `wm.surface.*` → off) be overridden by a narrow re-manage rule
# (the notes-panel title → on) declared after it.
#
# ─────────────────────────────────────────────────────────────────────────
# tileable($w; $rules)                → bool
#     The predicate above. $rules is the float-rules object ({rules:[…]}) or a
#     bare rule array.
# float_verdict($w; $rules)           → "on" | "off"
#     The allowlist verdict alone (last matching rule's manage; "on" default).
# partition($observed; $rules)        → { managed: [<window_id>…], float: [<window_id>…] }
#     Classify every observed window; the float bucket is the un-adopted
#     remainder. Both id-lists sorted (deterministic), mirroring resolve's
#     `unmanaged` shape. The reactor (Step 8) adopts the managed ids and leaves
#     the float ids untouched (reconcile already passes unmanaged windows through).
#
# ─────────────────────────────────────────────────────────────────────────
# BSP ADOPT  (§5.AdoptionRule, Step 4)
#
# split_orientation($frame)           → "row" | "col"
#     The "longer dimension" policy: a WIDE (or square) slot splits into a row
#     (side-by-side), a TALL slot into a col (stacked). null → "row".
# adopt($tree; $window_leaf; $focused_leaf; $focused_frame) → $tree'
#     Link $window_leaf into the tree by splitting the focused leaf (BSP-at-
#     focused). The focused leaf is replaced, in its parent's slot, by a fresh
#     row|col internal node with children [focused_leaf, window_leaf] — the new
#     window opens right-of / below the focused one, in its former slot. The
#     orientation follows split_orientation($focused_frame). NEVER a stack (auto
#     is row/col only — decision 9). The new internal node is `computed` (no
#     ratios / ratio_source) so auto_proportion (Step 6) equalizes it.
#       empty tree           → window_leaf seeds the root.
#       focused not a leaf   → fall back to the lex-first leaf (else under root).
#       focused == root leaf → a new internal node becomes the root.
#
# ─────────────────────────────────────────────────────────────────────────
# REMOVE + COLLAPSE  (§5, Step 5)
#
# remove($tree; $leaf)                → $tree'
#     Unlink $leaf from its parent (dropping the ALIGNED ratio entry, so a pinned
#     split's surviving siblings keep their proportions and a computed one
#     re-equalizes), delete it, then collapse any now-only-child internal node —
#     replace it with its surviving child, which inherits the parent's slot — to
#     a FIXPOINT (nested/cascading collapse included). Removing the last leaf (the
#     root itself) → the empty tree {root_id:null, nodes:{}}. A leaf not present,
#     or an orphan unreachable from the root → a safe no-op / bare delete.
#
# ─────────────────────────────────────────────────────────────────────────
# AUTO-PROPORTION  (§5.3 ratio stickiness, Step 6)
#
# auto_proportion($tree)              → $tree'
#     Normalize COMPUTED row/col nodes back to an equal split — by stripping
#     their explicit `.ratios` so child_slots derives equal proportions (the same
#     no-ratios shape adopt produces), keeping the representation consistent. A
#     `ratio_source:"pinned"` node is SKIPPED — its hand-set ratios are read,
#     never re-snapped (the split analogue of a pinned frame, I4). Idempotent;
#     touches only row/col (the modes that consult ratios). The reactor may run
#     this after structural churn to re-equalize the auto-managed splits.
#     (tiling.jq's clamp/min-size math is a PROJECTION/frame concern, not ratio
#     normalization — its reuse, if any, lands when tiling.jq is absorbed, Step 9.)
#
# ─────────────────────────────────────────────────────────────────────────
# SYNC  (the managed-set keystone, §5)
#
# sync($tree; $observed; $rules; $focused_leaf; $topology)  → $tree'
#     The ONE reconciling pass the reactor calls each cycle: prune leaves whose
#     window left the managed-live set (closed/quit / minimized / newly-float),
#     adopt tileable newcomers (BSP at the anchor, chaining), then auto_proportion.
#     Composes partition + remove + adopt + auto_proportion + P::project; the def
#     (below) carries the per-split re-projection + ordering rationale.
# ─────────────────────────────────────────────────────────────────────────

# Float-rules input is permissive: the data file is {_schema, rules:[…]}, but a
# bare array is accepted too (handy in fixtures). Type-guarded so indexing an
# array with .rules never errors.
def _rules($rules):
  if   ($rules | type) == "object" then ($rules.rules // [])
  elif ($rules | type) == "array"  then $rules
  else [] end;

# A rule matches when every facet it declares tests true against the window.
# An omitted app/title/window_id facet is vacuously true (a rule with none is a
# global default-manage rule). Window facets default to "" so a missing app/title
# can never crash test() — it simply fails an anchored pattern. The `window_id`
# facet (exact id match) is the RUNTIME-ONLY facet manual float pins ride on (S5):
# the verb appends `{window_id:<wid>, manage:"off"}` rules last, so a per-window
# pin overrides any class rule via last-match-wins. It never appears in the static
# float-rules.json file — only in the in-memory merge.
def rule_matches($w; $r):
  (if ($r | has("app"))       then (($w.app   // "") | test($r.app))   else true end)
  and
  (if ($r | has("title"))     then (($w.title // "") | test($r.title)) else true end)
  and
  (if ($r | has("window_id")) then (($w.window_id) == $r.window_id)    else true end);

# Last matching rule wins; "on" (managed) is the default when nothing matches.
# A matching rule with no explicit manage defaults to "off" (it is a float rule).
def float_verdict($w; $rules):
  reduce (_rules($rules)[]) as $r ("on";
    if rule_matches($w; $r) then ($r.manage // "off") else . end);

def is_standard($w):
  (($w.role // null) == "AXWindow") and (($w.subrole // null) == "AXStandardWindow");

def is_resizable($w):
  ($w.resizable // false) == true;

def tileable($w; $rules):
  is_resizable($w) and is_standard($w) and (float_verdict($w; $rules) != "off");

def partition($observed; $rules):
  reduce (($observed // [])[]) as $w ({managed: [], float: []};
    if tileable($w; $rules)
    then .managed += [$w.window_id]
    else .float   += [$w.window_id] end)
  | .managed |= sort
  | .float   |= sort;

# ── BSP adopt ───────────────────────────────────────────────────────────────
# Longer-dimension policy: wide/square slot → row (side-by-side); tall → col.
# _split_axis returns BOTH the axis AND the legibility reason (the "why" an adopt
# fact records) from ONE branch set, so axis and its reason can never disagree.
# The axis_reason vocabulary is closed + mechanical — it enumerates these branches
# ("aspect:w>=h" / "aspect:w<h" / "aspect:null"); Stage 5's balance-first decide
# adds reasons to this same field. split_orientation is the axis-only view (the
# value adopt + the fixture surface consume), defined in terms of it.
def _split_axis($frame):
  if $frame == null then { axis: "row", reason: "aspect:null" }
  elif ($frame.w // 0) >= ($frame.h // 0) then { axis: "row", reason: "aspect:w>=h" }
  else { axis: "col", reason: "aspect:w<h" } end;
def split_orientation($frame): _split_axis($frame).axis;

# Id for the internal node a split introduces: "i:<leaf-id>", deterministic from
# the new window's leaf id. COLLISION-SAFE — if that id already names a node in
# the tree, append ".1", ".2", … until free, so adopt can never silently
# overwrite an existing node (validate is blind to such an overwrite — it would
# clobber a bound leaf and double a parent edge while reporting ok). The base
# case is collision-free in practice (a window is adopted once); the disambiguator
# is the belt-and-suspenders that keeps adopt total against any leaf-id scheme.
def _split_node_id($window_leaf; $nodes):
  ("i:" + ($window_leaf.id | tostring)) as $base
  | if (($nodes[$base]) // null) == null then $base
    else ( first( range(1; 1000000)
                  | ($base + "." + tostring)
                  | select( (($nodes[.]) // null) == null) )
           // ($base + ".x") )
    end;

# ── split a leaf in two (the shared BSP surgery) ─────────────────────────────
# Insert $new_leaf_id beside $target under a fresh internal node ($orientation mode),
# with $new_leaf_id on the $side ("before"|"after") of $target. The single primitive
# behind BOTH auto-adopt (orientation from aspect ratio, side "after") and manual warp
# (op_move_leaf — orientation/side from the move direction); a future placeholder op
# reuses it too. PRE (caller guards): $new_leaf_id's node already exists in $tree.nodes
# (an orphan — no parent edge) and $target is a REACHABLE leaf. The fresh node's id is
# keyed off $new_leaf_id (collision-safe via _split_node_id), matching adopt's historical
# id so factoring this out of adopt is behaviour-preserving.
def split_leaf($tree; $target; $new_leaf_id; $orientation; $side):
  ($tree.nodes) as $nodes
  | ($tree.root_id) as $root
  | _split_node_id($nodes[$new_leaf_id]; $nodes) as $N
  | ( if $side == "before" then [$new_leaf_id, $target] else [$target, $new_leaf_id] end ) as $kids
  | if $target == $root
    then  # target IS the root → the fresh internal node becomes the root.
      { root_id: $N, nodes: ($nodes + { ($N): {id: $N, mode: $orientation, children: $kids} }) }
    else  # splice the fresh node into $target's single parent slot (lex-first path's [-2]).
      ( P::paths_to($nodes; $root; $target) | sort_by(join("/")) | .[0] ) as $path
      | ($path[-2]) as $parent
      | $tree
      | .nodes[$N] = {id: $N, mode: $orientation, children: $kids}
      | .nodes[$parent].children =
          ((.nodes[$parent].children // []) | map(if . == $target then $N else . end))
    end;

def adopt($tree; $window_leaf; $focused_leaf; $focused_frame):
  ($window_leaf.id) as $wid
  | ($tree.nodes // {}) as $nodes
  | ($tree.root_id) as $root
  | split_orientation($focused_frame) as $mode
  | if ($root == null) or (($nodes[$root] // null) == null)
    then { root_id: $wid, nodes: { ($wid): $window_leaf } }          # seed root
    else
      # the set of node ids REACHABLE from the root (parcel's DFS closure). A
      # split target must be reachable — an orphan leaf (present but detached;
      # only a malformed recipe/GIGO op makes one) has no parent path to split
      # under, and would otherwise crash the parent lookup below.
      (P::closure($nodes; [$root])) as $reach
      # split target: the focused leaf if it is a REACHABLE leaf, else the
      # lex-first reachable leaf.
      | ( if ($focused_leaf != null)
             and (($nodes[$focused_leaf] // null) != null)
             and (P::is_leaf($nodes[$focused_leaf]))
             and (($reach[$focused_leaf]) // false)
          then $focused_leaf
          else ( [ $nodes | to_entries[]
                   | select(P::is_leaf(.value) and (($reach[.key]) // false)) | .key ]
                 | sort | .[0] // null )
          end ) as $F
      | if $F == null
        then  # degenerate (no leaf anywhere): hang the new leaf off the root.
          $tree
          | .nodes[$wid] = $window_leaf
          | .nodes[$root].children = ((.nodes[$root].children // []) + [$wid])
        else  # add the new window leaf, then split $F via the shared primitive
              # (orientation from aspect ratio, side "after") — adopt's historical
              # behaviour, now routed through split_leaf so warp/placeholder reuse it.
          ($tree | .nodes[$wid] = $window_leaf)
          | split_leaf(.; $F; $wid; $mode; "after")
        end
    end;

# ── remove + collapse ───────────────────────────────────────────────────────
# Collapse every now-redundant internal node — one with exactly ONE child — by
# replacing it, everywhere it is referenced (including as the root), with that
# child, then deleting it. Iterates to a FIXPOINT so a cascade (a collapse that
# leaves its grandparent single-childed) fully settles. A leaf (0 children) is
# never collapsed; only a 1-child internal node is redundant.
def _collapse_singletons($tree):
  { t: $tree, go: true }
  | until(.go | not;
      .t as $t
      | ( [ $t.nodes | to_entries[]
            | select(((.value.children // []) | length) == 1)
            # never collapse the per-display scaffold (D): the region root (the fixed
            # container) or a pinned mount — a 1-window display must KEEP its mount, whose
            # display-pinned frame is load-bearing. Plain row/col/stack BSP nodes (every
            # non-D tree is only these) still collapse exactly as before.
            | select(((.value.mode // "region") != "region")
                     and ((.value.frame_source // "computed") != "pinned"))
            | .key ] | .[0] ) as $single
      | if $single == null then {t: $t, go: false}
        else
          ($t.nodes[$single].children[0]) as $child
          | { t: ( $t
                   | (if .root_id == $single then .root_id = $child else . end)
                   | .nodes = ( .nodes
                       | del(.[$single])
                       # rewrite the edge only on nodes that HAVE children (internal
                       # nodes) — never stamp a phantom children:[] onto a leaf.
                       | with_entries(
                           if (.value | has("children"))
                           then .value.children =
                                  (.value.children | map(if . == $single then $child else . end))
                           else . end) ) ),
              go: true }
        end )
  | .t;

def remove($tree; $leaf):
  ($tree.nodes // {}) as $nodes
  | ($tree.root_id) as $root
  | if ($nodes[$leaf] // null) == null then $tree              # not present → no-op
    elif $leaf == $root then {root_id: null, nodes: {}}         # last leaf → empty tree
    else
      ( P::paths_to($nodes; $root; $leaf) | sort_by(join("/")) | .[0] ) as $path
      | if ($path == null) or (($path | length) < 2)
        then ($tree | del(.nodes[$leaf]))                       # orphan → bare delete
        else
          ($path[-2]) as $parent
          | ($nodes[$parent].children | index($leaf)) as $i
          | ( $tree
              # drop the leaf's child slot AND its aligned ratio entry, so pinned
              # survivors keep their proportions / computed ones stay equal.
              | .nodes[$parent].children = ((.nodes[$parent].children // []) | del(.[$i]))
              | (if (.nodes[$parent] | has("ratios"))
                 then .nodes[$parent].ratios = (.nodes[$parent].ratios | del(.[$i]))
                 else . end)
              # if the parent is a stack presenting the removed leaf, drop the now
              # dangling `top` so child_slots falls back to the first survivor
              # (manual stacks only — auto never creates one).
              | (if (.nodes[$parent].top // null) == $leaf
                 then .nodes[$parent] |= del(.top) else . end)
              | del(.nodes[$leaf]) )
          | _collapse_singletons(.)
        end
    end;

# ── auto-proportion (ratio stickiness) ──────────────────────────────────────
# Re-equalize the auto-managed splits: drop explicit ratios on COMPUTED row/col
# nodes (→ child_slots' default-equal, the no-ratios shape adopt produces), while
# leaving a pinned node's hand-set ratios untouched (read, never re-snapped — I4).
def auto_proportion($tree):
  $tree
  | .nodes = ( .nodes | with_entries(
      if ( ((.value.mode // "region") | (. == "row" or . == "col"))
           and ((.value.ratio_source // "computed") != "pinned")
           and (.value | has("ratios")) )
      then .value |= del(.ratios)
      else . end ) );

# ── reproportion facts (legibility) ──────────────────────────────────────────
# The causal record of which COMPUTED row/col nodes auto_proportion re-equalizes
# this pass — exactly the nodes its predicate (above) strips. Computed from the
# PRE-strip $tree so the fact names a REAL strip, not every computed node (the
# common no-stale-ratios case → empty array, keeping the stream quiet). Tree-global
# (window_id null). Mirrors auto_proportion's predicate so the two cannot diverge.
def _reproportion_facts($tree):
  [ ($tree.nodes // {}) | to_entries[]
    | select( ((.value.mode // "region") | (. == "row" or . == "col"))
              and ((.value.ratio_source // "computed") != "pinned")
              and (.value | has("ratios")) )
    | { kind: "reproportion", window_id: null, node: .key, axis: .value.mode } ];

# ── reequalize policy (the first lifted CONFIG knob) ──────────────────────────
# auto_proportion + its facts, gated by the strategy's reequalize_policy. This is
# the one LIVE policy knob Stage-2 Step-6 lifts into the per-strategy config block —
# today's sync ran auto_proportion on EVERY settle; now WHEN it runs is configurable:
#   "always"    re-equalize every settle (the DEFAULT — byte-identical to legacy).
#   "on_remove" re-equalize only when this pass pruned a window ($removed > 0) — the
#               Stage-4 sticky target. $removed counts EVERY leaf leaving the managed-live
#               set this pass (close/quit, minimize, OR float-out — the prune-fact causes),
#               so any of those reabsorbs space; a mere adopt/move leaves hand-shaped
#               proportions alone.
#   "off"       never auto-re-equalize (full sticky; ratios survive every settle).
# An unknown/absent policy falls back to "always", so a strategy that omits the knob
# (or omits config entirely) is behavior-preserving.
def _reequalize($tree; $policy; $removed):
  if ($policy == "off") or (($policy == "on_remove") and ($removed == 0))
  then { tree: $tree, facts: [] }
  else { tree: auto_proportion($tree), facts: _reproportion_facts($tree) }
  end;

# ── per-display mount scaffold (D) ────────────────────────────────────────────
# The per-display tiling shape is one tree: a fixed "root" region node whose
# children are pinned mounts ("d:<display_id>"), one per OCCUPIED display, each
# tiling that display's usable rect (child_slots honors frame_source:"pinned" +
# display_id, so no leaf ever straddles the inter-display gap). ONE root_id is
# kept — scope/nav traverse mounts transparently (the mount is a normal node).
def _mount_id($d): "d:" + ($d | tostring);

# Ensure $tree is in mount-shape with a mount for every display id in $want
# (occupancy-driven; $want = the display ids of the live windows). A tree not
# already rooted at "root" is rebuilt fresh — its windows then re-adopt via sync's
# adopt pass (a one-time re-tile on the migration from a bare BSP / on multi-display
# splits). Idempotent on a mount tree: keeps existing mounts + their subtrees,
# appends only missing ones (mount-id-sorted children, deterministic).
def ensure_scaffold($tree; $want):
  ( if ($tree.root_id == "root") and ((($tree.nodes // {}).root.children // null) != null)
    then $tree
    else { root_id: "root", nodes: { "root": { id: "root", mode: "region", children: [] } } }
    end )
  | reduce ($want | unique)[] as $d (.;
      _mount_id($d) as $m
      | if ((.nodes[$m]) // null) != null then .
        else .nodes[$m] = { id: $m, mode: "row", frame_source: "pinned",
                            display_id: $d, children: [] }
             | .nodes.root.children = ((.nodes.root.children // []) + [$m]) end )
  | .nodes.root.children = ((.nodes.root.children // []) | unique);

# Adopt each newcomer into ITS home display's mount, chaining the BSP anchor PER
# DISPLAY: the first newcomer on a display anchors at the focused leaf (iff it lives
# in that mount) else the mount's lex-first leaf, else seeds the empty mount; each
# subsequent newcomer on that display splits the prior one. $home = {"<wid>": <disp>}.
# Reuses the topology-free `adopt` (fed the anchor's projected frame for
# split_orientation) — confined to the mount because the anchor is always inside it.
def adopt_newcomers($tree; $newcomers; $home; $focused_leaf; $topology):
  ( reduce $newcomers[] as $w ( { tree: $tree, anchors: {}, facts: [] };
      .tree as $t | .anchors as $anch | .facts as $fx
      | ("w:" + ($w | tostring)) as $wid
      | { id: $wid, window_id: $w } as $leaf
      | ($home[($w | tostring)]) as $disp
      | _mount_id($disp) as $m
      | (((($t.nodes[$m]).children) // []) | length) as $mkids
      | if $mkids == 0
        then { tree:    ( $t | .nodes[$wid] = $leaf | .nodes[$m].children = [$wid] ),
               anchors: ( $anch | .[$m] = $wid ),
               facts:   ( $fx + [ { kind: "seed", window_id: $w, leaf: $wid,
                                    mount: $m, display_id: $disp } ] ) }
        else
          (P::closure($t.nodes; [$m])) as $sub
          | ( if   (($anch[$m]) != null) and ((($sub[$anch[$m]]) // false))
              then $anch[$m]
              elif ($focused_leaf != null) and ((($sub[$focused_leaf]) // false))
                   and (P::is_leaf($t.nodes[$focused_leaf]))
              then $focused_leaf
              else ( [ $sub | keys[] | select(P::is_leaf($t.nodes[.])) ] | sort | .[0] )
              end ) as $foc
          | (P::project($t; $topology).leaves[$foc].desired_frame // null) as $ff
          | _split_axis($ff) as $sa
          | { tree:    adopt($t; $leaf; $foc; $ff),
              anchors: ( $anch | .[$m] = $wid ),
              facts:   ( $fx + [ { kind: "adopt", window_id: $w, leaf: $wid,
                                   anchor_leaf: $foc, mount: $m,
                                   axis: $sa.axis, axis_reason: $sa.reason, side: "after" } ] ) }
        end )
  ) | { tree: .tree, facts: .facts };

# ── homing policy (the `homing` config knob) ──────────────────────────────────
# DEFAULT "focus" = GEOMETRIC homing: a newcomer homes to the display its observed
# frame overlaps most (G::assign_display), and ensure_scaffold only mounts OCCUPIED
# displays — so windows that all land on the focused display PILE there and an empty
# display stays empty (the multi-display homing contract, pinned by
# sync-homing-geometric-not-empty-display). This is byte-identical to before the knob.
#
# "empty_first" = PREFER-EMPTY-DISPLAY: when an empty display exists, a NEWCOMER is
# re-homed onto it instead of its geometric display — the operator's "fill BOTH
# screens" policy (memory: wm-tiling-target-model). This is a PURE rewrite of the
# window→display $home map (the ONE site both ensure_scaffold's mount set and
# adopt_newcomers' per-window placement derive from — DRY: change the map, not two
# call sites). EXISTING bound windows keep their geometric home (only the not-yet-
# bound newcomers are reassigned, so a settled layout never reshuffles); newcomers
# fill empty displays id-sorted (newcomer ↔ empty display), and once the empty
# displays run out the remaining newcomers keep their geometric home. ZERO frame /
# clamp / split math here — it only swaps a display id in $home.
#
# `_rehome_to_empty($home; $newcomers; $prior_bound; $disps)`:
#   $home        = {"<wid>": <disp>} geometric homing (the input map)
#   $newcomers   = the managed-live windows NOT bound in the prior tree, id-sorted
#   $prior_bound = the window ids already bound in the prior tree (existing windows)
#   $disps       = the normalized topology displays
def _rehome_to_empty($home; $newcomers; $prior_bound; $disps):
  # A display is OCCUPIED if some EXISTING (already-bound) window homes to it; the
  # empties are the rest, id-sorted (deterministic newcomer↔empty pairing).
  ( [ $disps[] | .id
      | . as $d
      | select( any( ($prior_bound // [])[];
                     ($home[(. | tostring)]) == $d ) ) ] ) as $occupied
  | ( [ $disps[] | .id | . as $id | select( ($occupied | index($id)) == null ) ] | sort ) as $empties
  # Pair each newcomer with the next free empty display (id-sorted both sides);
  # newcomers beyond the empties keep their geometric home (no override emitted).
  | reduce ( $newcomers | to_entries[] ) as $pair
      ($home;
        $pair.value as $w | $pair.key as $i
        | if $i < ($empties | length)
          then .[($w | tostring)] = $empties[$i]
          else . end );

# ── re-home + empty-mount cleanup (D3) ────────────────────────────────────────
# Re-home a window the user dragged to ANOTHER display: a bound leaf whose window's
# assigned display (from its observed frame) ≠ the display of the mount it currently
# sits under is REMOVED here, so the adopt pass re-adopts it into its home mount.
# Without this it would stay pinned to its old display and reconcile would snap it
# back, fighting the user. (No hysteresis yet — a window parked exactly on the seam
# could flip-flop between syncs; add stickiness if observed live. $home={"<wid>":disp}.)
def rehome_displaced($tree; $home):
  ($tree.root_id) as $root
  | ( [ ($tree.nodes // {}) | to_entries[]
        | select(P::is_leaf(.value) and ((.value.window_id // null) != null))
        | { leaf: .key, w: .value.window_id } ] ) as $bound
  | ( [ $bound[]
        # the mount a leaf sits under = the root's child on its (lex-first) path
        | (P::paths_to($tree.nodes; $root; .leaf) | sort_by(join("/")) | .[0]) as $path
        | { leaf: .leaf, w: .w,
            cur:  (($tree.nodes[$path[1]]).display_id // null),
            want: ($home[(.w | tostring)]) }
        | select((.cur != null) and (.cur != .want)) ] ) as $displaced
  # The internal removes here are RE-HOMES, not departures: they emit `rehome`
  # facts (paired with the re-adopt in the same pass), never `prune` facts — that
  # boundary keeps facts-derived adopted/pruned counts honest (Step 3).
  | { tree:  ( reduce $displaced[] as $d ($tree; remove(.; $d.leaf)) ),
      facts: ( [ $displaced[] | { kind: "rehome", window_id: .w, leaf: .leaf,
                                  from_display: .cur, to_display: .want } ] ) };

# Drop any pinned mount left childless (its display emptied by prune/re-home) and
# unlink it from the root. ensure_scaffold only ADDS mounts (for occupied displays);
# this removes the ones that emptied out, so a closed-out display leaves no dangling
# mount. Run AFTER adopt, so a display re-occupied this cycle keeps its (now-filled) mount.
def drop_empty_mounts($tree):
  ( [ ($tree.nodes // {}) | to_entries[]
      | select(((.value.frame_source // "") == "pinned")
               and (((.value.children // []) | length) == 0))
      | .key ] ) as $empties
  | reduce $empties[] as $m ($tree;
      .nodes.root.children = (((.nodes // {}).root.children // []) | map(select(. != $m)))
      | del(.nodes[$m]) );

# ── sync (the managed-set keystone) ──────────────────────────────────────────
# sync($tree; $observed; $rules; $focused_leaf; $topology) → { tree, facts[] }
#
#   THE FACT STREAM (legibility, 2026-05-29 — the strategy contract's `.facts`):
#   the CAUSAL record of every decision this pass made, captured at the decision
#   site (never reconstructed from a tree diff). One envelope `{kind, window_id, …}`
#   — `kind` is the only field consumers switch on; an unknown kind renders generically,
#   so later stages add kinds (stack/lock/drag/solidify) without touching the renderer.
#   This is the SCHEMA's single home; the emitter (watch.sh) + `ley parcel explain`
#   reference it. Stage-1 kinds, appended in decision order:
#     prune        {window_id, leaf, cause:"departed"|"minimized"|"floated", absorber?}
#                  absorber (wid|null, NATIVE S-P3 prunes only): the survivor whose
#                  post-reclaim cell took the freed space — consumed by the reactor's
#                  close-refocus `space` policy. Cold prunes omit it (read as null).
#     rehome       {window_id, leaf, from_display, to_display}
#     seed         {window_id, leaf, mount, display_id}          # first window into an empty mount
#     adopt        {window_id, leaf, anchor_leaf, mount, axis, axis_reason, side}
#     reproportion {window_id:null, node, axis}                  # an auto_proportion re-equalize
#   STRATEGY-emitted kinds (arrangement.jq, NOT this engine — appended after the author):
#     float_newcomer {window_id, leaf, policy}     # newcomer staged to float (newcomer_policy=float-all, fork 7)
#     classifier_pending {}                        # one-shot: newcomer_policy=float-transient coerced to tile-all
#   axis_reason ∈ {"aspect:w>=h","aspect:w<h","aspect:null"} (split_orientation's branches).
#
#   The ONE pure pass that reconciles the layout tree to the live window world:
#   PRUNE departed/minimized/newly-float leaves, ADOPT newcomers (BSP, chaining),
#   then auto_proportion. Replaces the five scattered impure entrypoints
#   (adopt / adopt_all / remove_window / prune_dead + the reactor's per-event
#   authoring) with a single fixture-testable function — endgoal §5's "adopt as a
#   pure pre-pass that produces a tree, moves nothing", generalized to the whole
#   managed set. The reactor's bootstrap and per-settle paths just call it.
#
#   managed-live = the tileable, NON-minimized observed window ids (partition of
#   the non-minimized observed set). A leaf whose window left that set is pruned —
#   covering closed/quit (gone from observed), minimized (the user took it out),
#   AND newly-float (a managed window a float rule now matches; prune_dead missed
#   this). Newcomers = managed-live not already bound to a leaf, id-sorted.
#
#   $topology is consulted (via P::project) ONLY to read the current frame of each
#   adopt's split target, for split_orientation — the same projection wm_parcel_adopt
#   does today. It is threaded so a MULTI-newcomer bootstrap re-projects the growing
#   tree between chained adopts (each split sees its target's real frame → correct
#   alternating BSP). The `adopt` primitive itself stays topology-free; sync feeds it
#   the frame. The first adopt into an empty tree (anchor "" / absent) seeds the root
#   and needs no projection.
#
#   $config is the strategy's policy block; today it carries one live knob,
#   reequalize_policy (see _reequalize). BYTE-EQUALITY: the legacy sync-*.json fixtures
#   carry NO `config` key, so the harness (parcel/tests.sh) reaches this via the 6-arg
#   form with `($fx.config // {})` = {}, and an empty/missing config ⇒ policy "always" ⇒
#   the legacy auto_proportion-every-settle path, byte-identical to before the knob existed.
#   $config is coerced to {} unless it is an object, so a malformed manifest config (an
#   array/string/number) can never crash the settle — it falls to the "always" default.
def sync($tree; $observed; $rules; $focused_leaf; $topology; $config):
  ( ($config | if type == "object" then . else {} end) ) as $cfg
  | ( $cfg.reequalize_policy // "always" ) as $reqpol
  # The homing policy knob (config-gated; default "focus" = today's geometric homing,
  # byte-identical — see _rehome_to_empty). "empty_first" prefers an empty display for
  # each newcomer. Coerced via $cfg so a malformed config can never crash the settle.
  | ( $cfg.homing // "focus" ) as $homing
  # (The newcomer_policy read here was forward-documentation only — never consumed —
  # removed when the policy moved upstream to the reactor. A::sync is policy-free: it
  # adopts/prunes per the tree + honors pins via $rules. newcomer-policy-unification.)
  | ( $observed // [] ) as $obs
  # Z-STACK MEMBER EXEMPTION (P-VERBS P6, movemode-stack A1): a prior stack's
  # NON-TOP member reads minimized at the port BECAUSE the layout buried it
  # (the executor's cover/minimize realizes presented:false — circular evidence,
  # not user intent, unlike :545's "the user took it out"). Exempt prior stack
  # members from the minimized gate so a stack SURVIVES settles; a window
  # un-stacked by any op loses the node and the exemption with it. Stack-free
  # trees: $buried == [] → $live byte-identical (the golden/roundtrip locks).
  | ( [ ($tree.nodes // {}) | to_entries[]
        | select((.value.mode // "") == "stack")
        | .value.top as $top
        | (.value.children // [])[] | select(. != $top) ] ) as $buried_ids
  | ( [ $buried_ids[] | ($tree.nodes[.].window_id // empty) ] ) as $buried_wids
  | ( [ $obs[] | .window_id ] ) as $obs_wids
  # M4 prune-split (P-MIN Step 9): managed-live filters on GENUINE AXMinimized
  # (`ax_minimized`), not the `minimized` OR — a window the layout merely COVERED
  # (minimized==true only because covered) stays managed-live, so sync does not prune
  # it as a user-minimize (this GENERALIZES the buried-stack-member exemption below to
  # every covered window). `// .minimized` keeps it byte-identical until leyline-reframe
  # emits the new bit (an old observed record has no `ax_minimized` → falls back to the
  # OR = today's behavior). NB: an explicit `has` check, not `//` — jq's `//` treats a
  # genuine `false` as empty and would collapse it back to the OR.
  | ( ( partition([ $obs[] | select((if has("ax_minimized") then .ax_minimized else .minimized end) != true) ]; $rules).managed
        + [ $buried_wids[] | select(. as $w | ($obs_wids | index($w)) != null) ] )
      | unique ) as $live
  # PRUNE — every leaf whose window is no longer in the managed-live set (closed/quit/
  # minimized/newly-float). $dead carries {window_id, leaf} so the tree reduce (below,
  # iterating window_id exactly as before) AND the prune facts both read it.
  | ( [ ($tree.nodes // {}) | to_entries[]
        | .value.window_id as $wid
        | select(($wid != null) and (($live | index($wid)) == null))
        | { window_id: $wid, leaf: .key } ] ) as $dead
  | ( reduce $dead[] as $d ($tree;
        ( [ (.nodes // {}) | to_entries[] | select(.value.window_id == $d.window_id) | .key ] | .[0] ) as $leaf
        | if $leaf == null then . else remove(.; $leaf) end ) ) as $pruned
  # PRUNE facts — cause classified from $obs: gone entirely → "departed"; present but
  # minimized → "minimized"; present, non-minimized, no longer tileable → "floated"
  # (the three causes $live's single predicate collapses; unrecoverable from a tree diff).
  | ( [ $dead[] | .window_id as $w | .leaf as $lf
        | { kind: "prune", window_id: $w, leaf: $lf,
            cause: ( ( [ $obs[] | select(.window_id == $w) ] | .[0] ) as $o
                     | if   $o == null               then "departed"
                       elif (if ($o | has("ax_minimized")) then $o.ax_minimized else ($o.minimized // false) end) then "minimized"
                       else                                "floated" end ) } ] ) as $prune_facts
  # Nothing managed-live → the prune-all result stands (empty stays the empty tree).
  # Build the per-display scaffold only when there is something to place (D).
  | if ($live | length) == 0
    then ( _reequalize($pruned; $reqpol; ($dead | length)) ) as $req
         | { tree:  $req.tree,
             facts: ( $prune_facts + $req.facts ) }
    else
      # window_id → home display, from the observed frame + the topology displays.
      ( P::norm_topology($topology).displays ) as $disps
      | ( reduce $obs[] as $w ({};
            if ($live | index($w.window_id)) != null
            then .[($w.window_id | tostring)] =
                   G::assign_display(F::as_frame($w.frame // [0,0,0,0]); $disps)
            else . end ) ) as $home_geo
      # HOMING knob: default "focus" passes the geometric map through UNCHANGED
      # (byte-identical). "empty_first" re-homes each newcomer onto an empty display
      # (windows already bound in $pruned are existing → keep their geometric home).
      | ( [ ($pruned.nodes // {})[] | .window_id // empty ] ) as $prior_bound
      | ( ($live - $prior_bound) | sort ) as $newcomers_home
      | ( if $homing == "empty_first"
          then _rehome_to_empty($home_geo; $newcomers_home; $prior_bound; $disps)
          else $home_geo end ) as $home
      # ensure root + a pinned mount per OCCUPIED display (rebuilds a bare-BSP input).
      | ensure_scaffold($pruned; [ $home[] ]) as $scaffold
      # RE-HOME a window dragged to another display: its leaf leaves the old mount so the
      # adopt pass below re-adopts it into its home mount (D3). Returns {tree, facts}.
      | rehome_displaced($scaffold; $home) as $rh
      | ($rh.tree) as $rehomed
      # ADOPT newcomers (managed-live not yet bound, incl. the just-displaced), id-sorted,
      # into their home mount. Returns {tree, facts}.
      | ( [ ($rehomed.nodes // {})[] | .window_id // empty ] ) as $present
      | ( ($live - $present) | sort ) as $newcomers
      | adopt_newcomers($rehomed; $newcomers; $home; $focused_leaf; $topology) as $ad
      | ($ad.tree | drop_empty_mounts(.)) as $dropped   # emptied display drops its mount (D3)
      | ( _reequalize($dropped; $reqpol; ($dead | length)) ) as $req
      | { tree:  $req.tree,
          # fact order = decision order: prune → rehome → seed/adopt → reproportion.
          facts: ( $prune_facts + $rh.facts + $ad.facts + $req.facts ) }
    end;
