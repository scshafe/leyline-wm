# Parcel min-size — the learned-store ↔ tree bridge (pure functions, impure-fed).
#
# macOS AX exposes no readable minimum window size (`leyline-reframe query` emits
# none — see windowRecord in leyline-reframe.swift) — the floor is only enforced
# when you SET AXSize.
# So a window's min-size is LEARNED empirically: when the executor asks a window
# to shrink and a post-settle re-query shows it refused (observed still larger
# than the applied target), that refusal IS the floor. This module holds the two
# PURE functions the impure reconcile loop (lib/parcel/reconcile.sh) composes
# around that idea — the loop owns the file I/O and the live query; these are
# data-in/data-out:
#
#   learn_min_sizes($targets; $observed; $store) → store'
#     Fold one cycle's settled observations into the per-app learned table.
#
#   stamp_min_sizes($tree; $store; $observed) → tree'        (Piece 2a)
#     Stamp .nodes[<leaf>].min_size onto each bound leaf from the learned table,
#     so the pure engine (parcel.jq project / child_slots — which already READ
#     leaf.min_size) becomes min-aware with NO engine change.
#
# KEYED BY win_app (bundle_id // app): min-size is a property of the binary, not
# of a document or window instance — Chrome's min is the same for every Chrome
# window. Per-app survives re-tiling and seeds brand-new windows of that app, so
# the cold-start (one diverge → learn → clean) is paid at most once per app.
# Learned table shape:  { "<app_key>": { w?, h? } }  (axes independently optional).
#
# ── the learn predicate (why it can't mis-learn) ────────────────────────────
#   A window contributes a learned min on an axis only when, AFTER the D6 settle
#   loop, its observed size on that axis EXCEEDS its applied target by > TOL — we
#   asked it to be that small and it refused. The settle loop already absorbs the
#   async-resize race (D6), so a still-larger window is clamped, not lagging.
#   learn-UP = max(stored, observed). A symmetric learn-DOWN self-heal lowers a
#   stale floor when a window is observed SMALLER than its recorded min while
#   sitting AT its target (it genuinely can go smaller now) — monotone toward
#   truth, so one transient bad reading can't stick. Apps not seen this cycle are
#   preserved untouched (the fold starts from $store and only visits live targets).

import "geometry" as G;
import "frame_ops" as F;

