#!/usr/bin/env bash
# Parcel — the LANDED-vs-QUERY differential oracle (snappier-resize #5, Step 1).
#
# THE INVARIANT THIS PINS (I6-critical). The interactive-resize latency fix lets
# the AX executor's `apply` emit a `landed` array — a TOUCHED-windows-only genuine
# post-write re-read — and reconcile.sh feeds it into the SAME pure re-diff
# (reconcile.jq overlay_landed → R::reconcile → G::frame_eq) in place of a second
# full ~0.44s AX enumeration. For that substitution to preserve the I6 fixpoint, the
# verdict computed from the landed re-read (overlaid onto the pre-apply observed)
# MUST equal the verdict computed from a fresh full query of the converged state:
#
#     R::reconcile(tree; topo; overlay_landed(obs; landed))     # the fast path
#       ≡  R::reconcile(tree; topo; converged-query)            # the obs2 backstop
#
# and the comparison must stay in jq (G::frame_eq at TOL) — there is ONE comparator.
#
# THE ECHO TRAP (Cut 2 — "never grade your own homework"). The single way this can
# silently false-settle is if `landed` is an ECHO of the frame just WRITTEN rather
# than a genuine re-read. A min-size-clamped window proves the difference: the write
# asked for a small frame, the window refused, so a genuine re-read reports the
# CLAMPED (still-large) frame → re-diff `reframe` → diverged (correct); an echo
# reports the requested frame → re-diff `noop` → settled (a FALSE fixpoint). This
# oracle asserts the clamp scenario DIVERGES under a faithful re-read AND that the
# echo variant would have falsely settled — so any future executor that echoes
# instead of re-reading fails here, loudly.
#
# This is a PURE jq proof (no live AX, no Swift binary, no reconcile.sh plumbing) —
# it is the comparator the later "oracle-equivalence" verifies name. Steps 3/4 wire
# reconcile.sh to perform exactly the overlay_landed → R::reconcile this proves; the
# Step-4 cmd-test then confirms the live plumbing reproduces this verdict.
#
# Usage: parcel/landed-equiv.sh        (run all scenarios; rc1 on any failure)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
JQ=(jq -L "$REPO/tests/oracles/jq")

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# The single differential program. Given a scenario {tree, topo, obs, clamp} on
# stdin it: (1) runs the pre-apply diff to learn which windows apply would touch and
# their target frames; (2) models the CONVERGED post-apply state — every touched
# window lands at its target, except windows named in `clamp` keep target+extra on
# that axis (the min-size refusal); (3) derives `landed_faithful` (a touched re-read
# of the converged state) and `landed_echo` (the requested target frames — the bug);
# (4) emits the settled/diverged verdict + sorted rediff ids three ways: from a full
# query of the converged state, from overlay_landed(obs; faithful), and from
# overlay_landed(obs; echo). The bash below asserts faithful≡query and echo-catches.
PROG='
import "reconcile" as R;
def verdict($t; $topo; $o):
  R::reconcile($t; $topo; $o)
  | { settled: ((( .show|length)+(.reframe|length)+(.hide|length)) == 0),
      rids:    ([ (.show + .reframe + .hide)[].window_id ] | sort) };
