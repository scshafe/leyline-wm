# Parcel reconcile — the pure backend-diff layer (Phase 3a).
#
# parcel.jq is pure projection / identity / ops: it maps a tree + topology to a
# desired frame-map (project) and binds windows to leaves (resolve). It
# deliberately stops there — its header notes that "the reconcile loop that
# drives a real backend (Phase 3) consumes this output; it does not live here."
# This module is that next layer up: given the DESIRED state (from project) and
# the OBSERVED live window state (from the backend's query), it computes the
# mechanism-AGNOSTIC transition set needed to make observed match desired.
#
# It is still PURE — zero backend calls. The impure executor (Phase 3b: the
# {reframe, minimize, query, subscribe} adapter over CoreGraphics/AX) consumes
# this diff and is "a thin executor over its output." This module is the
# two-dimensional generalization of a frame-only reconcile: it diffs frames
# AND the presented set (design §8, §11).
#
# ── MECHANISM-AGNOSTIC (why this is buildable before the cover/minimize answer)
# The diff speaks abstract verbs — show / reframe / hide — never "minimize" vs
# "cover-via-raise." Choosing the mechanism (design §9: cover-via-raise the
# same-display default, net-difference minimize the fallback) is the EXECUTOR's
# job, not the diff's. So this layer ships without resolving the open cross-app
# cover question — the single biggest Phase-3 risk lives entirely below this
# seam.
#
# ─────────────────────────────────────────────────────────────────────────
# DATA
# ─────────────────────────────────────────────────────────────────────────
#
# targets — window-keyed DESIRED state (from reconcile_targets):
#   { "<window_id>": { window_id, presented: bool, frame: {x,y,w,h}|null } }
#     presented=true  → the window should be on-screen at `frame`.
#     presented=false → the window should be hidden (a bound but off-top leaf).
#   Vacant leaves (binding kept, no live window) contribute NO target — there is
#   no window to act on (§7). One window ↔ one leaf (I7) ⇒ keys are unique.
#
# observed — live window state (from the backend's query):
#   [ { window_id, frame: {x,y,w,h}|[x,y,w,h], minimized: bool } ... ]
#     `minimized` is the abstract NOT-PRESENTED bit as the adapter reports it:
#     under the minimize mechanism it is literal AXMinimized; under cover it is
#     whatever the adapter's query returns for an occluded window (suppressing
#     redundant hides for already-covered windows is the adapter's concern, not
#     the pure diff's). The diff only needs "is this window presented now" =
#     (minimized != true). Frames are coerced exactly as project produced
#     desired frames (as_frame → round), so frame_eq compares like with like.
#
# ─────────────────────────────────────────────────────────────────────────
# reconcile_diff($targets; $observed) →
#   { show:    [ {window_id, frame} ... ],    # not-presented → presented (place)
#     reframe: [ {window_id, frame, from} ],  # presented, frame drifted past TOL
#     hide:    [ {window_id} ... ],           # presented → not-presented
#     noop:    [ {window_id} ... ] }          # already correct
#
#   The four lists PARTITION the managed window set (Σ lengths == |targets|),
#   each window_id-sorted (deterministic). Observed windows with no target are
#   UNMANAGED and left untouched — Parcel subsumes only managed windows; tiling
#   (and any other reconciler) own the rest, and the two must never move the
#   same window (§8).
#
# APPLY ORDER — the executor's contract (design §8): show → reframe → hide.
#   Bring incoming on-screen and place it BEFORE hiding outgoing: never a blank
#   frame, never hide the only copy of a contended leaf. simulate_apply models
#   exactly this order; the real adapter must be observably equivalent.
#
# IDEMPOTENCE (I6) — reconcile-to-target, never relative deltas. So
#   reconcile_diff after simulate_apply yields empty show/reframe/hide. Every
#   reconcile_diff fixture asserts this fixpoint (`stable: true`).
#
# reconcile_targets($tree; $topo)   → targets    (composes project; parcel-bound)
# reconcile($tree; $topo; $observed) → the diff   (the loop's one-shot entry)
# simulate_apply($observed; $diff)  → observed'   (pure model of the executor)
# ─────────────────────────────────────────────────────────────────────────

import "parcel" as P;
import "geometry" as G;
import "frame_ops" as F;