def win_app($w): ($w.bundle_id // $w.app // null);   # mirrors parcel.jq:236

# ── display-usable caps (P-MIN Steps 1-2) ────────────────────────────────────
# The largest display's usable w/h — the physical bound no real window minimum
# can exceed. An observation LARGER than usable is an overflow artifact (a
# window hanging off-screen — the poisoned-floor class: a live Chrome entry of
# {w:1428,h:1440} on a 1205px-usable display), NOT a floor: learning or
# stamping it would author permanently-overflowing windows once the author-time
# stamp (M1) is live, and fit_sizes returns input unchanged when mins cannot
# fit. Tolerant of raw ({frame:[x,y,w,h]} / {usable:[…]}) and normalized
# ({usable:{w,h}}) topology shapes; null/empty topo → null (no cap — the
# 3-arity compat path and hand-fed fixtures behave exactly as before).
def _usable_caps($topo):
  [ (($topo // {}).displays // [])[]
    | (.usable // .frame // null)
    | if type == "array" and length >= 4 then { w: .[2], h: .[3] }
      elif type == "object" then { w: (.w // null), h: (.h // null) }
      else empty end
    | select((.w != null) and (.h != null)) ]
  | if length == 0 then null
    else { w: (map(.w) | max), h: (map(.h) | max) } end;

# Fold the settled observation into the learned per-app table.
#   $targets  : window-keyed desired state { "<wid>": {presented, frame} }
#               (= reconcile.jq reconcile_targets output).
#   $observed : settled live windows [ {window_id, frame, bundle_id?, app?} ... ].
#   $store    : prior learned table { "<app>": {w?, h?} } (or {}).
def learn_min_sizes($targets; $observed; $store; $topo):
  (G::TOL) as $tol
  | (_usable_caps($topo)) as $caps
  | ( reduce ($observed // [])[] as $w ({};
        if ($w.window_id == null) then . else .[$w.window_id | tostring] = $w end) ) as $obs
  | reduce ($targets | to_entries[]) as $e ($store;
      ($e.value) as $t
      | ($obs[$e.key] // null) as $o
      | if ($t.presented != true) or (($t.frame // null) == null) or ($o == null)
        then .
        else
          win_app($o) as $app
          | if $app == null then .
            else
              ($t.frame) as $tf
              | F::as_frame($o.frame) as $of
              | (.[$app] // {}) as $cur
              # Learn-up is GATED by the display-usable cap (P-MIN Step 1): an
              # observed size beyond usable means the window overflows the
              # screen — an author/lag artifact, not the app's floor. Skip the
              # axis (keep the prior) rather than clamp-to-usable: the real
              # minimum is unknown, and a fabricated usable-sized floor would
              # pin the app to a full screen axis forever. Learn-down (the
              # self-heal) stays ungated — lowering toward truth is always safe.
              #
              # REFUSAL LEARN-DOWN (B1, reachable-authoring 2026-06-10): a
              # refusal that LANDS BELOW the stored floor (target < landed <
              # stored) is DIRECT evidence the real min ≤ landed — the window
              # just demonstrated it can reach that size. The old max() kept
              # the stale-high floor, and the at-target self-heal can never
              # fire during a refusal (landed ≠ target by definition) — so a
              # stale-high floor was unhealable exactly when it mattered (the
              # episode's 441-vs-375 Chrome). Down-moves cannot be the
              # overflow-artifact class (those are LARGER than usable), so the
              # refusal-down arm is un-capped, like the at-target self-heal.
              | ( if   ($of.w > ($tf.w + $tol))                  # refused to shrink:
                  then ( if (($cur.w != null) and ($of.w < ($cur.w - $tol)))
                         then $of.w                              #   landed below stored → heal down
                         elif (($caps == null) or ($of.w <= ($caps.w + $tol)))
                         then ([ ($cur.w // 0), $of.w ] | max)   #   learn up (cap-gated)
                         else ($cur.w // null) end )
                  elif (($cur.w != null)                         # learn down (self-heal):
                        and ($of.w < ($cur.w - $tol))            #   now smaller than recorded
                        and (G::fabs($of.w - $tf.w) <= $tol))    #   while sitting at target
                  then $of.w
                  else ($cur.w // null) end ) as $nw
              | ( if   ($of.h > ($tf.h + $tol))
                  then ( if (($cur.h != null) and ($of.h < ($cur.h - $tol)))
                         then $of.h
                         elif (($caps == null) or ($of.h <= ($caps.h + $tol)))
                         then ([ ($cur.h // 0), $of.h ] | max)
                         else ($cur.h // null) end )
                  elif (($cur.h != null)
                        and ($of.h < ($cur.h - $tol))
                        and (G::fabs($of.h - $tf.h) <= $tol))
                  then $of.h
                  else ($cur.h // null) end ) as $nh
              | if ($nw == null) and ($nh == null) then .
                else .[$app] = ( $cur
                                 | (if $nw != null then .w = $nw else . end)
                                 | (if $nh != null then .h = $nh else . end) )
                end
            end
        end );

# 3-arity compat (pre-P-MIN callers + hand-fed fixtures): no topology → no cap.
def learn_min_sizes($targets; $observed; $store):
  learn_min_sizes($targets; $observed; $store; null);

# Stamp the learned per-app min-size onto each bound leaf, so the pure engine
# (parcel.jq project / child_slots — which already READ leaf.min_size) becomes
# min-aware with no engine change. The leaf carries only a volatile window_id
# (autotile leaves are bare {id,window_id} — no binding), so the app identity
# comes from the OBSERVED window set, not the leaf.
#   $tree     : resolved tree (leaves bound to live window_ids).
#   $store    : learned table { "<app>": {w?,h?} }.
#   $observed : live windows (for window_id → win_app).
# An EXPLICIT (authored) leaf.min_size is never clobbered — authored intent wins;
# the stamp only fills leaves that lack one (the live case — no leaf is authored
# with a min_size). No-op when $store is empty ⇒ behaviour-preserving.
def stamp_min_sizes($tree; $store; $observed; $topo):
  (G::TOL) as $tol
  | (_usable_caps($topo)) as $caps
  | ( reduce ($observed // [])[] as $w ({};
      if ($w.window_id == null) then . else .[$w.window_id | tostring] = win_app($w) end) ) as $app_by_id
  | $tree
  | .nodes |= with_entries(
      .value as $n
      | if (($n.window_id // null) != null) and (($n.min_size // null) == null)
        then
          ( $app_by_id[$n.window_id | tostring] ) as $app
          | ( if $app == null then null else ($store[$app] // null) end ) as $m
          # Stamp-side cap (P-MIN Step 2, defense in depth): a STALE store may
          # still carry a physically-impossible floor — drop that axis at the
          # stamp (an un-stamped axis just gets the normal cell), so a poisoned
          # entry can never author an overflow even before the store is scrubbed.
          | ( if ($m == null) or ($caps == null) then $m
              else ( $m
                     | (if (.w != null) and (.w > ($caps.w + $tol)) then del(.w) else . end)
                     | (if (.h != null) and (.h > ($caps.h + $tol)) then del(.h) else . end)
                     | (if length == 0 then null else . end) )
              end ) as $m2
          | if $m2 != null then .value.min_size = $m2 else . end
        else . end );

# 3-arity compat (pre-P-MIN callers + hand-fed fixtures): no topology → no cap.
def stamp_min_sizes($tree; $store; $observed):
  stamp_min_sizes($tree; $store; $observed; null);

# ── stamp_min_sizes_arr: the ARRANGEMENT-store stamp (P-MIN M2-native) ────────
# The native-author sibling of stamp_min_sizes: refresh each BINDING's persisted
# floor (binding.min_size + contents[0].min_size — the fields P::leaf_fit_min and
# lineops' _cell_min read) from the learned per-app table, via the observed window
# set for window_id → app identity. The strategy stamps the PRIOR store with this
# before the native authors run, so the reach_bump hook (arrangement.jq native
# bridge) consumes the floors at AUTHOR time — the tree-stamp (M1) covers only the
# cold tail, and a carryable (dragged-grid) store by construction never goes cold.
#
# REFRESH semantics (matches the cold author, which re-stamps fresh each settle):
# store entry present → override (a B1 learn-down propagates); store entry absent
# for a RESOLVABLE app → drop (a scrubbed entry propagates); identity UNRESOLVABLE
# (window not observed) → keep what's there. INERT guards: a tree/empty input or
# an EMPTY learned table returns the input UNCHANGED (the golden/roundtrip locks
# inject {} — byte-identical). Stamp-side topology caps as stamp_min_sizes.
def stamp_min_sizes_arr($arr; $store; $observed; $topo):
  (G::TOL) as $tol
  | if (($arr.segments // null) == null) or ((($store // {}) | length) == 0) then $arr
    else
      (_usable_caps($topo)) as $caps
      | ( reduce ($observed // [])[] as $w ({};
            if ($w.window_id == null) then . else .[$w.window_id | tostring] = win_app($w) end) ) as $app_by_id
      | $arr
      | .bindings = ( ($arr.bindings // {}) | with_entries(
          .value as $b
          | ( $app_by_id[$b.window_id | tostring] // null ) as $app
          | if $app == null then .                       # identity unresolvable — keep
            else
              ( ($store[$app] // null) ) as $m
              # Stamp-side cap (P-MIN Step 2, defense in depth) — same per-axis
              # drop as stamp_min_sizes: a poisoned floor never authors overflow.
              | ( if ($m == null) or ($caps == null) then $m
                  else ( $m
                         | (if (.w != null) and (.w > ($caps.w + $tol)) then del(.w) else . end)
                         | (if (.h != null) and (.h > ($caps.h + $tol)) then del(.h) else . end)
                         | (if length == 0 then null else . end) )
                  end ) as $m2
              | .value = ( $b
                           | (if $m2 != null then .min_size = $m2 else del(.min_size) end)
                           | (if ((.contents // []) | length) > 0
                              then .contents[0] |= (if $m2 != null then .min_size = $m2 else del(.min_size) end)
                              else . end) )
            end ) )
    end;

# ── min_violations: the gesture-gate evidence (P-MIN M3, fork-1 staked) ──────
# Over a PROPOSED arrangement store: every presented binding whose cell frame
# sits below its persisted floor (binding.min_size — M2) by > TOL, with the
# relay-feasibility verdict the staked policy needs:
#   relay_ok — could ANY redistribution make this floor fit? false when the
#   floor exceeds the display usable, OR when the sum of floors across the
#   bindings sharing the violated axis band exceeds the usable extent (two
#   1300-floors cannot co-tile on a 1920 strip no matter where the line goes).
#   The band = bindings on the SAME display (anchor-key prefix) whose
#   perpendicular intervals intersect the violated cell's. v1 measures against
#   the LARGEST display's usable (single-display live; per-display refinement
#   when a multi-display scene demonstrates the need).
def min_violations($store; $topo; $minstore; $observed):
  (G::TOL) as $tol
  | (_usable_caps($topo)) as $caps
  # Floor resolution: the persisted binding min (M2) when present, else the
  # learned per-app store via the observed window's app identity — so the gate
  # still sees floors when the author fell back UN-stamped (the infeasible-
  # floors conservation fallback) or the binding predates M2.
  | ( reduce ($observed // [])[] as $w ({};
        if ($w.window_id == null) then . else .[$w.window_id | tostring] = win_app($w) end) ) as $app_by_id
  | ( [ ($store.bindings // {}) | to_entries[]
        | .key as $k | .value as $b
        | ( $b.min_size
            // (($b.contents // [])[0].min_size)
            // ( ($app_by_id[$b.window_id | tostring] // null) as $app
                 | if $app == null then null else (($minstore // {})[$app] // null) end )
            // null ) as $m
        | select(($b.frame // null) != null)
        | { did: ($k | split(":")[0]), wid: $b.window_id,
            f: (F::as_frame($b.frame)), m: $m } ] ) as $cells
  | [ $cells[]
      | . as $c
      | select($c.m != null)
      | { window_id: $c.wid,
          cell_w: $c.f.w, cell_h: $c.f.h,
          floor_w: ($c.m.w // null), floor_h: ($c.m.h // null),
          viol_w: (($c.m.w != null) and ($c.f.w < ($c.m.w - $tol))),
          viol_h: (($c.m.h != null) and ($c.f.h < ($c.m.h - $tol))) }
      | select(.viol_w or .viol_h)
      | . + { relay_ok:
          ( ($caps == null)
            or ( ( (.viol_w | not)
                   or ( ((.floor_w // 0) <= ($caps.w + $tol))
                        and ( ( [ $cells[]
                                  | select(.did == $c.did)
                                  | select( (.f.y < ($c.f.y + $c.f.h)) and ($c.f.y < (.f.y + .f.h)) )
                                  | (.m.w // 0) ] | add // 0 ) <= ($caps.w + $tol) ) ) )
                 and
                 ( (.viol_h | not)
                   or ( ((.floor_h // 0) <= ($caps.h + $tol))
                        and ( ( [ $cells[]
                                  | select(.did == $c.did)
                                  | select( (.f.x < ($c.f.x + $c.f.w)) and ($c.f.x < (.f.x + .f.w)) )
                                  | (.m.h // 0) ] | add // 0 ) <= ($caps.h + $tol) ) ) ) ) ) } ];

# 2-arity compat: binding-persisted floors only (no store/observed resolution).
def min_violations($store; $topo):
  min_violations($store; $topo; null; []);