. as $fx
| ($fx.tree) as $t | ($fx.topo) as $topo | ($fx.obs) as $obs | (($fx.clamp) // {}) as $clamp
| R::reconcile($t; $topo; $obs) as $diff
| [ ($diff.show + $diff.reframe + $diff.hide)[] | .window_id ] as $touched
| ( reduce (($diff.show + $diff.reframe)[]) as $r ({}; .[$r.window_id|tostring] = $r.frame) ) as $target_by
# converged: untouched windows hold their pre-apply obs frame; touched windows land
# at target (presented), clamped windows refuse by target+extra on the named axis.
| ( reduce $touched[] as $id ({};
      ($target_by[$id|tostring]) as $tf
      | (($clamp[$id|tostring]) // {}) as $cl
      | .[$id|tostring] = { window_id: $id, minimized: false,
                            frame: { x: $tf.x, y: $tf.y,
                                     w: ($tf.w + ($cl.w_extra // 0)),
                                     h: ($tf.h + ($cl.h_extra // 0)) } } ) ) as $tconv
| ( [ $obs[] | . as $w | ($tconv[$w.window_id|tostring]) as $c
      | if $c == null then $w else $w + {frame: $c.frame, minimized: $c.minimized} end ] ) as $converged
| ( [ $touched[] | $tconv[.|tostring] ] ) as $landed_faithful
| ( [ $touched[] | {window_id: ., frame: $target_by[.|tostring], minimized: false} ] ) as $landed_echo
| { touched:  ($touched | sort),
    v_query:  verdict($t; $topo; $converged),
    v_landed: verdict($t; $topo; R::overlay_landed($obs; $landed_faithful)),
    v_echo:   verdict($t; $topo; R::overlay_landed($obs; $landed_echo)) }
'

# Run the program on a scenario JSON (arg $1), echoing the result object.
run_scenario() { printf '%s' "$1" | "${JQ[@]}" -c "$PROG"; }

# A 1920x1080 single display, no gap (project halves/thirds cleanly).
TOPO='{"displays":[{"id":1,"frame":[0,0,1920,1080]}],"dead_zones":[]}'

# ── Scenario A — faithful settle (the resize happy path) ─────────────────────
# 601 | 602 row over 1920x1080 → BSP targets 960x1080 each. Both observed off-target
# (1600x900). Apply lands both at target. landed-fed verdict and query-fed verdict
# must BOTH be settled, with identical (empty) rediff.
sceneA() {
  local tree='{"root_id":"i","nodes":{"i":{"id":"i","mode":"row","children":["w:601","w:602"]},"w:601":{"id":"w:601","window_id":601},"w:602":{"id":"w:602","window_id":602}}}'
  local obs='[{"window_id":601,"app":"Alpha","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}},{"window_id":602,"app":"Beta","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}}]'
  local r; r="$(run_scenario "{\"tree\":$tree,\"topo\":$TOPO,\"obs\":$obs}")"
  local qs ls qr lr
  qs="$(jq -r '.v_query.settled'  <<<"$r")"; ls="$(jq -r '.v_landed.settled' <<<"$r")"
  qr="$(jq -c '.v_query.rids'     <<<"$r")"; lr="$(jq -c '.v_landed.rids'    <<<"$r")"
  [[ "$qs" == "true" && "$ls" == "true" && "$qr" == "$lr" ]] \
    && ok "A faithful settle: landed-fed ≡ query-fed (both settled, rids $lr)" \
    || bad "A faithful settle: query(settled=$qs rids=$qr) vs landed(settled=$ls rids=$lr)"
}

# ── Scenario B — min-size clamp (THE echo trap) ──────────────────────────────
# Same tree; window 602 refuses to shrink, landing 200px wider than its 960 target.
# A faithful re-read reports the clamped frame ⇒ both verdicts DIVERGE on {602}. An
# echo (landed = requested 960) would re-diff 602 as noop ⇒ false settle. Assert
# (1) faithful landed-fed ≡ query-fed (both diverged on 602), and (2) the echo
# variant settles while the truth diverges — the echo is provably caught here.
sceneB() {
  local tree='{"root_id":"i","nodes":{"i":{"id":"i","mode":"row","children":["w:601","w:602"]},"w:601":{"id":"w:601","window_id":601},"w:602":{"id":"w:602","window_id":602}}}'
  local obs='[{"window_id":601,"app":"Alpha","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}},{"window_id":602,"app":"Chrome","bundle_id":"com.google.Chrome","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}}]'
  local r; r="$(run_scenario "{\"tree\":$tree,\"topo\":$TOPO,\"obs\":$obs,\"clamp\":{\"602\":{\"w_extra\":200}}}")"
  local qs ls es qr lr
  qs="$(jq -r '.v_query.settled'  <<<"$r")"; ls="$(jq -r '.v_landed.settled' <<<"$r")"; es="$(jq -r '.v_echo.settled' <<<"$r")"
  qr="$(jq -c '.v_query.rids'     <<<"$r")"; lr="$(jq -c '.v_landed.rids'    <<<"$r")"
  # (1) faithful re-read tracks the query exactly: both diverged, same rid set.
  [[ "$qs" == "false" && "$ls" == "false" && "$qr" == "$lr" && "$qr" == "[602]" ]] \
    && ok "B clamp: faithful landed-fed ≡ query-fed (both diverged on $lr)" \
    || bad "B clamp: query(settled=$qs rids=$qr) vs landed(settled=$ls rids=$lr) — want both diverged on [602]"
  # (2) the echo variant would FALSE-SETTLE while the truth diverges — caught.
  [[ "$es" == "true" && "$qs" == "false" ]] \
    && ok "B clamp: an echo executor false-settles (echo=$es) where truth diverges (query=$qs) — echo caught" \
    || bad "B clamp: echo trap not exercised (echo settled=$es, query settled=$qs — want echo=true query=false)"
}

# ── Scenario C — overlay soundness with an untouched (noop) window ────────────
# 601 | 602 | 603 row → thirds (640 wide each). 603 is observed ALREADY at its
# target (a noop apply never touches), 601/602 off-target (reframed + landed). The
# overlay must keep 603's pre-apply frame and reproduce the query verdict — proving
# untouched windows are not dropped or misclassified by the touched-only landed set.
sceneC() {
  local tree='{"root_id":"i","nodes":{"i":{"id":"i","mode":"row","children":["w:601","w:602","w:603"]},"w:601":{"id":"w:601","window_id":601},"w:602":{"id":"w:602","window_id":602},"w:603":{"id":"w:603","window_id":603}}}'
  # 603's target third of 1920 = [1280,0,640,1080]; seed obs at exactly that (noop).
  local obs='[{"window_id":601,"app":"A","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}},{"window_id":602,"app":"B","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}},{"window_id":603,"app":"C","minimized":false,"frame":{"x":1280,"y":0,"w":640,"h":1080}}]'
  local r; r="$(run_scenario "{\"tree\":$tree,\"topo\":$TOPO,\"obs\":$obs}")"
  local qs ls qr lr touched
  qs="$(jq -r '.v_query.settled'  <<<"$r")"; ls="$(jq -r '.v_landed.settled' <<<"$r")"
  qr="$(jq -c '.v_query.rids'     <<<"$r")"; lr="$(jq -c '.v_landed.rids'    <<<"$r")"
  touched="$(jq -c '.touched' <<<"$r")"
  # 603 was already at target ⇒ apply touched only {601,602}; both land ⇒ settled.
  [[ "$touched" == "[601,602]" && "$qs" == "true" && "$ls" == "true" && "$qr" == "$lr" ]] \
    && ok "C overlay soundness: untouched 603 preserved, landed-fed ≡ query-fed (touched $touched, settled)" \
    || bad "C overlay soundness: touched=$touched query(settled=$qs rids=$qr) landed(settled=$ls rids=$lr)"
}

# ── Scenario D — a SHOW/reveal target: genuine landed minimized:false must win ───
# 601 | 602 row; 602 is observed MINIMIZED (hidden) ⇒ reconcile emits a `show` for it.
# Apply deminimizes + places it, so its genuine landed re-read is {minimized:false, at
# target}. overlay_landed MUST honor that false (a has()-guard, not jq's `//`, which
# treats false as empty) so the re-diff classifies 602 noop ⇒ settled, matching a fresh
# query. The swallow bug (`$l.minimized // $w.minimized`) would keep the pre-apply
# minimized:true ⇒ re-diff `show` ⇒ false-DIVERGE; this scene fails under it.
sceneD() {
  local tree='{"root_id":"i","nodes":{"i":{"id":"i","mode":"row","frame_source":"authored","frame":[0,0,1920,1080],"children":["w:601","w:602"]},"w:601":{"id":"w:601","window_id":601},"w:602":{"id":"w:602","window_id":602}}}'
  local obs='[{"window_id":601,"app":"A","minimized":false,"frame":{"x":0,"y":0,"w":1600,"h":900}},{"window_id":602,"app":"B","minimized":true,"frame":{"x":0,"y":0,"w":400,"h":300}}]'
  local r; r="$(run_scenario "{\"tree\":$tree,\"topo\":$TOPO,\"obs\":$obs}")"
  local qs ls qr lr touched
  qs="$(jq -r '.v_query.settled'  <<<"$r")"; ls="$(jq -r '.v_landed.settled' <<<"$r")"
  qr="$(jq -c '.v_query.rids'     <<<"$r")"; lr="$(jq -c '.v_landed.rids'    <<<"$r")"
  touched="$(jq -c '.touched' <<<"$r")"
  # 602 is a show target ⇒ touched; both windows land presented-at-target ⇒ settled.
  [[ "$touched" == "[601,602]" && "$qs" == "true" && "$ls" == "true" && "$qr" == "$lr" ]] \
    && ok "D show/reveal: genuine landed minimized:false honored, landed-fed ≡ query-fed (settled)" \
    || bad "D show/reveal: touched=$touched query(settled=$qs rids=$qr) landed(settled=$ls rids=$lr) — minimized:false swallowed?"
}

printf 'landed-equiv: landed-fed-verdict ≡ query-fed-verdict (Step 1 oracle)\n'
sceneA; sceneB; sceneC; sceneD
printf '\nlanded-equiv: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
