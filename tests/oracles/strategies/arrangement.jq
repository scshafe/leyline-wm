# arrangement — the line-primary (arrangement-store) tiling strategy (S6 cutover).
#
# A tiling strategy is a PURE jq program: the reactor feeds it the world via
# --argjson (tree $t, observed window set $obs, float rules $rules, topology
# $topo, policy knobs $config, learned min-store $minstore) + --arg focused-leaf
# $foc. Where bsp/balanced return { tree, facts[] } (the tree.read strategies),
# THIS strategy returns { arrangement, facts[] } — it declares the
# `arrangement.read` capability in the manifest, and the sync consumer
# (lib/parcel/autotile.sh) keys on that capability to split .arrangement (not
# .tree) into the single-writer wm_parcel_arrangement_set, gating it on
# arrangement::valid (the INV-1 partition gate) instead of P::validate.
#
# ── THE SLICING-ONLY AUTHORING (S6 scope; arrangement is the SOLE store, A6) ──
# This authors the SLICING subset only (span-insert / non-slicing pinwheel
# authoring is S9). The simplest-correct authoring identity the rollout names:
# SLICING-INSERT == BSP-STYLE ADOPT. Adopting a newcomer by inserting ONE line at
# the focused cell produces exactly the partition the BSP-style adopt engine
# (autotile::sync — the tree MACHINERY that STAYS after the bsp/balanced *modes*
# were deleted in Phase A) produces — so on the slicing subset the arrangement IS
# from_floorplan(the adopt engine's authored tree). We therefore COMPOSE that
# adopt engine verbatim and bridge its result:
#
#   (a) A::sync — the adopt/prune/re-proportion engine (lib/jq/autotile.jq, the
#       internal newcomer-adopt substrate — NOT a selectable mode) authors the
#       BSP tree' + the causal facts. ZERO re-implemented adopt logic; the
#       seed/adopt/prune/reproportion decisions are the engine's.
#   (b) AR::bridge_arrangement($tree; $topo) — derives the line-primary store
#       from that tree: { segments (from_floorplan's bag), bindings (the
#       per-display-qualified <display_id>:<i0>:<j0> side-table carrying
#       project's desired_frame), off_top }. This is the SAME bridge the S3
#       arrangement_targets reads back, so the store the reactor writes is the
#       store the reactor reads.
#
# ── THE CLAMP-DIALECT FORK IS THE #1 HAZARD — WE DO NOT FORK IT ───────────────
# There is ZERO min-fit / feasibility / canvas / split arithmetic in this file.
# Every frame is project's desired_frame (the reachable-target impedance bump
# baked in at parcel.jq:304-328), carried VERBATIM through bridge_arrangement
# into the store; min-size floors are MS::-learned upstream and consumed by
# A::sync / P::project, never re-derived here. A second clamp dialect would
# settle a window differently from the FROZEN GOLDEN (bsp's exact authored output,
# captured at A1 into parcel/fixtures/golden/*) and reintroduce the
# non-reproducible multi-display reframe-thrash (memory: D-over-E reframe-thrash
# fix). The golden-equiv oracle (parcel/golden-equiv.sh) + cmd-test T27's
# byte-equality against the frozen golden are the tripwires that fail the instant
# a fork diverges (they diverge on a min-bound scene).
#
# ── THE STORE IS THE SYSTEM OF RECORD (S10, parcel-core rollout) ──────────────
# The store PERSISTS { segments(+per-segment `relation` sticky marker), bindings(+per-cell
# `contents`), off_top, topology, promotions } across settles, and the NEXT settle's
# prior-state read comes from the STORED ARRANGEMENT ITSELF, not from a re-derived flat
# tree. The flip is _prior_tree_structured (below): it runs FIRST and reads the prior
# managed set + mounts + sticky coords from the stored { segments, bindings } directly,
# ADDITIVELY — it sits IN FRONT of the KEPT _prior_tree flat reconstruction, falling
# through whenever the store lacks faithfully-reconstructable persisted structure
# (_has_persisted_structure false — every pre-S10 store, any tree/empty input, any
# mixed-axis nested display, and EVERY plain flat store). The revert is a one-line guard
# flip (route through _prior_tree unconditionally — the flat reconstruction was never
# deleted), so a wrong structured reader cannot regress the live store into un-recoverable
# code.
#
# THE BYTE-IDENTITY CONTRACT (two guarantees, two oracles): (1) the depth-0 / no-promotion
# / no-sticky / 1-stack BASE CASE stays BYTE-IDENTICAL to the pre-S10 store — proven by the
# single-settle carried oracles (parcel/arrangement-bridge.sh 12/0/0, parcel/golden-equiv.sh
# 5/0; promotions:[] is ignored by arrangement_targets, a 1-deep contents reads back via
# contents[0], a free segment carries no relation field). (2) The STEADY-STATE
# sticky/structure round-trip (prior input = a stored arrangement) — proven SOLELY by the
# new two-settle O0 byte-lock (parcel/store-roundtrip.sh: settle-2 stored == settle-1
# stored) + store_sticky_roundtrip / store_contents_1stack, because the carried
# single-settle goldens structurally cannot reach that path. A hand-set (sticky) gridline
# ratio survives a no-op settle (the segment-space analogue of the I4 pinned-ratio veto)
# instead of being re-snapped. NOTHING derives a recursion yet — S10 only makes the store
# able to HOLD one (the EMPTY promotions relation + the 1-DEEP contents slot are persisted
# INERT, so a later slice has a store that can hold its output).
#
# ── INVARIANTS ───────────────────────────────────────────────────────────────
# The program is PURE (no IO; the port is not in jq's vocabulary). It only
# AUTHORS the arrangement — the reactor's wm_parcel_arrangement_set remains the
# single writer (INV-1), and an arrangement it returns that fails
# arrangement::valid (a gap/overlap partition) is rejected there leaving the
# store intact. Facts use the existing kind vocabulary (seed/adopt/prune/
# reproportion) carried straight from A::sync, so ley parcel explain renders them
# UNCHANGED (the same generic kind-switch the legibility layer has always fed).
# NO CLAMP CHANGE: every frame still flows from P::project via bridge_arrangement
# (the #1 hazard — a forked min-fit dialect — is untouched; the system-of-record
# flip changes only the PRIOR-READ source, never the geometry/feasibility math).
import "autotile" as A;
import "arrangement" as AR;
import "parcel" as P;
import "balance" as B;
import "minsize" as M;
# Compose the adopt engine's authoring (A::sync — adopt/prune/re-proportion, the
# slicing-insert == BSP-adopt identity) ONCE, then bridge its tree into the line-
# primary store.
# from_floorplan derives the segment bag from the authored tree; bridge_arrangement
# carries project's frames + the per-display-qualified bindings — the store
# arrangement_targets reads back byte-equal to reconcile_targets. The facts ride
# out from sync unchanged (the causal stream the legibility layer surfaces).
#
# THE STORE IS SELF-CONTAINED. We merge the NORMALIZED topology (P::norm_topology)
# into the arrangement so the single-writer's INV-1 partition gate
# (arrangement::valid_md) and the readers (arrangement_targets, state) validate +
# project from the store ALONE — mirroring wm_parcel_tree_set's stdin-only contract
# (the tree carries no topology either, but the arrangement's validity is a PER-DISPLAY
# partition over the displays, so it must carry the display rects it partitions).
# `topology` is normalized at author time so the gate never re-normalizes a raw scene.
# ── THE PRIOR-STATE READER (A2.0 — the sync-facts idempotence half) ──────────
# A::sync diffs the live world against the PRIOR managed set, which it reads from
# the input store's `.nodes[].window_id` (prune = a leaf whose window left; adopt =
# a live window not yet a leaf). On the FIRST settle (or a bsp-revert) the input is
# a TREE and that read is direct. But in the arrangement steady state the input is
# the arrangement store this strategy authored LAST settle ({segments,bindings,…},
# no .nodes) — so A::sync would see an EMPTY prior tree, re-seed every window, and
# emit spurious seed/adopt facts each settle (the layout is still correct — the
# bridge is deterministic over the live observed — but the causal stream feeding
# retile.decided / explain would lie, and a vanished window would never report as
# pruned). Reconstruct a minimal MOUNT-SHAPED prior tree from the bindings (the only
# fields A::sync's prune/adopt diff reads are each leaf's window_id + its home mount;
# the binding key is `<display_id>:<i0>:<j0>`, so the display_id is its first segment)
# so the diff is honest. This is NOT a clamp/geometry dialect — it carries ZERO frame
# math; ensure_scaffold + auto_proportion rebuild the geometry from the live world
# exactly as today (the bridge stays byte-stable, proven). A tree input passes through
# unchanged. (The full ratio-preserving arrangement→tree round-trip is the line-native
# authoring of S8/S9; this minimal reader closes only the FACTS gap the flip exposed.)
def _prior_tree($store):
  if ($store.segments == null) then $store          # already a tree (or empty) — direct
  else
    ( ([ ($store.bindings // {}) | to_entries[]
         | { wid: .value.window_id, disp: (.key | split(":")[0]) } ]
       + [ ($store.off_top // [])[] | { wid: .window_id, disp: "1" } ])
      | map(select(.wid != null)) ) as $bound
    | reduce $bound[] as $b
        ( { root_id: "root", nodes: { "root": { id: "root", mode: "region", children: [] } } };
          ("d:" + ($b.disp | tostring)) as $m
          | ("w:" + ($b.wid | tostring)) as $lid
          | ( if (.nodes[$m] // null) == null
              then .nodes[$m] = { id: $m, mode: "row", frame_source: "pinned",
                                  display_id: ($b.disp | tonumber? // $b.disp), children: [] }
                   | .nodes.root.children += [$m]
              else . end )
          | .nodes[$lid] = { id: $lid, window_id: $b.wid }
          | .nodes[$m].children += [$lid] )
  end;

# ── THE STRUCTURE-PRESERVING PRIOR-READER (S10 — the system-of-record flip) ────
# The system of record. _prior_tree (above) flattens the store to a mode:"row" mount
# with NO ratios — so a hand-set (sticky) gridline is RE-SNAPPED to equal by the next
# settle's prune/adopt REPROPORTION (auto_proportion strips computed ratios). This
# reader sits IN FRONT of _prior_tree and carries the persisted STICKINESS forward: it
# reconstructs the SAME per-display mount the flat reader does, then for a display whose
# gridline is HAND-SET (a `relation:"pinned"` segment, the I4-veto analogue), stamps the
# mount ratio_source:"pinned" + the coord-derived `ratios` so the reproportion SKIPS it
# (I4) and from_floorplan re-derives the SAME coord — the sticky gridline survives a
# no-op settle instead of being flattened away.
#
# ADDITIVE + REVERTIBLE. This is the ONLY change to the prior input SOURCE; A::sync's
# adopt/prune logic is UNTOUCHED. The reader is STRUCTURE-PRESERVING ONLY WHEN the
# structure is present-and-faithfully-reconstructable (a single-axis fully-pinned mount
# the cell→binding join recovers exactly); for ANYTHING ELSE it returns null and the
# caller falls through to the always-present _prior_tree flat reconstruction. So the
# revert is a one-line guard flip (route through _prior_tree unconditionally), NOT an
# un-delete — the flat reconstruction is never removed, and a wrong reconstruction on any
# edge case is defused by the fallback. ZERO clamp/frame math: it carries only window_id
# + the mount's ratio vector (read off cell widths); the geometry is rebuilt by
# child_slots from the live world exactly as today.
#
# Per-segment, NOT global (the sticky bit is per-mount): a display whose divider is
# pinned keeps its hand-set ratio; a SIBLING display whose divider is free re-equalizes
# normally — because each display's mount is reconstructed independently and only a
# fully-pinned mount carries ratio_source:"pinned".
#
# SCOPE (honest): S10 faithfully reconstructs the SINGLE-AXIS-PER-DISPLAY slicing case
# (all `v` → row, all `h` → col) — the dominant live shape and the sticky fixture. A
# display with MIXED-axis (genuinely nested BSP) segments is NOT reconstructable as one
# n-ary mount without the full line-native arrangement→tree round-trip (S8/S9), so this
# reader returns null for it and the flat fallback runs (no sticky preserved there — the
# honestly-deferred frontier, exactly as the strategy header names the S8/S9 boundary).
def _sticky_mount($store; $T; $disp):
  ( ($disp | tostring) ) as $dstr
  # The display's segments (homed by from_floorplan's _bags) and its derived cells.
  | ( [ AR::_bags(($store.segments // []); $T)[] | select((.display_id|tostring) == $dstr) ][0] ) as $bag
  | ( ($bag.segments // []) ) as $segs
  | ( [ AR::cells_md(($store.segments // []); $T)[] | select((.display_id|tostring) == $dstr) ] ) as $cells
  # SINGLE-AXIS ONLY: all `v` (a row split) or all `h` (a col split). A mixed-axis
  # (nested) bag is NOT a single n-ary mount → null (fall through to flat).
  | ( [ $segs[] | .axis ] | unique ) as $axes
  | if ($segs | length) == 0 then null            # no divider → nothing sticky to carry
    elif ($axes | length) != 1 then null          # mixed axis (nested) — defer to flat
    else
      ($axes[0]) as $axis
      | (if $axis == "v" then "row" else "col" end) as $mode
      # FULLY PINNED only: every divider on this display is hand-set. A mix of pinned
      # and free dividers on ONE axis cannot be expressed as a single node's
      # ratio_source (per-node, not per-divider) — defer to flat (re-equalizes).
      | ( all($segs[]; (.relation // "free") == "pinned") ) as $all_pinned
      | if ($all_pinned | not) then null
        else
          # Order the cells along the split axis; join each to its bound window via the
          # anchor side-table (the SAME <display_id>:<i0>:<j0> key bindings use). A cell
          # with no binding (a vacant slot) makes the mount un-reconstructable → null.
          ( [ $cells[]
              | { key: ("\(.display_id):\(.i0):\(.j0)"),
                  pos: (if $axis == "v" then (.frame.x) else (.frame.y) end),
                  size: (if $axis == "v" then (.frame.w) else (.frame.h) end) } ]
            | sort_by(.pos) ) as $ordered
          | ( [ $ordered[] | ($store.bindings[.key].window_id // null) ] ) as $wids
          | if (($wids | length) < 2) or (any($wids[]; . == null)) then null
            else
              ( [ $ordered[] | .size ] ) as $sizes
              | ($sizes | add) as $tot
              | if ($tot <= 0) then null
                else
                  { mode: $mode,
                    wids: $wids,
                    ratios: [ $sizes[] | (. / $tot) ] }
                end
            end
        end
    end;

# ── _has_persisted_structure: does the store carry structure worth preserving? ──
# The activation predicate for the structure-preserving prior-read (S10's system-of-
# record flip). TRUE iff the store carries persisted structure the flat _prior_tree would
# DISCARD: a sticky (relation:"pinned") segment today; a deeper-than-1 `contents` stack
# (S16) tomorrow — extended here, in ONE place, as each capability lands. FALSE for a
# plain flat store (no sticky, all 1-deep) — then the prior-read falls through to the
# always-present _prior_tree flat reconstruction, which is byte-identical for the diff
# (the base case). So the flip is structure-DRIVEN: the prior comes from the stored
# arrangement's STRUCTURE only when there is structure to carry; otherwise the simpler
# flat reader runs and the base case stays byte-identical.
def _has_persisted_structure($store):
  ($store.segments != null)
  and ( any(($store.segments // [])[]; (.relation // "free") == "pinned") );

# Build the structure-preserving prior tree, or null if the store carries no faithfully-
# reconstructable persisted structure (then the caller FALLS THROUGH to the always-present
# _prior_tree flat reconstruction). This is the system-of-record FLIP: the prior managed
# set + mounts + sticky coords come from the stored { segments(+relation), bindings }
# DIRECTLY, so what the operator's edits persist (sticky ratios — and, later, nesting and
# deep stacks) survives the settle instead of being flattened away. A::sync's adopt/prune
# logic is UNTOUCHED — only its PRIOR input SOURCE changes, and only when the structure is
# present. Reconstructs EVERY display's mount: a sticky (single-axis fully-pinned) display
# gets a pinned mount carrying its hand-set ratios; a non-sticky display is rebuilt flat
# (windows as direct children, no ratios — re-equalizes, exactly as _prior_tree). Returns
# null iff the store has NO persisted structure (let the flat reader run — byte-identical
# base case) OR a display is structurally un-reconstructable while another is sticky
# (mixed → flat-all, conservative: never half-reconstruct).
def _prior_tree_structured($store; $T):
  if (_has_persisted_structure($store) | not) then null   # no structure → flat reader (base case)
  else
    # The per-display window membership (bindings + off_top), reusing the flat reader's
    # bound-set derivation so adopt/prune see the SAME managed set.
    ( ([ ($store.bindings // {}) | to_entries[]
         | { wid: .value.window_id, disp: (.key | split(":")[0]) } ]
       + [ ($store.off_top // [])[] | { wid: .window_id, disp: "1" } ])
      | map(select(.wid != null)) ) as $bound
    | ( [ $bound[] | .disp ] | unique ) as $disps
    | ( [ $disps[] | { disp: ., sticky: _sticky_mount($store; $T; .) } ] ) as $mounts
    | if (all($mounts[]; .sticky == null)) then null   # structure present but un-reconstructable → flat
      else
        # Build root + per-display mounts. A sticky display uses its reconstructed
        # pinned mount (ordered children + pinned ratios); a non-sticky display is built
        # flat (windows as direct children, no ratios — auto_proportion re-equalizes it).
        ( reduce $mounts[] as $m
          ( { root_id: "root", nodes: { "root": { id: "root", mode: "region", children: [] } } };
            ($m.disp) as $d
            | ("d:" + ($d | tostring)) as $mid
            | ($d | tonumber? // $d) as $dnum
            | if ($m.sticky != null)
              then
                # Pinned mount: children ordered along the split axis, ratios hand-set.
                ( [ $m.sticky.wids[] | ("w:" + (. | tostring)) ] ) as $kids
                | .nodes[$mid] = { id: $mid, mode: $m.sticky.mode, frame_source: "pinned",
                                   display_id: $dnum, children: $kids,
                                   ratios: $m.sticky.ratios, ratio_source: "pinned" }
                | .nodes.root.children += [$mid]
                | reduce range(0; ($m.sticky.wids | length)) as $i (.;
                    ($m.sticky.wids[$i]) as $w
                    | .nodes["w:" + ($w | tostring)] = { id: ("w:" + ($w | tostring)), window_id: $w } )
              else
                # Flat mount (no ratios — re-equalizes), windows in binding order.
                ( [ $bound[] | select(.disp == $d) | .wid ] ) as $dwids
                | .nodes[$mid] = { id: $mid, mode: "row", frame_source: "pinned",
                                   display_id: $dnum, children: [ $dwids[] | "w:" + (. | tostring) ] }
                | .nodes.root.children += [$mid]
                | reduce $dwids[] as $w (.;
                    .nodes["w:" + ($w | tostring)] = { id: ("w:" + ($w | tostring)), window_id: $w } )
              end ) )
      end
  end;

# ── MANUAL Z-STACK CARRY (P-VERBS P6, movemode-stack A1) ──────────────────────
# A DEEP-contents binding round-trips as a tree STACK node (mode:"stack",
# stack_source:"manual" — the valve never unfolds it; A::sync carries nodes), so
# the cold settle PRESERVES a hand-stacked cell instead of re-adopting its buried
# members as siblings. Applied to WHICHEVER prior the readers produce (structured
# OR flat — a stacked GRID display falls to the flat reader, the known
# cold-flatten class: the grid re-equalizes but the STACK must still survive).
# The top's leaf is re-parented under the stack node; buried members gain leaves
# here (neither reader's membership sees non-top wids). Stack-free stores hit the
# reduce with [] → the tree is byte-identical (the golden/roundtrip locks).
def _carry_manual_stacks($store; $tree):
  reduce ( [ ($store.bindings // {}) | to_entries[]
             | select(((.value.contents // []) | length) > 1)
             | { top:  (.value.contents[0].window_id),
                 wids: [ .value.contents[].window_id | select(. != null) ] }
             | select(.top != null) ] | .[] ) as $stk ($tree;
    ("w:" + ($stk.top | tostring)) as $lid
    | ("s:" + ($stk.top | tostring)) as $sid
    | if (.nodes[$lid] // null) == null then .   # top absent from the prior membership → skip
      else
        ( .nodes
          | .[$sid] = { id: $sid, mode: "stack", stack_source: "manual", top: $lid,
                        children: [ $stk.wids[] | "w:" + (. | tostring) ] }
          | reduce ($stk.wids[]) as $w (.;
              .["w:" + ($w | tostring)] = ((.["w:" + ($w | tostring)])
                // { id: ("w:" + ($w | tostring)), window_id: $w })) ) as $n2
        | .nodes = ($n2 | with_entries(
            if ((.value.children // null) != null) and (.key != $sid)
            then .value.children = [ .value.children[] | if . == $lid then $sid else . end ]
            else . end ))
      end );

# ── THE CROWDING VALVE (Phase C — OPT-IN, default OFF, byte-identical) ─────────
# The deleted `balanced` MODE was the only strategy that VALVED: it ran
# `B::valve_live` after `A::sync` to fold a min-INFEASIBLE row/col into a STACK
# instead of letting it shrink/overlap (balance.jq). The arrangement strategy
# bridges A::sync's tree DIRECTLY, so a crowded region never auto-folds — under the
# sole arrangement store the crowding-valve was MISSING. This composes it back,
# OPT-IN, mirroring balanced VERBATIM: there is ZERO new feasibility / min-fit /
# `_required` math here — `B::valve_live` is composed wholesale (the #1 hazard is
# forking a second clamp dialect; we do NOT). The min floors come from $minstore,
# the SAME store reconcile stamps; valve_live stamps it onto the synced tree for the
# DECISION then strips it before persisting (reconcile re-stamps fresh, add-only).
#
# THE GATE is the PRESENCE of `stack_vs_shrink_threshold` in $config (the same knob
# name balanced used). ABSENT ⇒ the valve is NOT composed ⇒ the synced tree bridges
# UNCHANGED ⇒ byte-identical to today (the golden-equiv + arrangement-bridge byte-
# equality tripwires stay green, INCLUDING on a min-infeasible scene where un-valved
# arrangement shrinks/clamps exactly as before). PRESENT (even 0 — at 0 the valve
# folds EXACTLY where the un-valved partition would have shrunk below min, per
# balance.jq:50-55) ⇒ B::valve_live folds the crowded region; the FOLDED tree
# (carrying `mode:"stack"` nodes) bridges through bridge_arrangement: from_floorplan
# emits NO edge for a stack (ONE cell), project presents the stack's top + marks the
# surplus members presented:false → they ride out as the bridge's off_top list, and
# arrangement_targets emits top-presented + rest-as-off_top (the S5 cells_stack /
# S3 off_top path, already proven byte-consistent). Facts compose in DECISION order
# (sync's prune→adopt→reproportion, then the valve's unfold/fold).
( ($config // {}) | if type == "object" then . else {} end ) as $cfg
| ($cfg | has("stack_vs_shrink_threshold")) as $valve_on
# RECLAIM POLICY (reclaim-policy-even-default): how a removed window's freed space is
# redistributed — `even` (band-equal) | `absorber` (single neighbour, today's default) |
# `proportional` | `focus`. Env override (A/B) wins, then the manifest config, then
# `absorber` (so any consumer that passes neither stays byte-identical to pre-feature).
| (env.LEYLINE_PARCEL_RECLAIM // $cfg.reclaim_policy // "absorber") as $reclaim
# Newcomer policy is authored by the lifecycle transaction before this pure
# strategy runs. The strategy remains policy-free and honors the resulting
# membership/pin rules.
| (if $foc == "" then null else $foc end) as $focus
# THE PRIOR-READ IS THE SYSTEM OF RECORD (S10 — the flip). The structure-preserving
# reader (_prior_tree_structured) runs FIRST and reads the prior managed set + mounts +
# sticky coords FROM the stored { segments(+relation), bindings } directly — so what the
# operator's edits persist (sticky ratios today; nesting/deep stacks later) survives the
# settle instead of being flattened away by the lossy flat round-trip. A::sync's
# adopt/prune logic is UNTOUCHED — only its PRIOR input SOURCE changes, and only when the
# store carries persisted structure (_has_persisted_structure).
#
# ADDITIVE: it FALLS THROUGH to the always-present _prior_tree flat reconstruction
# whenever the store lacks faithfully-reconstructable persisted structure (returns null) —
# every store written before S10, any tree/empty input, any mixed-axis (nested) display,
# and EVERY plain flat store (no sticky → the base case, byte-identical for the diff).
#
# REVERT CONTRACT: this is a one-line GUARD FLIP. Route the prior-read back through
# `_prior_tree($t)` unconditionally (drop the `// `-arm) and the structure-preserving
# reader is defused — the flat reconstruction was NEVER deleted, so a wrong structured
# reader on any prune/adopt edge case cannot regress the live store into un-recoverable
# code; it is defused by flipping back to the always-present fallback.
| (P::norm_topology($topo)) as $T
# ── AUTHOR-TIME MIN STAMP, NATIVE EDITION (P-MIN M2-native — reachable authoring A1) ──
# The cold tail stamps floors onto the synced TREE (M::stamp_min_sizes below), but a
# carryable (dragged-grid) store by construction NEVER goes cold — its bindings stayed
# un-stamped, so the native bridge's reach_bump hook and the drag clamp's _cell_min were
# both starved (the 2026-06-10 drag episode, links 1+3 of the chain). Refresh the PRIOR
# store's binding floors from the SAME learned table the cold stamp reads, BEFORE the
# native authors run: the native bridge then (a) reach_bumps each cell at author time
# (M1-native) and (b) re-emits the floor onto binding + contents[0] (M2-native), so the
# authored store is clamp-visible to lineops. INERT: empty $minstore / tree input →
# $ts == $t byte-identically (the golden/roundtrip locks inject {}). The cold path
# keeps reading $t (its prior-readers consume only membership/relation, never min).
| (M::stamp_min_sizes_arr($t; ($minstore // {}); $obs; $topo)) as $ts
# ── Z-DEMOTION AUTHOR GATE (z-demotion Z-1, the M5 data path) ──────────────────
# When the zdemote knob is on (autotile.sh injects {demote:true} into $config),
# stamp each binding's demotable_faces from $obs app identities — the SAME-app
# faces a drag may demote past, evaluated FRESH each settle (the M2 stamp
# pattern; the native bridge re-emits them, the cold rebuild drops them and the
# next gated settle re-stamps). Knob off → no stamp → byte-identical ($ts
# shadowed unchanged; the golden/roundtrip locks).
| ( if ($config.demote // false) and ($ts.segments != null)
    then AR::stamp_demotable($ts; $obs; $T) else $ts end ) as $ts
# ── THE NATIVE STEADY-STATE AUTHOR (S-P2 — line-native frame derivation) ───────
# When the store already holds a line bag AND the managed-live window set is UNCHANGED
# (no adopt, no prune) AND there are no stacks (off_top empty + contents 1-deep — the
# valve is opt-in/default OFF), author the next store DIRECTLY from the carried segments
# via AR::bridge_arrangement_native (re-deriving each cell's frame), instead of the cold
# tree round-trip. This is what makes a hand-dragged GRID / mixed-axis layout PERSIST: a
# gesture (move_line, B1's drag) edits the segments but leaves the binding frames stale,
# and this re-derivation IS the settle's re-stamp (it SUBSUMES B1's `sync` re-author).
# byte-NIL on a flat no-op (native == the cold fixpoint, store-roundtrip stays green);
# byte-PERSIST on a grid (the cold _prior_tree flattens it; native keeps it — the fix).
#
# REVERT: force $native_noop to false (drop this branch) → every settle takes the cold
# path, byte-identical to today. The cold path below is NEVER removed.
#
# $prior_bound is computed ONLY for a segment store ($t.segments != null) so the rec lens
# never runs on a tree/seed input; the first guard clause re-checks it so a tree → false.
| ( [ $obs[] | select(.minimized != true) ] ) as $live_obs
# $prior_bound = the prior MANAGED set (the rec-lens recovery; null on a tree/seed input).
# It drives the native fast-paths' adopt/prune diff ($live - $prior_bound). The newcomer
# float-all exclusion that used to live here is gone — the reactor pins a float-all newcomer
# pre-sync, so a normal pin verdict (via $rules) excludes it (newcomer-policy-unification).
| ( if ($t.segments != null)
    then AR::carryable_windows($t; $T)          # == the rec-lens recovery, factored to lib/jq (S-P5)
    else null end ) as $prior_bound
| ( A::partition($live_obs; $rules).managed | sort ) as $live
# SOUND-BY-CONSTRUCTION: the native author (bridge_arrangement_native) is FLAT — it authors
# top-level cells only, BLIND to promotions/nested. But $prior_bound counts windows through the
# promotion/nested-AWARE lens (arrangement_targets_rec descends a `nested` binding; derive_nested
# materializes promotions). So native may ONLY fire on a GENUINELY FLAT store, else it would drop
# the windows held in a nested sub-arrangement (a managed-set false-positive → window loss). The
# `promotions == []` + `no nested binding` clauses make that exclusion explicit, SYMMETRIC to the
# stack exclusion above (and a no-op today — no live promote/nest verb authors either field).
# Promotion/nest-AWARE native authoring is a future slice that relaxes these two clauses with its
# own verification (B2/B3 region persistence, blocked on this keystone).
| ( ($t.segments != null)
    and ($live == $prior_bound)                                  # no adopt, no prune; the NON-CIRCULAR
                                                                 #   conservation safety: $live is the REAL observed
                                                                 #   set, so a derive_nested under-recovery (A2) →
                                                                 #   mismatch → cold (no-loss), never a silent drop.
    # Same IDs do not imply the same display: an OS-completed mouse drag preserves
    # window identity while moving its frame across a display-local Space boundary.
    # A mismatch must reach A::sync's existing rehome path instead of being snapped
    # back by bridge_arrangement_native from the stale binding keys.
    and AR::observed_bindings_stay_on_display($t; $live_obs; $live; $T)
    and ( if ((env.LEYLINE_PARCEL_NATIVE_PROMOTE // "1") != "0")       # B3-1b REVERT LEVER: =0 → is_flat (promotion store → cold)
          then AR::is_carryable($t)                              # admit a flat OR promotion store (no stack/nested binding);
          else AR::is_flat($t) end ) ) as $native_noop           #   the dispatch carries promotions, derive_nested (B3-1a) re-materializes → PERSISTS
# ── S-P3: the native PRUNE branch (a managed window LEFT a mixed-axis grid) ────
# Sibling of $native_noop: EXACTLY one goner, NO newcomer, the GONER'S display mixed-axis,
# same flat-exclusions (no stack/promotion/nested). AR::bridge_arrangement_native_prune
# reclaims the goner's space line-natively ("reclaim where clean" — the grid SURVIVES where
# the cold _prior_tree flattens it) and returns null on its safety teeth (re-key MISS/
# COLLISION, valid_md fail, >1 goner) → $np is null → the COLD path authors the settle.
# REVERT: force $native_prune to false → every prune takes the cold path (flatten), as today.
| (($prior_bound // []) - $live) as $goners
| ( ((env.LEYLINE_PARCEL_NATIVE_PRUNE // "1") != "0")                 # REVERT LEVER: =0 → cold path
    and ($t.segments != null)
    and (($goners | length) == 1)                                # EXACTLY one goner (Amend. C)
    and ((($live - ($prior_bound // [])) | length) == 0)         # NO newcomer (adopt is S-P4)
    and (if ((env.LEYLINE_PARCEL_NATIVE_PROMOTE // "1") != "0")        # B3-4: admit a CARRYABLE promotion store
         then AR::is_carryable($t) else AR::is_flat($t) end)      #   (still no stack / materialized nested); =0 → is_flat → cold-dissolve
    # Amend. D — route by the GONER'S display: that display's bag must be mixed-axis (a grid).
    # A flat-display goner → cold (equalizes, today's behavior); a sibling grid is left to cold too
    # (v1 conservative; the full per-display compose is a follow-up). `and` short-circuits so
    # $goners[0] is only read when exactly one goner exists.
    and ( ( [ $t.bindings | to_entries[] | select(.value.window_id == $goners[0]) | .key | split(":")[0] ][0] ) as $gdid
          | any( AR::_bags(($t.segments // []); $T)[] | select((.display_id | tostring) == $gdid);
                 ([ .segments[].axis ] | unique | length) >= 2 ) ) ) as $native_prune
| ( if $native_prune then AR::bridge_arrangement_native_prune($ts; $goners; $focus; $topo; $reclaim) else null end ) as $np
# ── S-P4: the native ADOPT branch (a newcomer ARRIVED into a mixed-axis grid) ──
# Sibling of $native_prune: EXACTLY one newcomer, NO goner, the NEWCOMER'S display mixed-axis,
# same flat-exclusions. $ndid = the newcomer's home display (its observed-frame centre). The author
# fills a reserved hole on $ndid first, else inserts a split at the anchor cell; it returns null on
# its safety teeth (re-key MISS/COLLISION, full-set non-conservation, valid_md fail, newcomer-off-
# $ndid) → $na null → cold. REVERT: LEYLINE_PARCEL_NATIVE_ADOPT=0 → cold. Routing by the newcomer's
# display (not a global `any`) is Amend. A — the symmetric port of S-P3's goner-display routing.
| (($live - ($prior_bound // []))) as $newcomers
| ( if ($newcomers | length) == 1
    then ( [ $obs[] | select(.window_id == $newcomers[0]) ][0] ) as $nwobs
         | (if $nwobs == null then null else AR::home_display($nwobs.frame; $T) end)
    else null end ) as $ndid
| ( ((env.LEYLINE_PARCEL_NATIVE_ADOPT // "1") != "0")                 # REVERT LEVER: =0 → cold path
    and ($t.segments != null)
    and (($newcomers | length) == 1)                             # EXACTLY one newcomer (Amend. C)
    and (($goners | length) == 0)                                # NO goner (prune is S-P3)
    and (if ((env.LEYLINE_PARCEL_NATIVE_PROMOTE // "1") != "0")        # B3-4: admit a CARRYABLE promotion store
         then AR::is_carryable($t) else AR::is_flat($t) end)      #   (still no stack / materialized nested); =0 → is_flat → cold-dissolve
    and ($ndid != null)
    and (any( AR::_bags(($t.segments // []); $T)[] | select((.display_id | tostring) == ($ndid | tostring));
              ([ .segments[].axis ] | unique | length) >= 2 )) ) as $native_adopt   # NEWCOMER's display is a grid
| ( if $native_adopt then AR::bridge_arrangement_native_adopt($ts; $newcomers; $ndid; $focus; $topo) else null end ) as $na
| if $native_noop
  then
    # The native no-op: re-derive frames from the carried segments. Carry the S10 schema
    # fields (topology, promotions) exactly as the cold tail does. facts:[] is honest —
    # nothing was adopted/pruned/reproportioned (the sticky-by-default feel, S-P5).
    # $ts (the min-stamped prior) feeds the bridge so reach_bump consumes the learned
    # floors at author time and the M2 re-emit persists them (A1; $ts == $t when min-less).
    { arrangement: ( AR::bridge_arrangement_native($ts; $topo)
                     + { topology: $T, promotions: ($t.promotions // []) } ),
      facts: [] }
  elif ($np != null)
  then
    # S-P3 native prune: the grid SURVIVES the goner (cold would flatten it). Emit a `prune`
    # fact (the SAME kind A::sync emits, so `ley parcel explain` renders unchanged). Cause read
    # from $obs: a goner absent from observed = departed; present + minimized = minimized;
    # present + non-managed = floated.
    ($goners[0]) as $gw
    | ( if (($obs | map(.window_id) | index($gw)) == null) then "departed"
        elif (($obs | map(select(.window_id == $gw and .minimized == true)) | length) > 0) then "minimized"
        else "floated" end ) as $cause
    # absorber (close-refocus A1): the survivor that took the freed space — rides the
    # fact only (nullable; the persisted store stays byte-identical to pre-A1).
    | { arrangement: ( $np.arr + { topology: $T, promotions: (AR::carry_promos($np.arr; ($t.promotions // []); $T)) } ),
        facts: [ { kind: "prune", window_id: $gw, leaf: "w:\($gw)", cause: $cause, absorber: $np.absorber } ] }
  elif ($na != null)
  then
    # S-P4 native adopt: the newcomer joins the grid (the grid GROWS, not flattened — and cold
    # would LOSE a window here). Emit an `adopt` fact (the SAME kind A::sync emits → explain unchanged).
    ($newcomers[0]) as $aw
    | { arrangement: ( $na + { topology: $T, promotions: (AR::carry_promos($na; ($t.promotions // []); $T)) } ),
        facts: [ { kind: "adopt", window_id: $aw, leaf: "w:\($aw)" } ] }
  else
  ((_prior_tree_structured($t; $T) // _prior_tree($t)) | _carry_manual_stacks($t; .)
   # NORMALIZE a bare {}/null-nodes prior to a valid empty tree: A::sync's empty-$live
   # arm (_reequalize) needs {root_id,nodes}, not the bare {} a cleared store yields.
   # Reachable when float-all floats EVERY window on a cold start (empty $live) — pre-Wave-3
   # this only bit if rules floated all windows on a {} store. Byte-equal for any real
   # tree (.nodes != null → unchanged) AND for the tile-all cold start (scaffold path
   # tolerates either shape — jq-verified byte-identical).
   | if (.nodes == null) then { root_id: null, nodes: {} } else . end) as $prior
| A::sync($prior; $obs; $rules; $focus; $topo; $cfg) as $base
# OPT-IN valve: fold the synced tree's crowded regions ONLY when the knob is set.
# valve_live returns {tree, facts}; default (knob absent) passes $base straight through.
| ( if $valve_on
    then B::valve_live($base.tree; $obs; ($minstore // {}); $topo; $focus; $cfg)
    else { tree: $base.tree, facts: [] } end ) as $valved
# AUTHOR-TIME MIN STAMP (P-MIN M1 — the keystone): stamp the learned per-app
# floors onto the synced tree's leaves BEFORE bridging, so project's min-fit
# re-lay (fit_sizes / subtree_min / reach_bump, lib/jq/parcel.jq) authors
# REACHABLE frames — the episode's 468px-cell-for-a-709px-floor class becomes
# a one-settle re-lay instead of diverge-oscillate-revert. Empty $minstore →
# stamp is a no-op → byte-identical (the golden/bridge/roundtrip locks inject
# {}). Topology-capped: a stale poisoned floor axis is dropped at the stamp
# (minsize.jq Step-2 defense), never authored as an overflow.
#
# CONSERVATION FALLBACK (the FOLLOWUPS "bridge bound-set == sync managed set"
# cold-tail assert, made load-bearing): on an INFEASIBLE-floors scene (floors
# that cannot co-fit — fit_sizes returns input unchanged) the stamped project
# can emit OVERLAPPING frames whose centres co-occupy one cell, and the
# bridge's centre-containment join would silently DROP a window (witnessed:
# two 1300-floors on 1920 → one binding survived). If the stamped bridge loses
# any window the synced tree binds, fall back to the UN-stamped bridge
# (pre-M1 authoring: plain cells, the executor refusal toast + flap breaker
# handle the rest) and say so in the facts. Conservation outranks min-fit.
| (M::stamp_min_sizes($valved.tree; ($minstore // {}); $obs; $topo)) as $stamped
# STACK-CARRYING trees bridge through the CONTENTS sink (bridge_arrangement_folded
# — the S16 authority; byte-equal to the plain bridge on a stack-free tree per the
# parity fixtures, but guarded anyway so the golden paths stay byte-untouched by
# construction). This is what makes a MANUAL stack durable: the prior reader's
# stack node round-trips back into contents instead of leaking to off_top.
| ( any(($stamped.nodes // {})[]; (.mode // "") == "stack") ) as $has_stacks
| ( if $has_stacks then AR::bridge_arrangement_folded($stamped; $topo)
    else AR::bridge_arrangement($stamped; $topo) end ) as $bridge0
| ( [ ($valved.tree.nodes // {})[] | select((.window_id // null) != null) | .window_id ]
    | unique | sort ) as $want
| ( ( [ ($bridge0.bindings // {})[] | .window_id ]
      + [ ($bridge0.off_top // [])[] | .window_id ] )
    | map(select(. != null)) | unique | sort ) as $got
| (if $got == $want then null
   else { kind: "min_stamp_unfit_fallback", dropped: ($want - $got) } end) as $unfit_fact
| ( if $unfit_fact == null then $bridge0
    elif $has_stacks then AR::bridge_arrangement_folded($valved.tree; $topo)
    else AR::bridge_arrangement($valved.tree; $topo) end ) as $bridge
# THE STORE IS THE SYSTEM OF RECORD (S10). The authored store carries the S10 schema
# fields, each INERT at its default so the depth-0 base case bridges byte-identically:
#   promotions — the encapsulation relation (spec §1.3). CARRIED FORWARD from the PRIOR
#     store, BUT ONLY WHEN THE RE-AUTHOR PRESERVES THEM — via AR::carry_promos (the ONE
#     carry-or-dissolve decision, factored to lib/jq arrangement.jq, shared by this cold
#     tail AND both native churn tails, B3-4). The cold path RE-AUTHORS segments from a BSP
#     flatten, so a NON-SLICING (T-junction) region's coord_map no longer cell-aligns; a
#     carried stale coord_map is NOT "inert" (derive_nested orphans an interior segment,
#     fails to find the region cell, and DROPS a window on read — the code-confirmed B2/B3
#     A2 corruption). carry_promos keeps the set only if derive_nested over the bridge
#     recovers the SAME windows; else [] (DISSOLVE — no loss, structure gone, the
#     "route-to-cold dissolves" contract). Byte-INERT on a flat prior (promotions==[] →
#     [] → byte-identical to the old literal; golden/bridge/roundtrip untouched). The
#     promotion-aware NATIVE churn tails (native_prune/native_adopt) carry through the SAME
#     helper, so a region PERSISTS the churn whenever it geometrically can.
#   bridge_arrangement already carries segments[].relation (the per-segment STICKY
#     marker, OMITTED for a free segment → byte-identical) + per-cell `contents` (the
#     1-deep stack slot, byte-identical to today's single binding).
| (AR::carry_promos($bridge; ($t.promotions // []); $T)) as $carry_promos
| { arrangement: ($bridge + { topology: P::norm_topology($topo), promotions: $carry_promos }),
    facts: ($base.facts + $valved.facts + (if $unfit_fact == null then [] else [$unfit_fact] end)) }
  end
# (Newcomer-staging facts removed — the policy + the float motion now live upstream in
# the reactor, not in the strategy. newcomer-policy-unification.)
