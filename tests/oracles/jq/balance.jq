# Parcel balance — the no-overlap stack VALVE for the `balanced` strategy.
#
# A PURE sibling engine module (the build-DRY/modular directive): it COMPOSES
# parcel's primitives by import rather than growing parcel.jq. balanced.jq runs the
# valve AFTER autotile::sync to fold surplus children into stacks wherever a row/col
# can't honour its children above their min-size — so F1's OVERLAP arm
# (lib/jq/floorplan.jq) holds by CONSTRUCTION, instead of letting `fit_sizes`
# pass-through (parcel.jq:177-192) → the reachable-target bump (parcel.jq:313-316) →
# neighbours overlap (which bsp tolerates).
#
# SCOPE of the F1-by-construction guarantee (review 8.3 — F1 has TWO arms, two
# exemptions; the valve covers the common arm, NOT all of F1):
#   • OVERLAP arm — GREEN by construction for COMPUTED splits: the valve stacks until
#     every presented row/col fits its children's Σmin on the split axis, so no two
#     presented cells intersect. EXEMPTION: a user-pinned (ratio_source:"pinned")
#     infeasible split is skipped (I4) → fit_sizes vetoed → siblings overlap (overlap
#     arm RED), as the user instructed — also RED under bsp.
#   • CONTAINMENT arm — may RED for an OVER-CANVAS min: a single leaf whose min exceeds
#     its WHOLE span (even alone in a stack) overflows root — stacking frees split-axis
#     space AMONG SIBLINGS, it cannot shrink one window below its own min. Physics; also
#     RED under bsp; not a valve failure. The conservation oracle surfaces it as
#     `overflowing` so an F1 containment-RED here is ATTRIBUTABLE, not a silent drop.
# So: for computed, non-over-canvas layouts F1 is fully green; the two RED classes above
# are documented, expected, and bsp-identical — never a silent valve failure.
#
# parcel.jq is byte-FROZEN through Stage 4: this module reaches INTO the core
# (P::child_slots / P::subtree_min / P::node_mode / P::is_leaf / P::norm_topology;
# P::op_reveal_leaf joins at the 8.3 fold) but never edits it — so any Stage-4
# regression bisects to a strategy/valve file, never the strategy-agnostic projector.
# The internal-node spans the probe needs (project emits only LEAF frames) are
# recomputed here by `node_frames`, walking the SAME `P::child_slots` geometry so the
# spans bake in fit_sizes + pinned/authored overrides exactly as project does. NOTE
# node_frames' leaf frames equal project's `desired_frame` only on FEASIBLE trees: on
# an INFEASIBLE (over-min) tree node_frames emits the RAW un-bumped slot, while project
# grows the leaf via the reachable-target bump (parcel.jq:313-316). The raw slot is the
# CORRECT probe input (the honest span the children must divide); the divergence is
# pinned by node_frames_overflow. Do NOT "fix" node_frames to apply the bump — that
# would corrupt the probe's span semantics.
#
# Stage 4 builds this in two steps so the first behavioral change is one bisectable
# commit:
#   8.2 (this commit) — `node_frames` + `probe` (PURE, fact-only). NOT yet composed
#       into balanced.jq, so `balanced` stays byte-identical to bsp through 8.2.
#   8.3 — `fold` + `valve($tree;$topo;$foc;$config)` (the first behavioral change),
#       composed after A::sync in balanced.jq, with the conservation oracle.
#
# Rulings baked in (rigorous-architect, 2026-05-29; see the plan's "Stage 4 design"):
#   • node_frames computed ONCE per pass — spans are fold-order-independent (a fold
#     shrinks a node's split-axis subtree_min sum→max, never its frame or siblings').
#   • threshold (px, default 0): a node is infeasible iff
#     Σ(child split-axis min) + (cnt-1)*gap > span + threshold. At 0, for an
#     ALL-COMPUTED row/col node (Stage 4's universe — sync authors only computed
#     children), this is algebraically identical to fit_sizes' PASS-THROUGH point
#     ($tmin > $avail, parcel.jq:180): Σmin > span-(cnt-1)gap ⇔ Σmin+(cnt-1)gap > span.
#     So default-0 folds EXACTLY where bsp's fit_sizes passes through to overlap (pinned
#     by the exact-boundary fixtures at gap 0 AND gap 10). Two honest caveats: (a) the
#     pass-through point is a slightly-CONSERVATIVE superset of *visible* sibling overlap
#     (integer slot rounding + the reachable bump), so the valve may fold a hair eagerly —
#     intended; (b) for an AUTHORED/PINNED child `_required` reads the child's actual
#     assigned footprint (node_frames), NOT fit_sizes' proportional-slot $mins — so the
#     identity does NOT hold for mixed nodes. Dormant in Stage 4 (no such children arise);
#     the authored-child requirement semantics + the false-fold risk are a Stage-7
#     (lock/solidify) decision. See probe_pinned_child.
#   • skip ratio_source:"pinned" nodes (I4 — the user's hand-set split wins, falls to
#     the bump like bsp; ⟹ F1's OVERLAP arm may be RED under a user-pinned infeasible
#     split, parcel.jq:215 — the first of the two documented F1-RED exemptions above; the
#     second is the over-canvas containment case).