# ── observed → window-keyed {window_id, frame, minimized} ────────────────────
# Frames coerced through frame_ops' as_frame/round_frame so they match the
# desired-frame side bit-for-bit (both array and object inputs accepted).
# as_frame/round_frame were promoted out of parcel.jq into frame_ops.jq once
# this module (and autotile.jq) became consumers — the diff layer composes the
# shared helper directly rather than reaching into parcel for it.
def norm_observed($observed):
  reduce (($observed // [])[]) as $w ({};
    ($w.window_id) as $wid
    | if $wid == null then .
      else .[$wid | tostring] =
             { window_id: $wid,
               frame:     F::round_frame(F::as_frame($w.frame)),
               minimized: ($w.minimized // false),
               # the z-demotion read split (doc 12 M3): `minimized` keeps the
               # historical AXMinimized||covered fold; `covered` (a 2026-06-11
               # executor field) lets the demoted arm tell covered-as-intended
               # from a genuine minimize. Absent (older executor/fixtures) → false.
               covered:   ($w.covered // false) }
      end);

# ── the diff: classify each target window against the observed state ─────────
def reconcile_diff($targets; $observed):
  norm_observed($observed) as $obs
  | reduce ($targets | to_entries[]) as $e (
      {show: [], reframe: [], hide: [], noop: [], assert_under: []};
      ($e.value)            as $t
      | ($t.window_id)      as $wid
      | ($t.frame // null)  as $want
      | ($obs[$e.key] // null) as $o
      | (($o == null) or ($o.minimized == true)) as $hidden_now
      # The DEMOTED arm (z-demotion Z-2): a demoted:true target sits UNDER its
      # same-app `under` neighbour by design. (a) Reading COVERED (the new field
      # — NOT the merged minimized bit) with the neighbour present is
      # covered-AS-INTENDED → noop, never `show` (the I6 show-loop the read fold
      # would otherwise cause); a genuine user minimize reads minimized && NOT
      # covered and falls through to today's arms (never swallowed). (b) Every
      # live demoted pair emits an assert_under entry — the executor re-asserts
      # the neighbour's z each settle (re-bury after a lift), frames untouched
      # (simulate_apply ignores the list; the 3-list settled predicate too).
      | ( ($t.demoted // false) == true and (($t.under // null) != null) ) as $demoted
      | ( $demoted and ($o != null)
          and ( (($obs["\($t.under)"] // null) | if . == null then false else (.minimized | not) end) ) ) as $under_live
      | ( if $under_live then (.assert_under += [ {window_id: $wid, under_window_id: $t.under} ]) else . end )
      | if ($t.presented == true) then
          # should be on-screen at $want
          if $hidden_now then
            ( if $demoted and ($o != null) and ($o.covered == true)
              then .noop += [ {window_id: $wid} ]          # covered-as-intended, not a hide
              else .show += [ {window_id: $wid, frame: $want} ] end )
          elif ($want != null) and ((G::frame_eq($o.frame; $want)) | not) then
            .reframe += [ {window_id: $wid, frame: $want, from: $o.frame} ]
          else
            .noop += [ {window_id: $wid} ]
          end
        else
          # should be hidden
          if $hidden_now then
            .noop += [ {window_id: $wid} ]
          else
            .hide += [ {window_id: $wid} ]
          end
        end )
  | .show         |= sort_by(.window_id)
  | .reframe      |= sort_by(.window_id)
  | .hide         |= sort_by(.window_id)
  | .noop         |= sort_by(.window_id)
  | .assert_under |= sort_by(.window_id)
  # assert_under rides ONLY when live demoted pairs exist: every pre-Z2 fixture,
  # event payload and consumer keeps the exact 4-key diff shape (byte-inert).
  | (if (.assert_under | length) == 0 then del(.assert_under) else . end);

# ── the executor, modeled purely ─────────────────────────────────────────────
# Applies a diff to an observed list in the contract order show → reframe →
# hide, returning the resulting observed list (so it can feed back into
# reconcile_diff to prove idempotence). Phase 3b's real adapter must be
# observably equivalent to this — it is the reference oracle for differential
# testing the backend. Windows absent from the diff (unmanaged) pass through
# unchanged.
def simulate_apply($observed; $diff):
  norm_observed($observed) as $obs0
  | ( reduce ($diff.show[])    as $s ({};  .[$s.window_id | tostring] = {present: true,  frame: $s.frame}) ) as $a1
  | ( reduce ($diff.reframe[]) as $r ($a1; .[$r.window_id | tostring] = {present: true,  frame: $r.frame}) ) as $a2
  | ( reduce ($diff.hide[])    as $h ($a2; .[$h.window_id | tostring] = {present: false, frame: null})     ) as $acts
  | [ $obs0 | to_entries[]
      | .value as $w
      | ($acts[.key] // null) as $a
      | if   $a == null            then $w
        elif $a.present == false   then $w + {minimized: true}
        else                            $w + {minimized: false, frame: ($a.frame // $w.frame)}
        end ];

# ── post-apply observed, reconstructed from a touched-only landed re-read ────
# The executor's `apply` (Phase 3b) can append a `landed` array — one record per
# window it ACTED ON (show / reframe / hide), each a GENUINE post-write AX re-read
# (fresh AXPosition/AXSize + AXMinimized/covered, NOT an echo of the requested
# frame). overlay_landed reconstructs the full post-apply observed by merging those
# touched re-reads back over the PRE-APPLY observed: untouched windows keep their
# pre-apply frame (they did not move — apply only touches its own windows), touched
# windows take their landed frame/minimized. Feeding the result into reconcile() is
# byte-equivalent to re-diffing a fresh full query of the converged state, WITHOUT a
# second full AX enumeration — the latency the post-apply re-query was paying.
#
# Why this preserves I6 (the load-bearing invariant): the settled/diverged DECISION
# still flows through reconcile_diff → G::frame_eq at TOL (one comparator). landed is
# DATA fed in, never a verdict computed in the executor. A min-size-clamped window
# whose landed re-read reports the CLAMPED (still-large) frame re-diffs as `reframe`
# ⇒ diverged — exactly as an obs2 query would. An executor that echoed the requested
# frame instead of re-reading would falsely re-diff as `noop` ⇒ a false-settle; the
# landed-equiv oracle (parcel/landed-equiv.sh) pins that the clamped case diverges.
#   $observed : pre-apply observed list [ {window_id, frame, minimized, bundle_id?, app?} ].
#   $landed   : touched-window post-apply re-reads [ {window_id, frame, minimized?} ].
# Identity fields (bundle_id/app — min-size learn keys off them) are preserved from
# $observed; a landed window absent from $observed is appended (defensive — a show
# target normally already appears in $observed as minimized).
def overlay_landed($observed; $landed):
  ( reduce ($landed // [])[] as $l ({};
      if ($l.window_id == null) then . else .[$l.window_id | tostring] = $l end) ) as $by
  | ( [ ($observed // [])[]
        | . as $w
        | ($by[$w.window_id | tostring] // null) as $l
        | if $l == null then $w
          else $w + { frame: $l.frame,
                      # has()-guard, NOT `//`: a GENUINE landed `minimized:false` (a
                      # successfully deminimized show/reveal target) must win — jq's
                      # `//` treats false as empty and would fall through to the
                      # pre-apply `minimized:true`, false-DIVERGING the re-read onto the
                      # slow query backstop. (Safe either way — the false-SETTLE combo
                      # `presented:false target ∧ pre-apply minimized:true` classifies as
                      # noop and never enters $landed — but honor the re-read so show/
                      # reveal keeps the fast path. landed-equiv.sh scene D pins this.)
                      minimized: (if ($l | has("minimized")) then $l.minimized
                                  else ($w.minimized // false) end) }
          end ] ) as $merged
  | ( reduce $merged[] as $w ({}; .[$w.window_id | tostring] = true) ) as $seen
  | $merged + [ ($landed // [])[] | select(($seen[.window_id | tostring] // false) | not) ];

# ── targets: window-keyed DESIRED state, from project + the tree's window ids ─
# project is leaf-keyed and frame-only; the tree carries each leaf's resolved
# window_id (Phase 2). Join them: a presented bound leaf becomes a place target,
# a bound off-top leaf a hide target, a vacant leaf nothing.
def reconcile_targets($tree; $topo):
  P::project($tree; $topo) as $proj
  | ($tree.nodes // {}) as $nodes
  | reduce ($proj.leaves | to_entries[]) as $e ({};
      ($nodes[$e.key].window_id // null) as $wid
      | if $wid == null then .
        else .[$wid | tostring] =
               { window_id: $wid,
                 presented: $e.value.presented,
                 frame:     $e.value.desired_frame }
        end);

# ── the loop's one-shot entry point: project → targets → diff ────────────────
def reconcile($tree; $topo; $observed):
  reconcile_diff(reconcile_targets($tree; $topo); $observed);
