# Parcel tree-scope focus — pure cursor helpers (ADR 016).
#
# The "focus-scope cursor" (Hyper+u/i) walks the AUTHORED parcel tree by node id,
# orthogonal to spatial window nav (h/j/k/l, spatial_nav.jq over the 2D plane).
# This module is PURE: it maps a tree (+ topology, for the overlay frame) and a
# cursor node to the next cursor node, or to the scoped node's projected frame. It
# owns no state — the runtime (parcel/scope.json) and the impure executor live
# ABOVE it, exactly as reconcile.jq sits above parcel.jq.
#
# Built per ADR docs/adr/016-parcel-tree-scope-focus.md (§"Step 2 helper
# contracts"). Split OUT of parcel.jq (not grown into it, per the build-DRY/modular
# directive) — it composes parcel's shared primitives (paths_to, child_slots,
# node_mode, is_leaf, norm_topology) by import, the same way reconcile.jq does.
#
# ─────────────────────────────────────────────────────────────────────────
# cursor_parent($tree; $node)               → <node_id>
#     ASCEND: the parent of $node on its lexicographically-first root→node path
#     (the I3 / §13#7 winner policy op_reveal_leaf uses). $node itself at the root
#     (ascend-at-root is a no-op) or if unreachable.
# cursor_descend($tree; $node; $origin_leaf) → <node_id>
#     DESCEND to the presented child: stack→top; row/col/region/fill→the child
#     whose subtree holds $origin_leaf (descend-toward-focus), else the first
#     child; a leaf returns itself (descend-on-leaf is a no-op). $origin_leaf null
#     → first child.
# representative_leaf($tree; $node; $origin) → <leaf_id>
#     Follow presented branches down to a leaf (iterate cursor_descend to a
#     fixpoint). "Which window does this scope ultimately present." null origin →
#     the first-presented leaf.
# nearest_stack_ancestor($tree; $node)      → <stack_id> | null
#     The stack `scope cycle` acts on: the nearest stack AT-OR-ABOVE $node on its
#     lex-first path (a stack cursor → itself; a leaf/region → its closest enclosing
#     stack; null when none). The only tree math the v1 cursor CONSUMER needs (§e).
# cursor_frame($tree; $topo; $node)         → {x,y,w,h} | null
#     The scoped node's projected frame in CG/top-left coords (the overlay binary
#     does the AppKit bottom-left flip), or null when the node is on no PRESENTED
#     path (a hidden stack member — nothing to highlight).
# ─────────────────────────────────────────────────────────────────────────

import "parcel" as P;
import "geometry" as G;

# Ascend: parent of $node on its lexicographically-first reachable path from the
# root. Returns $node at the root / when unreachable (ascend is a no-op there).
# Multi-parent safe: paths_to enumerates every root→node path; we take the I3
# winner (the same policy op_reveal_leaf uses, parcel.jq:400-403).
def cursor_parent($tree; $node):
  ( P::paths_to($tree.nodes; $tree.root_id; $node)
    | sort_by(join("/")) | .[0] ) as $path
  | if ($path == null) or (($path | length) < 2) then $node
    else $path[-2] end;

# Descend: the presented child of $node.
#   leaf             → $node          (descend-on-leaf is a no-op)
#   stack            → .top // first  (the §3 stack gate, parcel.jq:148-149)
#   row/col/region/* → the child whose subtree contains $origin_leaf
#                      (descend-toward-focus, tree.jq:98-112 semantics), else first.
# A round-trip with cursor_parent is the identity when focus hasn't moved.
def cursor_descend($tree; $node; $origin_leaf):
  ($tree.nodes) as $nodes
  | ($nodes[$node]) as $n
  | if ($n == null) or P::is_leaf($n) then $node
    elif P::node_mode($n) == "stack"
      then ($n.top // ($n.children // [])[0] // $node)
    else
      ($n.children // []) as $kids
      | if   ($kids | length) == 0 then $node
        elif $origin_leaf == null  then $kids[0]
        else ( [ $kids[]
                 | select(P::paths_to($nodes; .; $origin_leaf) | length > 0) ][0]
               // $kids[0] )
        end
    end;

# Follow presented branches from $node down to a leaf (cursor_descend to a
# fixpoint). The $next == $cur guard makes a malformed childless internal node
# terminate rather than spin.
def representative_leaf($tree; $node; $origin_leaf):
  ($tree.nodes) as $nodes
  | { cur: $node, done: false }
  | until( .done;
      .cur as $c
      | if ($nodes[$c] == null) or P::is_leaf($nodes[$c]) then .done = true
        else cursor_descend($tree; $c; $origin_leaf) as $nx
          | if $nx == $c then .done = true else .cur = $nx end
        end )
  | .cur;

# The stack the cursor's `scope cycle` acts on (ADR §e — the only tree math the v1
# consumer needs). Walks the lexicographically-first root→node path (the §13#7
# winner path cursor_parent uses) and takes the DEEPEST stack on it: a stack cursor
# resolves to itself, a leaf/region to its closest enclosing stack — the node whose
# `top` actually changes what's presented. null when no stack is on the path
# (a stackless region scope has nothing to cycle). `last` of [] is null.
def nearest_stack_ancestor($tree; $node):
  ($tree.nodes) as $nodes
  | ( P::paths_to($nodes; $tree.root_id; $node)
      | sort_by(join("/")) | .[0] ) as $path
  | if $path == null then null
    else ( [ $path[]
             | select( ($nodes[.]) as $n
                       | ($n != null) and (P::node_mode($n) == "stack") ) ]
           | last )
    end;

# The scoped node's projected frame, for the overlay. Walks every root→node path
# accumulating the slot frame via parcel's own child_slots / split_positions (so
# pinned/authored frames are honored), then takes the lexicographically-first
# PRESENTED path — the same winner project picks among contended paths
# (parcel.jq:184-186). Returns {x,y,w,h} in CG/top-left coords, or null when the
# node sits on no presented path (nothing to highlight). The root projects onto
# the display-union canvas, matching project_walk's seed (parcel.jq:176-178).
def cursor_frame($tree; $topo; $node):
  P::norm_topology($topo) as $T
  | ($tree.nodes // {}) as $nodes
  | ($tree.root_id) as $root
  # USABLE union, matching project's root seed (parcel.jq) — the overlay frame
  # must track where windows actually tile (menu-bar/Dock subtracted).
  | (G::frames_union([$T.displays[].usable]) // {x:0,y:0,w:0,h:0}) as $canvas
  | [ P::paths_to($nodes; $root; $node)[]
      | . as $path
      | ( reduce range(0; ($path | length) - 1) as $i
            ( { frame: $canvas, presented: true };
              .frame as $pf
              | $nodes[$path[$i]] as $pn
              | ( [ P::child_slots($nodes; $T; $pn; $pf)[]
                    | select(.child_id == $path[$i+1]) ][0] ) as $slot
              | if $slot == null
                then { frame: null, presented: false }
                else { frame: $slot.frame,
                       presented: (.presented and $slot.selected) }
                end ) )
        + { path: $path } ]
  | ( [ .[] | select(.presented and (.frame != null)) ]
      | sort_by(.path | join("/")) | .[0] ) as $win
  | ($win.frame // null);