import "geometry" as G;
import "parcel" as P;
import "minsize" as M;     # stamp_min_sizes — the live min-aware valve (valve_live)

# The canvas rect project seeds the root over (parcel.jq:284) — re-derived
# IDENTICALLY here (the 3rd copy; floorplan._root:58 is the 2nd). The duplication is
# the Stage-7 canvas_rect($T) extraction debt (FOLLOWUPS:175), upheld so parcel.jq
# stays byte-frozen through Stage 4. Drift is fixture-detectable (a gap_grid_2x2-shaped
# fixture → {8,8,984,984} must hold in project, floorplan, AND here).
def _root($T):
  G::inset_frame((G::frames_union([$T.displays[].usable]) // {x:0,y:0,w:0,h:0}); ($T.gap // 0));

# The split axis of a row/col node ("col" splits vertically → height).
def _split_dim($mode): if $mode == "row" then "w" else "h" end;

# Every node's assigned frame, INTERNAL nodes included — the spans the feasibility
# probe needs. project_walk (parcel.jq:259) emits only leaves; this walks the SAME
# `P::child_slots` geometry (so frames bake in fit_sizes + pinned/authored overrides,
# parcel.jq:215-247) but records {<id>:frame} at EVERY node. The path-guard bounds
# node_frames' OWN walk against re-entry, but `P::child_slots`→`P::subtree_min` are
# themselves UNguarded, so a CYCLIC table still diverges there exactly as project does —
# node_frames relies on validate's I1 rejecting cycles upstream of the writer (it is not
# itself a cycle guard). ASSUMES a STRICT tree: a shared internal node (a DAG; legal +
# uncaught by validate, whose I2 flags only LEAF multi-parent, parcel.jq:451) reached by
# two paths is recorded under whichever path is walked last — so the valve fails safe on
# a non-strict tree (it never folds one; `probe`/`valve` guard with `_strict`, which
# guards DAG sharing, NOT cycles). Computed mount trees from sync are strict + acyclic.
def node_frames($tree; $topo):
  P::norm_topology($topo) as $T
  | ($tree.nodes // {}) as $nodes
  | ($tree.root_id) as $root
  | def go($id; $frame; $seen):
      if ($seen | index($id)) != null then {}
      else
        ($nodes[$id]) as $n
        | ($seen + [$id]) as $s
        | { ($id): $frame }
          + ( if P::is_leaf($n) then {}
              else reduce (P::child_slots($nodes; $T; $n; $frame))[] as $sl ({};
                     . + go($sl.child_id; $sl.frame; $s)) end )
      end;
    if ($root == null) or (($nodes[$root] // null) == null) then {}
    else go($root; _root($T); []) end;

# A tree is STRICT iff no node has two parents (no internal sharing). node_frames /
# the valve only operate on strict trees (the computed-tree invariant); a non-strict
# tree fails safe (no fold). Mirrors parcel.jq's parent_count without exporting it.
def _strict($nodes):
  all( ($nodes | keys[]);
       ( . as $id | [ $nodes | to_entries[]
         | select(((.value.children // []) | index($id)) != null) ] | length ) <= 1 );

# Split-axis REQUIREMENT of an internal row/col node: per child, its subtree_min on
# the split axis if the child is COMPUTED, else (a pinned/authored child held inert) its
# current assigned size on that axis (from node_frames) — then + (cnt-1)*gap for the
# inner gutters. For an ALL-COMPUTED node (Stage 4's universe — BSP authors only computed
# sub-splits) this matches what fit_sizes (parcel.jq:177-192) compares against avail, so
# the threshold-0 fold tracks bsp's overlap exactly. The pinned/authored branch DIVERGES
# from fit_sizes' $mins (parcel.jq:218-223 uses the proportional SLOT size $sizes[i] for
# such a child, whereas this uses the child's actual assigned FOOTPRINT) — deliberately,
# since the footprint is the truer requirement, but it means probe may flag a node whose
# siblings do not actually overlap (the authored child merely spills off-canvas). This
# branch is DORMANT in Stage 4 (no authored/pinned children arise); it is the Stage-7
# lock/solidify reserve, exercised + documented by the probe_pinned_child fixture, where
# the false-fold-vs-fit_sizes question is to be settled.
def _required($nodes; $T; $node; $frames):
  ($node.children // []) as $kids
  | ($kids | length) as $cnt
  | _split_dim(P::node_mode($node)) as $ax
  | ($T.gap // 0) as $gap
  | ( [ $kids[] as $cid
        | ($nodes[$cid]) as $cn
        | if (($cn.frame_source // "computed") == "computed")
          then P::subtree_min($nodes; $cid; $gap)[$ax]
          else (($frames[$cid] // {w:0,h:0})[$ax]) end ]
      | add // 0 )
    + ($gap * ([$cnt - 1, 0] | max));

# An internal row/col node is a stack CANDIDATE when its split-axis requirement
# exceeds its span + threshold. Pure helper shared by probe (8.2) and the fold (8.3).
# Skips: non-row/col, < 2 children, ratio_source pinned (I4), unframed (unreachable).
def _candidates($tree; $topo; $config):
  ($config | if type == "object" then . else {} end) as $cfg
  | ($cfg.stack_vs_shrink_threshold // 0) as $thr
  | P::norm_topology($topo) as $T
  | ($tree.nodes // {}) as $nodes
  | node_frames($tree; $topo) as $frames
  | [ $nodes | to_entries[]
      | .key as $id | .value as $n
      | (P::node_mode($n)) as $mode
      | select( ($mode == "row" or $mode == "col")
                and (((($n.children // []) | length)) >= 2)
                and (($n.ratio_source // "computed") != "pinned")
                and (($frames[$id] // null) != null) )
      | _split_dim($mode) as $ax
      | ($frames[$id][$ax]) as $span
      | _required($nodes; $T; $n; $frames) as $req
      | select($req > ($span + $thr))
      | { node: $id, axis: $mode, span: $span, required: $req,
          children: ($n.children // []),
          # surplus = the children the default fold (top = first child) would hide.
          # The actual fold may pick a different top via focus, changing WHICH child
          # is surplus, never the COUNT (all-but-one).
          surplus: (($n.children // [])[1:]) } ]
  | sort_by(.node);

# ── 8.2: feasibility probe (pure, fact-only) ──────────────────────────────────
# The candidate facts a future `ley parcel explain` surfaces — phase:"candidate"
# (distinct from 8.3's action fact, so the generic renderer never shows a probe as a
# real stack). Does NOT fold; emits one fact per infeasible row/col naming the surplus
# child(ren) by literal id + the required/span that tripped it. On a non-strict tree:
# no candidates (fail safe).
def probe($tree; $topo; $config):
  if (_strict($tree.nodes // {}) | not) then []
  else
    [ _candidates($tree; $topo; $config)[]
      | { kind: "stack", phase: "candidate", node: .node, axis: .axis,
          required: .required, span: .span, surplus: .surplus } ]
  end;

# ── 8.3: the fold (FIRST behavioral change) ───────────────────────────────────
# A valve fold flips an infeasible computed row/col node to `mode:"stack"` (so
# child_slots presents only `top` // first-child, parcel.jq:250 — the surplus children
# go presented:false, no overlap) and stamps PROVENANCE: `stack_source:"valve"` +
# `valve_from` (the prior mode). The provenance is what makes the valve REVERSIBLE and
# keeps it OFF manual stacks (8.5, no stack_source / "manual"). It is pure derived
# bookkeeping the valve owns end-to-end — project/validate/reconcile never read it.

# Un-fold EVERY valve stack back to its prior computed mode (drop top + the markers).
# The MANDATORY first act of each pass (rigorous-architect F3/M2/M5): balanced re-runs
# sync+valve every settle, and sync can carry a prior valve stack forward into this
# pass's input; measuring feasibility on an already-folded node (subtree_min already
# collapsed sum→max) would latch it stacked forever. So strip to the clean computed
# tree, measure, re-fold — mirrors auto_proportion stripping computed ratios every
# settle (autotile.jq:330). NEVER touches a manual stack (stack_source != "valve").
def _unfold($tree):
  $tree | .nodes = (.nodes | with_entries(
    if ((.value.stack_source // null) == "valve")
    then .value = (.value | .mode = (.valve_from // "row")
                          | del(.stack_source) | del(.valve_from) | del(.top))
    else . end ));

# Bound (window-carrying) leaves anywhere under $id, via parcel's DFS closure.
def _descendant_bound_leaves($nodes; $id):
  [ (P::closure($nodes; [$id])) | keys[]
    | select(P::is_leaf($nodes[.]) and (($nodes[.].window_id // null) != null)) ];

# Bottom-up (post-order) fold: recurse children FIRST, then decide THIS node against the
# child-folded tree — so a parent reads its children's POST-fold subtree_min (sum→max
# wherever a child stacked) and folds only if it STILL doesn't fit, stacking at the
# DEEPEST crowding (rigorous-architect F2). This maximizes presented windows ACROSS
# DEPTHS — a deep fold can keep a shallow split's other branch visible. WITHIN a single
# flat infeasible row/col, though, the fold flips the WHOLE node to a stack ⇒ exactly ONE
# child presented (parcel.jq:250), even if a strict subset of the N children would have
# fit. Partial folding (split off only the surplus, e.g. row[a, stack[b,c]]) is a richer
# feature DEFERRED past Stage 4; in practice BSP authors ~binary nodes so flat N≥3 is
# rare (review 8.3). $frames is the UN-folded node_frames (spans are fold-order-
# independent — a fold never changes a node's frame or its siblings'), computed ONCE;
# only the requirement (subtree_min over the progressively-folded $nn) is recomputed per
# node. Returns {nodes, folded:[…]}; `top` is left UNSET here (child_slots defaults to
# first child) — the focus reveal at the end of `valve` sets the visible top once.
def _fold_node($nodes; $T; $frames; $thr; $id):
  ($nodes[$id]) as $n
  | if (P::is_leaf($n)) then {nodes:$nodes, folded:[]}
    else
      (reduce ($n.children // [])[] as $cid ({nodes:$nodes, folded:[]};
         (_fold_node(.nodes; $T; $frames; $thr; $cid)) as $r
         | {nodes:$r.nodes, folded:(.folded + $r.folded)})) as $acc
      | ($acc.nodes) as $nn
      | ($nn[$id]) as $cur
      | (P::node_mode($cur)) as $mode
      | if ($mode == "row" or $mode == "col")
           and ((($cur.children // []) | length) >= 2)
           and (($cur.ratio_source // "computed") != "pinned")
           and (($frames[$id] // null) != null)
        then
          (_split_dim($mode)) as $ax
          | ($frames[$id][$ax]) as $span
          | (_required($nn; $T; $cur; $frames)) as $req
          | if ($req > ($span + $thr))
            then { nodes: ($nn | .[$id].mode = "stack"
                               | .[$id].stack_source = "valve"
                               | .[$id].valve_from = $mode),
                   folded: ($acc.folded + [ {node:$id, axis:$mode, span:$span, required:$req} ]) }
            else {nodes:$nn, folded:$acc.folded} end
        else {nodes:$nn, folded:$acc.folded} end
    end;

# valve($tree;$topo;$foc;$config) → { tree, facts[] }
# The composed pass balanced.jq runs AFTER A::sync: un-fold all valve stacks → measure
# (node_frames spans + subtree_min requirements) → re-fold the infeasible bottom-up →
# reveal the focused leaf through the new stacks (ONCE, on the final tree; ok:false kept
# as-is, never propagated as {ok} into the strategy output). Facts (decision order):
# unfold (a prior valve stack space freed) then fold {kind:"stack", action, node, axis,
# span, required, top, surplus} — top/surplus derived from the FINAL project (honest
# post-reveal reality, so `ley parcel explain` names exactly what is hidden). NOTE on
# NESTED folds: a fold fact's `surplus` is every hidden bound leaf under that node, so an
# OUTER stack's surplus SUBSUMES an inner stack's — the surplus sets are NESTED, not a
# disjoint partition of the hidden set (a leaf hidden two levels deep appears in both
# facts). Each is individually honest (the leaf IS hidden under that node); a consumer
# counting "hidden once each" must dedup. (The conservation oracle reads project, not
# these facts, so it is unaffected — review 8.3.) Fails safe (unchanged tree, no facts)
# on a non-strict or empty tree. Reversibility note: _collapse_singletons (autotile.jq,
# byte-frozen) could strand a stale `top` on a collapsed child, but the un-fold-all-first
# sweep strips every valve top before measuring, so a valve stack never carries one in;
# a stranded top on a MANUAL stack would drop its children — now CAUGHT by the strengthened
# conservation oracle (a dangling-top stack presents no real child ⇒ unexplained).
def valve($tree; $topo; $foc; $config):
  ($config | if type == "object" then . else {} end) as $cfg
  | ($cfg.stack_vs_shrink_threshold // 0) as $thr
  | if (_strict($tree.nodes // {}) | not) or (($tree.root_id // null) == null)
    then {tree:$tree, facts:[]}
    else
      P::norm_topology($topo) as $T
      | ($foc | if . == "" then null else . end) as $focus
      | ([ ($tree.nodes // {}) | to_entries[] | select(.value.stack_source == "valve") | .key ]) as $prior
      | _unfold($tree) as $clean
      | node_frames($clean; $topo) as $frames
      | (_fold_node($clean.nodes; $T; $frames; $thr; $clean.root_id)) as $f
      | ($clean | .nodes = $f.nodes) as $folded
      | ($f.folded | map(.node)) as $folded_ids
      | (if ($focus != null) and (($folded.nodes[$focus] // null) != null)
         then (P::op_reveal_leaf($folded; $focus) | if .ok then .tree else $folded end)
         else $folded end) as $final
      | P::project($final; $topo) as $proj
      | ([ $f.folded[]
           | .node as $nid
           | (_descendant_bound_leaves($final.nodes; $nid)) as $leaves
           | { kind:"stack", action:"fold", node:$nid, axis:.axis, span:.span, required:.required,
               top:     ([ $leaves[] | select(($proj.leaves[.].presented // false) == true) ] | .[0] // null),
               surplus: ([ $leaves[] | select(($proj.leaves[.].presented // false) != true) ] | sort) } ]) as $fold_facts
      | ([ $prior[] as $p | select(($folded_ids | index($p)) == null) | { kind:"stack", action:"unfold", node:$p } ]) as $unfold_facts
      | { tree: $final, facts: ($unfold_facts + $fold_facts) }
    end;

# ── 8.3: the conservation ORACLE (the M1 silently-dropped detector) ───────────
# F1 over the cell set is BLIND to a window that vanished (a hidden leaf contributes no
# cell, so F1 stays green whether the window is stacked OR silently dropped). The oracle
# is the missing half of the net (rigorous-architect M1): it derives `hidden` from
# project's ACTUAL leaf dispositions (presented==false), NOT from the valve's facts —
# because the failure mode is a leaf hidden by something the valve did NOT fact (an
# orphan, a manual stack, a reveal edge case). A hidden managed-bound leaf is EXPLAINED
# iff it is reachable AND some stack ANCESTOR on its path PRESENTS A REAL CHILD and routes
# AWAY from this leaf (the only legal reason project hides a bound leaf: it lost to a
# visible sibling under a working stack). A DANGLING-top stack (top resolves to a non-child
# → project drops ALL its children, parcel.jq:250) presents nothing, so its hidden children
# are UNEXPLAINED — that, an orphan, or any hidden-with-no-routing-stack leaf = silently
# dropped. ok ⟺ no unexplained hidden leaf. F1-green must be because-STACKED, proven here.
# (The bare "has a stack ancestor" test was a false-GREEN on a dangling top — review 8.3.)
#
# Also surfaces `overflowing`: PRESENTED leaves project flags overflow on (slot < min,
# parcel.jq:302) — an over-canvas / over-span min the valve CANNOT fix (stacking frees
# split-axis space among siblings; a single leaf wider than its whole span still overflows
# root → F1's CONTAINMENT arm REDs — physics, also RED under bsp). This is the SECOND F1-RED
# exemption beside the I4-pinned-split OVERLAP case; surfacing it makes an F1 containment-RED
# ATTRIBUTABLE (an expected over-canvas leaf, not a silent valve failure). `ok` ignores it
# (overflow is not a drop — the window is presented, just bigger than the screen).
def _hidden_explained($nodes; $root; $leaf):
  (P::paths_to($nodes; $root; $leaf)) as $paths
  | (($paths | length) > 0)
    and any( $paths[];
        . as $path
        | any( range(0; ($path | length) - 1);
               . as $i
               | ($nodes[$path[$i]]) as $p
               | (($p.mode // "region") == "stack")
                 and ( (($p.children // [])) as $k
                       | (($p.top // ($k[0] // null))) as $pres
                       | (($k | index($pres)) != null)        # the stack presents a REAL child
                         and ($pres != $path[$i + 1]) ) ) );  # ...and routes AWAY from this leaf
def conservation($tree; $topo; $foc; $config):
  valve($tree; $topo; $foc; $config) as $v
  | ($v.tree) as $t
  | ($t.nodes // {}) as $nodes
  | ($t.root_id) as $root
  | P::project($t; $topo) as $proj
  | ([ $nodes | to_entries[]
       | select(P::is_leaf(.value) and ((.value.window_id // null) != null)) | .key ] | sort) as $managed
  | ([ $managed[] | select(($proj.leaves[.].presented // false) == true) ] | sort) as $presented
  | ([ $managed[] | select(($proj.leaves[.].presented // false) != true) ] | sort) as $hidden
  | ([ $hidden[]  | select(_hidden_explained($nodes; $root; .) | not) ] | sort) as $unexplained
  | ([ $presented[] | select(($proj.leaves[.].overflow // false) == true) ] | sort) as $overflowing
  | { ok: (($unexplained | length) == 0),
      managed: $managed, presented: $presented, hidden: $hidden,
      unexplained: $unexplained, overflowing: $overflowing };

# ── 8.3: valve_live — the min-aware composition the reactor runs ───────────────
# The pure `valve` above reads min_size off the tree (P::subtree_min); but sync's
# authored tree carries NO min_size — it is stamped TRANSIENTLY in reconcile from the
# learned store (reconcile.sh:177, minsize.jq:96, ADD-only so reconcile re-stamps a
# null-min tree fresh every settle). So balanced threads the same store in and stamps
# it onto sync's tree for the valve's DECISION, then STRIPS the stamped mins before
# persisting — preserving reconcile's refresh model (persisting them would freeze stale
# mins across a window→leaf rebind, since reconcile's add-only stamp won't overwrite).
# $unmin = leaves with NO min_size pre-stamp = exactly the ones stamp_min_sizes adds to
# (it never clobbers an authored min, minsize.jq:93), so stripping $unmin restores the
# clean tree + the valve's stacks, leaving any future AUTHORED min (Stage 7) untouched.
# Empty store ⇒ stamp is a no-op ⇒ no fold ⇒ byte-identical to bsp (behavior-preserving).
def valve_live($synced; $obs; $minstore; $topo; $foc; $config):
  ([ ($synced.nodes // {}) | to_entries[]
     | select((.value.min_size // null) == null) | .key ]) as $unmin
  | M::stamp_min_sizes($synced; ($minstore // {}); ($obs // []); $topo) as $stamped
  | valve($stamped; $topo; $foc; $config) as $v
  | { tree: ( $v.tree
              | .nodes |= with_entries(
                  .key as $k
                  | if (($unmin | index($k)) != null) then (.value |= del(.min_size)) else . end ) ),
      facts: $v.facts };
