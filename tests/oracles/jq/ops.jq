# Parcel manual-placement ops — the composing op module.
#
# PURE: zero backend calls, no window moves. Houses the manual placement ops the
# operator drives by keybind (S3: swap + move/warp), kept OUT of parcel.jq per
# the build-DRY-modular directive (cf. reconcile.jq / autotile.jq composing on top
# of parcel.jq). It imports the structural primitives from parcel.jq and re-exposes
# a single `apply_op` that handles the new verbs and DELEGATES everything else to
# P::apply_op — so the bash dispatch (lib/parcel/store.sh) and the `ops` fixture
# surface (parcel/tests.sh) point HERE and route both old and new verbs through one
# door.
#
# apply_op($tree; $op; $args) → { ok, tree?, reason? }
#   swap_leaf → op_swap_leaf; move_leaf → op_move_leaf; all others → P::apply_op
#   (link | unlink_edge | delete_node | set_mode | set_ratio | retarget_stack | reveal_leaf).

import "parcel" as P;
import "autotile" as A;

# ── op_swap_leaf — trade two leaves' POSITIONS ───────────────────────────────
# Swap leaves $a and $b in place: rewrite every node's `children` ($a↔$b) AND
# every stack `top` ($a↔$b), so a slot that was presented stays presented after
# the trade. `ratios` are positional and intentionally LEFT ALONE — each leaf
# inherits the geometry of the slot it lands in, which is exactly "the two windows
# trade places". Guards: $a≠$b, both nodes present, both are leaves (the root is
# internal ⇒ never swappable). Cannot create a cycle, multi-parent, or window
# collision — every I-invariant is preserved by construction (wm_parcel_op still
# re-validates via tree_set as defence in depth).
def op_swap_leaf($tree; $a; $b):
  ($tree.nodes) as $nodes
  | if   $a == $b                          then {ok:false, reason:"swap_leaf: a == b (\($a))"}
    elif (($nodes[$a] // null) == null)    then {ok:false, reason:"no such node: \($a)"}
    elif (($nodes[$b] // null) == null)    then {ok:false, reason:"no such node: \($b)"}
    elif (P::is_leaf($nodes[$a]) | not)    then {ok:false, reason:"not a leaf: \($a)"}
    elif (P::is_leaf($nodes[$b]) | not)    then {ok:false, reason:"not a leaf: \($b)"}
    else
      {ok:true,
       tree: ($tree
              | .nodes |= with_entries(
                  ( if (.value | has("children"))
                    then .value.children |=
                           map(if . == $a then $b elif . == $b then $a else . end)
                    else . end )
                  | ( if   .value.top == $a then .value.top = $b
                      elif .value.top == $b then .value.top = $a
                      else . end )))}
    end;

# ── op_move_leaf — WARP: re-parent the focused leaf into the target's slot ───
# Warp semantics: detach the focused leaf (collapsing its vacated parent),
# then split the directional TARGET leaf, inserting focused on $side ("before" |
# "after") under a fresh $orientation-mode node. Composes the autotile BSP
# primitives — A::remove (detach + collapse to a fixpoint) then A::split_leaf (the
# shared split). The impure caller (lib/parcel/move.sh) resolves $target via the
# IDENTICAL spatial_nav ranking as nav (direct → wrap) and derives $orientation /
# $side from the direction, so this op carries no direction vocabulary and stays
# pure-structural. Guards: $focused==$target → no-op (ok:true — a wrap can resolve
# onto self); both present; both leaves (the root is internal, and two distinct
# leaves can never be ancestor/descendant → a cycle is impossible, no I1 check needed).
def op_move_leaf($tree; $focused; $target; $orientation; $side):
  ($tree.nodes) as $nodes
  | if   $focused == $target                  then {ok:true,  tree:$tree}
    elif (($nodes[$focused] // null) == null)  then {ok:false, reason:"no such node: \($focused)"}
    elif (($nodes[$target]  // null) == null)  then {ok:false, reason:"no such node: \($target)"}
    elif (P::is_leaf($nodes[$focused]) | not)  then {ok:false, reason:"not a leaf: \($focused)"}
    elif (P::is_leaf($nodes[$target])  | not)  then {ok:false, reason:"not a leaf: \($target)"}
    else
      # A::remove deletes the leaf NODE too + collapses the vacated singleton, so
      # capture focused's node and re-add it as an orphan before the split re-links it.
      ($nodes[$focused]) as $foc_node
      | A::remove($tree; $focused) as $t1
      | if (($t1.nodes[$target] // null) == null)
        then {ok:false, reason:"move_leaf: target \($target) vanished after detach"}
        else {ok:true,
              tree: A::split_leaf(($t1 | .nodes[$focused] = $foc_node);
                                  $target; $focused; $orientation; $side)}
        end
    end;

# ── op_place_leaf — INSERT a not-yet-tiled window beside a target leaf ────────
# The bag/place commit (S8): land a carried window (currently stashed/minimized,
# NOT in the tree) into the target's slot, splitting on $side under a fresh
# $orientation node. Like op_move_leaf but with NO detach (the window has no node
# yet) — it mints the leaf ("w:<wid>", matching A::adopt_newcomers) and reuses
# A::split_leaf. The impure caller (place commit) resolves $target (the anchor
# leaf) + $orientation/$side (from the chosen warp dir) and runs reconcile --apply
# after, which deminimizes + frames the newcomer into its slot. Guards: $target
# present + a leaf; the window not already tiled (idempotent reject).
def op_place_leaf($tree; $target; $window_id; $orientation; $side):
  ("w:" + ($window_id | tostring)) as $new
  | ($tree.nodes) as $nodes
  | if   (($nodes[$target] // null) == null)  then {ok:false, reason:"no such node: \($target)"}
    elif (P::is_leaf($nodes[$target]) | not)  then {ok:false, reason:"not a leaf: \($target)"}
    elif (($nodes[$new] // null) != null)     then {ok:false, reason:"window already tiled: \($window_id) (leaf \($new))"}
    else
      {ok:true,
       tree: A::split_leaf(($tree | .nodes[$new] = {id: $new, window_id: $window_id});
                           $target; $new; $orientation; $side)}
    end;

# ── op_remove_leaf — DETACH a leaf from the tree (bag lift / stash) ───────────
# Thin {ok,tree} wrapper over A::remove (detach + collapse the vacated singleton to
# a fixpoint) — the same primitive op_move_leaf uses for its detach half. The bag
# lift/stash (S8) calls this so a lifted window's leaf leaves the tree (the tiling
# reflows AND reconcile won't try to re-show the now-minimized window). Idempotent:
# A::remove no-ops on an absent leaf, so re-lifting / lifting an unmanaged window is
# {ok:true} with the tree unchanged. Rejects an internal node (would detach a whole
# subtree) — callers pass a window leaf id ("w:<wid>").
def op_remove_leaf($tree; $leaf):
  ($tree.nodes[$leaf] // null) as $n
  | if   ($n == null)             then {ok:true,  tree:$tree}
    elif (P::is_leaf($n) | not)   then {ok:false, reason:"not a leaf: \($leaf)"}
    else                               {ok:true,  tree: A::remove($tree; $leaf)} end;

# ── dispatch — new verbs here, the rest delegated to the parcel core ─────────
def apply_op($tree; $op; $args):
  if   $op == "swap_leaf"   then op_swap_leaf($tree; $args.a; $args.b)
  elif $op == "move_leaf"   then op_move_leaf($tree; $args.focused; $args.target; $args.orientation; $args.side)
  elif $op == "place_leaf"  then op_place_leaf($tree; $args.target; $args.window_id; $args.orientation; $args.side)
  elif $op == "remove_leaf" then op_remove_leaf($tree; $args.leaf)
  else P::apply_op($tree; $op; $args) end;
