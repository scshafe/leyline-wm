# Parcel lineops — the line-EDIT write primitives (insert_line / remove_line).
#
# S14a (parcel-core). The FIRST genuinely-new WRITE primitives over the
# `arrangement` store (spec §6.1 P-INSERT / P-MERGE). `ops.jq` holds only the
# BSP-tree ops (op_swap_leaf/op_move_leaf/… gated by O::apply_op); none of the
# five line-primitives exist there. This is their home for the two with no prior
# anchor: insert_line (split a cell into two filled rectangles) and remove_line
# (fuse two rectangle-forming sides, electing a survivor binding).
#
# POSTURE — a SIBLING lens-op module: "a lens/op composing a lens" (a read-only
# lens over the arrangement store). It is NOT an extension of ops.jq (ops.jq stays the
# BSP-tree door gated by O::apply_op — lineops is its OWN door over the arrangement
# noun via apply($arr;$T;$op;$args)).
#
# LIVE STATUS — S18 B1 (2026-05-31) WIRED move_line live: the private directional
# resize author in lib/parcel/gesture.sh is the FIRST live importer — it runs
# L::apply(…;"move_line";…), pins the moved segment, and pipes the result through
# wm_parcel_arrangement_set (which still gates on A::valid_md; the gesture's own
# A::valid_rec _gate is the closure tooth). The OTHER five ops (insert_line/
# remove_line/promote/demote/rebind + span-insert) remain harness/CLI-only until
# B2/B3 wire them. Revert of B1: delete the directional author and its tests (this
# file is unchanged by B1 — move_line is composed, not edited). Revert of lineops
# itself (back to S13): additionally delete this file +
# the `lineops` SURFACES token + the filter_for arm + parcel/fixtures/lineops/ + the
# one guard-exclusion token.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CLOSURE-BY-REJECTION CONTRACT (spec §6.4) — and WHY THE GUARDS ARE THE TEETH
#
# Each op runs a CHEAP STRUCTURAL PRE-GUARD and bails with {ok:false,reason} +
# NO candidate formed on failure; only on success does it form the candidate and
# run _gate (A::valid_rec on the WHOLE candidate store) as a backstop. On EITHER
# false arm the caller's $arr is untouched (jq purity: the failure path never
# surfaces the candidate).
#
# THE LOAD-BEARING FINDING (verified empirically against the real arrangement.jq):
# the structural GUARDS are load-bearing for CORRECTNESS, NOT cheap pre-checks.
#   - A bad-span insert (e.g. v@600 [0,500] over a 1000-tall cell) is SILENTLY
#     re-merged by the atom-grid union-find to ONE cell — valid_rec returns
#     ok:true. So valid_rec CANNOT catch a dangling half-line.
#   - An L-fuse remove (dropping a line whose two sides have unequal perpendicular
#     extent) SILENTLY collapses to ONE coarser-but-VALID cell — valid_rec ok:true.
#     And incident() on an L/T line returns >2 sides (verified 4 on the L-fuse).
# Therefore valid_rec is DEFENCE-IN-DEPTH ONLY. The REAL closure teeth are:
#   - insert_line: the span MUST anchor BOTH faces of the target cell
#     (_span_anchors_both_faces), checked BEFORE any union-find.
#   - remove_line: |incident|==2 AND the two sides have equal perpendicular extent
#     (_sides_form_rectangle) — the rectangle precondition.
# An op that delegated closure to valid_rec alone would WRONGLY return {ok:true}
# on a no-op store. Do NOT delegate closure to valid_rec.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE SYNTHETIC LINE-ID SCHEME (S14a) — and what S15 makes load-bearing.
#
# insert_line stamps an OPTIONAL `id` on the appended segment: a monotone counter
# _next_line_id = 1 + (max .segments[].id // 0), scoped to the store bag. The id
# is OMIT-WHEN-ABSENT — every pre-S14a / bridge-authored / golden segment carries
# ZERO id fields (from_floorplan emits the bare {axis,coord,lo,hi}(+relation? for
# pinned), no id), so a store with zero inserts is byte-identical by construction
# (arrangement-bridge 12/0/0, golden 5/0, store-roundtrip 2/0 stay green). The id
# is the spec §8.1 synthetic primitive id — ADDRESSABLE (remove_line addresses by
# it), but NOT yet load-bearing for cell KEYING. S15 makes line-set identity
# load-bearing (assigning real ids to ALL segments — a stored-bytes change
# deliberately NOT pulled forward) and addresses legacy id-less segments (which
# remove_line here returns {ok:false} for — no geometry fallback in S14a). The
# rejected alternative (a geometry-derived id "L:axis:coord:lo:hi") is float-
# fragile (600 vs 600.0; a 1/3 split → "…333.3333…") and the LEAST stable id
# under S15's move gesture — it is NOT the S15 answer either.
#   ID-UNIQUENESS, NOW TOTAL (S15 CLOSED the latent S14a asymmetry): remove_line
#   ADDRESSES the FIRST id-match ([…][0], capturing its to_entries .key) and as of
#   S15 DROPS BY THAT INDEX (select(.key != $hit.key)), NOT select(.id != line_id)
#   which dropped EVERY id-match. The monotone _next_line_id never stamps a duplicate
#   and from_floorplan emits no id, so no bag with two equal ids is producible — but
#   S15 makes line-set identity load-bearing (a cell's primary key is its 4 bounding
#   line ids), so a forged/duplicate id MUST NOT be able to alias two cells onto one
#   line-set key by silently dropping both sides. Index removal makes the primary-key
#   guarantee TOTAL (the monotone counter prevents duplicate STAMPS; this makes the
#   removal address EXACTLY ONE segment regardless). Byte-exact on the inverse-pair.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE INVERSE-PAIR: remove_line ∘ insert_line == identity, BYTE-EXACT, ANY ordering.
#
# insert APPENDS to the .segments tail (+ [$seg]) and NEVER re-sorts; remove
# FILTERS by id (select(.id != line_id)) and NEVER re-sorts. So the prior segments
# keep their exact order + bytes, and removing the appended tail element restores
# the exact prior list on ANY input ordering. (Append-then-SORT BREAKS this on a
# non-canonically-ordered store — the writer does not canonicalize segment order —
# so neither op sorts.) The stamped id is the ONLY mutation; relation:"free"
# stamps no field; off_top/topology/promotions/bindings are carried verbatim.
#
# ─────────────────────────────────────────────────────────────────────────────
# SURVIVOR RE-KEYING IS DEFERRED TO S15. remove_line records the survivor election
# (the SHIPPED P::descriptor_specificity ladder) and DROPS the loser — but does NOT re-key
# the fused cell's surviving binding onto its NEW anchor. On the inverse-pair this
# is a no-op (insert authors no binding for the split halves — that is S15/S16). A
# remove between two BOUND cells therefore leaves the survivor's binding under its
# OLD anchor until S15 re-homes it. S14b/S15 must NOT assume re-homing is done.
# ─────────────────────────────────────────────────────────────────────────────

import "arrangement" as A;   # cells / valid_rec / incident / _canvas / _bags / _segment_point / _anchor_key — COMPOSED VERBATIM
import "parcel" as P;        # descriptor_specificity (the ONE survivor comparator) + norm_topology — VERBATIM
import "geometry" as G;      # frame_min_*/frame_max_*/fabs — the shared frame algebra, never re-coded

def TOL: A::TOL;             # the shared tolerance, re-exported not forked (A::TOL is G::TOL at arrangement.jq:73)

# The demoted cell's residual extent floor (z-demotion Z-1): a demotable cell
# cedes room down to THIS, never to 0 — a zero-extent cell would put coincident
# parallel segments in the bag (TOL-deduped by compress → a broken partition).
# 2·TOL keeps the partition non-degenerate; a deliberate deviation from the
# design doc's "extent 0" oracle, recorded in the z-demotion plan.
def DEMOTE_EXTENT: (2 * TOL);

# ── _next_line_id: the monotone synthetic id counter, store-scoped ────────────
def _next_line_id($arr):
  1 + (([ ($arr.segments // [])[].id // 0 ] | max) // 0);

# ── _home_bag: the per-display bag whose inset rect contains a segment ────────
# Composes A::_bags (the SAME per-display partition the lens derives over) +
# A::_segment_point (the SAME midpoint frame the homing uses) — never a forked
# homing rule. Returns the bag {display_id, segments, rect} or null.
def _home_bag($segments; $T; $seg):
  (A::_segment_point($seg)) as $pt
  | ((G::frame_min_x($pt) + G::frame_max_x($pt)) / 2) as $cx
  | ((G::frame_min_y($pt) + G::frame_max_y($pt)) / 2) as $cy
  | ( [ A::_bags($segments; $T)[]
        | select( (G::frame_min_x(.rect) - TOL <= $cx) and ($cx <= G::frame_max_x(.rect) + TOL)
                  and (G::frame_min_y(.rect) - TOL <= $cy) and ($cy <= G::frame_max_y(.rect) + TOL) ) ][0] // null );

# ── (HISTORICAL) _target_cell / _span_anchors_both_faces — S14a's SINGLE-cell ──
# locator + WF (1a) span guard. GENERALIZED in S18-span to _span_block /
# _span_anchors_block_faces (the N-cell span; N=1 reduces to these byte-identically),
# which insert_line now calls exclusively. The single-cell defs were removed as dead
# code after the generalization; revert = git history (the whole span-insert pre-slice
# reverts by deletion). See the SPAN-INSERT header below for the lineage.

# ── _sides_form_rectangle: |sides|==2 AND equal perpendicular extent ──────────
# The remove precondition. The two incident sides (A::incident output, WHOLE
# cells) must be EXACTLY 2 and share their perpendicular extent so the fused
# region is a rectangle, not an L. For a removed "v" line the two sides abut
# left/right of the gridline → they must share min_y AND max_y; for "h" → min_x
# AND max_x. Pure coordinate compares against incident's already-derived frames.
def _sides_form_rectangle($sides; $seg):
  if ($sides | length) != 2 then false
  else
    ($sides[0].frame) as $a | ($sides[1].frame) as $b
    | if $seg.axis == "v"
      then (G::fabs(G::frame_min_y($a) - G::frame_min_y($b)) <= TOL)
           and (G::fabs(G::frame_max_y($a) - G::frame_max_y($b)) <= TOL)
      else (G::fabs(G::frame_min_x($a) - G::frame_min_x($b)) <= TOL)
           and (G::fabs(G::frame_max_x($a) - G::frame_max_x($b)) <= TOL)
      end
  end;

# ── _gate: the single closure-by-rejection point — A::valid_rec, WHOLE store ──
# valid_rec's first arg is the WHOLE candidate STORE (it reads .segments/.bindings
# off the store — a bare-array call ERRORS). Defence-in-depth behind the cheap
# structural guards each op runs first.
def _gate($candidate; $NT):
  (A::valid_rec($candidate; $NT)) as $v
  | if $v.ok then { ok: true, arr: $candidate }
    else { ok: false, reason: "valid_rec rejected: \($v | { bad_pd: [ .per_display[] | select(.ok | not) ], bad_nested: ((.nested // []) | map(select(.ok | not))) })" }
    end;

# ─────────────────────────────────────────────────────────────────────────────
# THE PROMOTION RELATION (S14b) — promote / demote, the label ops (spec §6.1 P-PROMOTE).
#
# promote/demote are the FOURTH/FIFTH generating primitives, the ONE genuinely-new
# SCHEMA addition: they author/remove a `promotions` record encapsulating a rectangular
# block of cells into one parcel (or dissolving it). The parcel TREE is DERIVED from
# `promotions` by A::derive_nested (arrangement.jq) — promote is a PURE LABEL op: it
# appends a record and touches NOTHING ELSE (.segments/.bindings/.off_top carried
# verbatim), which is why it is trivially INV-preserving on the segment bag and why
# demote∘promote == identity BYTE-EXACT on the WHOLE store (append-tail / filter-by-id,
# neither op re-sorting — the lineops.jq:70-78 inverse-pair discipline VERBATIM, and
# STRONGER than insert/remove which mutate one segment's id field).
#
# INPUT = a CELL-ANCHOR SET ["<did>:<i0>:<j0>"] — the depth-0 _anchor_key strings of
# the flat cells to encapsulate. NOT a line-ID line_set (S14a stamps ids only on
# INSERTED segments; golden/bridge/from_floorplan bags are entirely id-less pre-S15, so
# a line-ID set is unaddressable) and NOT a raw rectangle (geometry-match ambiguity).
# Cell anchors are ALWAYS derivable (A::cells_md / _anchor_key mint them unconditionally).
# The line_set is DERIVED from the cells — preserving the spec §6.1 promote(line_set)
# intent pre-S15.
#
# THE PROMOTIONS RECORD: { id, region:[cell_keys], line_set:[<interior segment objects,
# verbatim GEOMETRY>], coord_map:<block bbox {x,y,w,h}> }. line_set is GEOMETRY not
# line-IDs (robust pre-S15 — those ids don't exist on id-less bags). `region` (the
# cell-anchor set) is stored ALONGSIDE coord_map because pre-S15 the promotion re-finds
# its block by GEOMETRY each derivation (derive_nested reads coord_map, not region).
# coord_map IS the spec §1.3 irreducible payload — the only datum derive_nested needs to
# re-enter the child space (interior segs already absolute over coord_map == the parent
# cell.frame, NO transform). S15 collapses `region` into a bounding-line-ID key once
# line-set identity is load-bearing — flag for the S15 migration (fixtures-only, no
# persisted production promotions exist).
#
# THE RECTANGLE PRECONDITION (spec §6.1 pre, §10.9): the chosen cells must tile a FILLED
# RECTANGLE. TWO teeth, the S14a guard-then-_gate posture: TOOTH 1 (load-bearing) is the
# EXACT integer area-tile (sum-of-cell-areas == bbox-area — filled components have
# disjoint bboxes so equality holds IFF the block exactly tiles $R, no gap/overlap; exact
# int arithmetic on rounded frames, no float δ cancellation) — this is the §10.9 reject
# (an L-block / partial pinwheel has sum_area < bbox_area). TOOTH 2 (defence-in-depth) is
# A::valid over the interior sub-bag. valid_rec ALONE is INSUFFICIENT (a non-rectangular
# block silently re-merges to a coarser-but-valid cell), so the STRUCTURAL guard is
# load-bearing — the SAME posture as S14a's span/rectangle guards.
#
# THE GATE validates the DERIVED nested tree: promote/demote run _gate_rec =
# A::valid_rec(A::derive_nested($candidate;$NT);$NT), so closure-by-rejection (§6.4)
# reaches INTO the nested bindings as defence-in-depth behind the structural guards.
# ─────────────────────────────────────────────────────────────────────────────

# ── _next_promotion_id: the monotone synthetic promotion-id counter, store-scoped ──
# Mirrors _next_line_id (the lineops.jq:97-98 pattern); APPEND-to-tail so demote-by-filter
# round-trips byte-exact. promotions defaults [] (S10) → zero-promotion byte-identity.
def _next_promotion_id($arr):
  1 + (([ ($arr.promotions // [])[].id // 0 ] | max) // 0);

# ── _block_rect: the union bounding rect (coord_map) of the named cells' frames ──
def _block_rect($cells):
  ([ $cells[] | G::frame_min_x(.frame) ] | min) as $x0
  | ([ $cells[] | G::frame_max_x(.frame) ] | max) as $x1
  | ([ $cells[] | G::frame_min_y(.frame) ] | min) as $y0
  | ([ $cells[] | G::frame_max_y(.frame) ] | max) as $y1
  | { x: $x0, y: $y0, w: ($x1 - $x0), h: ($y1 - $y0) };

# ── _block_cells: the named cells, located in the HOME bag's cells_md partition ──
def _block_cells($arr; $T; $cell_keys):
  [ A::cells_md(($arr.segments // []); $T)[]
    | select(A::_anchor_key(.) as $k | any($cell_keys[]; . == $k)) ];

# ── _is_filled_rectangle: the promote precondition + the promotion-validity check ──
# Composes A::valid / A::cells_md VERBATIM over the sub-region — zero forked union-find.
def _is_filled_rectangle($arr; $T; $cell_keys):
  (_block_cells($arr; $T; $cell_keys)) as $blk
  | if ($blk | length) == 0 then false
    else
      _block_rect($blk) as $R
      | ([ ($arr.segments // [])[] | select(A::_seg_interior_to(.; $R)) ]) as $inner
      | (($blk | map((.frame.w // 0) * (.frame.h // 0)) | add) == ($R.w * $R.h)) as $exact_cover
      | (A::valid($inner; $R).ok) as $v_ok
      | ($exact_cover and $v_ok)
    end;

# ── _gate_rec: the closure-by-rejection point for promote/demote — over the DERIVED tree ──
# valid_rec on the NESTED view A::derive_nested produces, so closure reaches INTO the
# nested bindings (defence-in-depth behind the structural rectangle guards).
def _gate_rec($candidate; $NT):
  (A::valid_rec(A::derive_nested($candidate; $NT); $NT)) as $v
  | if $v.ok then { ok: true, arr: $candidate }
    else { ok: false, reason: "valid_rec(derive_nested) rejected: \($v | { bad_pd: [ .per_display[] | select(.ok | not) ], bad_nested: ((.nested // []) | map(select(.ok | not))) })" }
    end;

# ── promote (P-PROMOTE): encapsulate a rectangular block of cells into one parcel ──
def promote($arr; $T; $cells):
  (P::norm_topology($T)) as $NT
  | ($cells // []) as $cell_keys
  | (_block_cells($arr; $NT; $cell_keys)) as $blk
  | if ($blk | length) == 0
    then { ok: false, reason: "promote: no cells match the anchor set \($cell_keys) in the partition" }
    else
      (_block_rect($blk)) as $R
      # degenerate double-promotion: an existing promotion already encapsulates this exact bbox.
      | if any(($arr.promotions // [])[]; (.coord_map.x == $R.x) and (.coord_map.y == $R.y) and (.coord_map.w == $R.w) and (.coord_map.h == $R.h))
        then { ok: false, reason: "promote: block \($cell_keys) (bbox \($R)) is already promoted (degenerate double-promotion)" }
        elif (_is_filled_rectangle($arr; $NT; $cell_keys) | not)
        then { ok: false, reason: "promote: block \($cell_keys) is not a filled rectangle (sum_area != bbox_area → non-rectangular / pinwheel cannot be partially encapsulated, §10.9)" }
        else
          ([ ($arr.segments // [])[] | select(A::_seg_interior_to(.; $R)) ]) as $line_set
          | ({ id: _next_promotion_id($arr), region: $cell_keys, line_set: $line_set, coord_map: $R }) as $rec
          | ($arr | .promotions = ((.promotions // []) + [$rec])) as $candidate
          | _gate_rec($candidate; $NT)
        end
    end;

# ── demote (the promote inverse): remove the promotion record by id ───────────
# A NO-OP on STORAGE: the interior lines were NEVER moved out of .segments (promote
# only APPENDED a label record; the relocation is a per-VIEW operation done by
# derive_nested, never on the stored bag). So demote just removes the label and the
# next derive_nested sees the lines flat again ("re-express the child's lines in the
# parent's space", spec §6.1 — a no-op on storage because they were never relocated).
# FILTER-BY-ID, NO re-sort → demote∘promote == identity BYTE-EXACT on the WHOLE store
# (promote appends one record to the .promotions tail and touches nothing else; demote
# filters that record by id and touches nothing else; neither re-sorts). _gate_rec is a
# valid_rec(derive_nested) backstop — store intact on reject.
def demote($arr; $T; $promotion_id):
  (P::norm_topology($T)) as $NT
  | ( [ ($arr.promotions // [])[] | select(.id == $promotion_id) ] | length ) as $hits
  | if $hits == 0 then { ok: false, reason: "demote: no promotion with id \($promotion_id)" }
    else
      ($arr | .promotions = [ (.promotions // [])[] | select(.id != $promotion_id) ]) as $candidate
      | _gate_rec($candidate; $NT)
    end;

# ─────────────────────────────────────────────────────────────────────────────
# THE UNIVERSAL CONTENTS OP (S16, R2) — rebind, the FIFTH generating primitive
# (spec §6.1 P-BIND). A leaf cell's `contents` z-list IS the universal stack: a
# tiled window is a 1-stack, a multi-window stack is a deep contents. rebind
# attaches/detaches a window descriptor to/from a cell's contents HEAD (the top) —
# making the multi-window stack the universal container, NOT a bolted-on special
# case (the present/hide authority is uniformly contents[0] present / contents[1..]
# off-top, A::arrangement_targets_rec's S16 arm).
#
# INPUT = a depth-0 CELL-ANCHOR key "<did>:<i0>:<j0>" (the SAME id-less-safe input
# promote takes, lineops.jq:183) — NOT a line-set (S15 ids are not load-bearing for
# cell keying pre-promotion) and NOT a raw rectangle. The descriptor is a binding
# { window_id, presented, frame, … } or null (detach/unbind).
#
# Z-ORDER (the B::valve-authority rule): contents[0] is the presented top.
#   ATTACH  : push the descriptor onto the HEAD (newest-on-top — the reveal
#             semantics); prior members demote one z-rank.
#   DETACH/UNBIND (descriptor null): pop the HEAD; the top retargets to the new
#             contents[0].
#   EMPTY   : a fully-unbound cell becomes a RESERVED SLOT { reserved:true,
#             contents:[] } — the OCC reserved-slot bucket (the operator's
#             placeholder feature), window_id ABSENT so A::arrangement_targets_rec
#             emits NO target (mirrors project's vacant leaf, parcel.jq:310), yet the
#             partition still sees ONE cell tiling its rect.
#
# rebind is NOT a byte-exact inverse-pair like insert/remove — ATTACH prepends a
# FRESH top, so attach∘detach byte-restores ONLY a detach-of-what-was-just-attached
# (push-head/pop-head, no re-sort). Documented, not relied upon.
#
# CRITICAL: rebind NEVER decides the valve fold's z-order. The fold's top/surplus
# come from B::valve's facts (A::bridge_arrangement_folded reads them), NEVER from
# rebind's head/tail convention — re-deriving WHICH members fold here would be a
# forked valve (the #1 hazard).
#
# INV (the partition invariant): rebind edits ONE binding's contents z-list (+ the
# bare top fields) and touches NOTHING in .segments / .promotions / .bindings[k].nested
# — so A::valid_rec (which reads .segments + .nested ONLY, never .contents) is
# INVARIANT under rebind BY CONSTRUCTION. _gate (A::valid_rec, WHOLE store) is the
# uniform lineops defence-in-depth posture — a no-op assertion on a contents-only
# edit (the structural argument, not valid_rec, is the teeth). OCC stays SEPARATE
# (B::conservation + project's vacant set, never folded into valid_rec).
#   OCC ORACLE, honestly: B::conservation is the ENGINE'S tree-side silent-drop net
#   (it takes a TREE — valve+project — not an arrangement store), so it is the OCC
#   authority once rebind composes into a live settle (S18). In the rebind TEST seam
#   (a store, no tree) OCC is checked store-side by the fixtures' LITERAL per-step
#   managed-window SETS (attach→{…+w}, detach→{…−top}, unbind→reserved) — those
#   literal sets are the teeth (a wrong rebind that drops/mis-buckets a window
#   mismatches them); the harness `_occ` ok flag is a within-store self-consistency
#   check, NOT an independent silent-drop detector (that is B::conservation's job).
#
# INTERIOR-cell reject: a cell whose nested.segments is non-empty is a PARCEL, not a
# leaf z-stack — rebind rejects it (reusing the EXACT *_rec interior predicate
# (nested.segments|length)>0, arrangement.jq:1212/1240/1277) so a rebind cannot
# corrupt a nested parcel.
def rebind($arr; $T; $cell_key; $descriptor):
  (P::norm_topology($T)) as $NT
  | (($arr.bindings // {})[$cell_key]) as $entry
  | ((($entry.nested.segments // []) | length) > 0) as $interior
  | if ($entry == null and $descriptor == null)
      then { ok: false, reason: "rebind: no cell \($cell_key) and null descriptor (nothing to unbind)" }
    elif $interior
      then { ok: false, reason: "rebind: \($cell_key) is an interior parcel (nested.segments non-empty), not a leaf z-stack" }
    else
      ( ($entry.contents)
        // (if $entry == null then [] else [ ($entry | del(.contents) | del(.nested)) ] end) ) as $z   # the 1-deep default = the bare binding
      | ( if $descriptor != null
          then ([ $descriptor ] + $z)     # ATTACH: push onto the HEAD (new top); prior members demote
          else ($z[1:]) end ) as $z2      # DETACH/UNBIND: pop the head; top retargets to new $z2[0]
      | ( if ($z2 | length) == 0
          then { reserved: true, contents: [] }     # EMPTY → RESERVED SLOT (OCC); window_id ABSENT → emits no target
          else ($z2[0] + { contents: $z2 })         # top binding's bare fields mirror contents[0] (the S10 shape, generalized)
          end ) as $entry2
      | ($arr | .bindings = ((.bindings // {}) | .[$cell_key] = $entry2)) as $candidate
      | _gate($candidate; $NT)                       # valid_rec, WHOLE store; partition untouched ⇒ trivially ok
    end;

# ── swap (P-SWAP): exchange the contents z-lists of two leaf cells ──────────────
# The arrangement analogue of ops.jq's op_swap_leaf — but a SIDE-TABLE value
# exchange, not a children-array reorder: the .segments partition is UNTOUCHED, so
# each window simply ADOPTS the other cell's frame on the next settle's re-stamp
# (bridge_arrangement_native re-projects bound frames from the partition). A
# CONTENTS-only op like rebind, so it adds ZERO clamp/min-size arithmetic (the #1
# hazard; valid_rec is INVARIANT under it by construction — it reads .segments/.nested
# only, never .contents).
#
# Both cells must EXIST and be LEAF z-stacks (reuse rebind's interior reject, the EXACT
# (nested.segments|length)>0 predicate). Carries the full contents list + the bare top
# fields (window_id/presented/frame), so a STACKED cell swaps as a unit. A reserved hole
# ({reserved:true,contents:[]}) is a valid swap participant (its "window" is absence —
# swapping IT relocates the hole, which is coherent). Same-cell swap (a==b) is a no-op
# reject (nothing to trade).
def swap($arr; $T; $cell_a; $cell_b):
  (P::norm_topology($T)) as $NT
  | (($arr.bindings // {})[$cell_a]) as $ea
  | (($arr.bindings // {})[$cell_b]) as $eb
  | if $cell_a == $cell_b then { ok: false, reason: "swap: same cell \($cell_a) (nothing to trade)" }
    elif ($ea == null) then { ok: false, reason: "swap: no cell \($cell_a)" }
    elif ($eb == null) then { ok: false, reason: "swap: no cell \($cell_b)" }
    elif ((($ea.nested.segments // []) | length) > 0) then { ok: false, reason: "swap: \($cell_a) is an interior parcel, not a leaf z-stack" }
    elif ((($eb.nested.segments // []) | length) > 0) then { ok: false, reason: "swap: \($cell_b) is an interior parcel, not a leaf z-stack" }
    else
      # exchange the WHOLE entries (contents + bare top fields), but the anchor KEY
      # carries the cell GEOMETRY (frame) — which must STAY with the cell, not the
      # window. So re-stamp each swapped entry bare frame from the DESTINATION cell prior
      # frame; the next settle re-projects from .segments regardless, so this only keeps
      # the immediate pre-settle view coherent (mirrors insert.sh sync re-stamps the
      # frame, the lineops.jq:126 note).
      # NOTE: this restamps only the wrapper .frame, NOT contents[0].frame — which is left
      # at its old (source-cell) value. Callers whose result must satisfy the transactional
      # arrangement validator (contents[0].frame == .frame, wm_core_transaction_migration.jq:197)
      # must refresh the binding frames after this op (proposal authors do so via
      # _proposal_arrangement_refresh_binding_frames). The op's own descriptor-swap logic is
      # intentionally left frame-agnostic on contents.
      ($arr | .bindings = ((.bindings // {})
        | .[$cell_a] = ($eb | (if has("frame") then .frame = ($ea.frame) else . end))
        | .[$cell_b] = ($ea | (if has("frame") then .frame = ($eb.frame) else . end)))) as $candidate
      | _gate($candidate; $NT)
    end;

# ─────────────────────────────────────────────────────────────────────────────
# SPAN-INSERT (S18-span, the PURE pre-slice) — insert_line GENERALIZED to a line
# spanning N ADJACENT cells along a shared gridline (spec §6.1 P-INSERT generalized).
#
# S14a's insert_line splits ONE cell into two (its span guard required the new line's
# span == ONE cell's perpendicular extent, anchoring that cell's two bounding faces).
# SPAN-INSERT inserts a line spanning a CONTIGUOUS RUN of N cells along a shared
# gridline: the line's endpoints anchor on the OUTER faces of the N-cell block and it
# CROSSES the interior perpendicular gridlines — authoring a T-JUNCTION (a window spanning
# N adjacent cells, the pure core of the operator's `hyper+u` insert-spanning-N). This is
# the genuinely-new authoring PRIMITIVE S14a's insert_line cannot reach: insert_line
# requires EXACTLY ONE target cell, so a span across N cells is structurally rejected by it
# (verified). The store HOLDS the result (A::valid_rec ok) and A::cells_rec DERIVES it.
#
# HONEST SCOPE — NOT a non-slicing-reach proof (corrected after adversarial review):
# a T-junction authored by ONE span-insert from a VALID slicing base is itself SLICING /
# BSP-EXPRESSIBLE — from_floorplan CAN bridge it (the shipped arrangement/equiv_t_junction.json
# proves exactly this; a guillotine test reports is_slicing:true; a split-segment bag derives
# the identical partition). The genuinely NON-SLICING shape is the 4-arm pinwheel CYCLE, which
# (as the plan adjudicated) is NOT reachable by a single valid_rec-gated span-insert from a
# valid base — it needs the MULTI-OP gesture composition (the live S18, deferred). So
# span-insert's value is the N-cell-span authoring op, NOT an expressiveness keystone; the
# held-state non-slicing proof stays arrangement_valid/pinwheel.json (S1).
#
# ONE OP, NOT A SIBLING. insert_line is GENERALIZED — _target_cell + _span_anchors_both_faces
# become _span_block + _span_anchors_block_faces; the segment append + id stamp + _gate are
# VERBATIM (the apply verb-switch is unchanged). The N=1 case provably REDUCES to S14a
# byte-identically (a 1-cell block: bbox == cell, span-axis outer-faces == both-faces, the
# area-tile is cell_area==cell_area trivially) — so generalizing costs zero new harness arm,
# zero new apply verb, and the single-cell split corpus (insert_line_split_ok /
# insert_line_bad_span_reject / insert_remove_roundtrip) stays byte-green by construction.
#
# THE TEETH (closure-by-rejection, the S14a posture VERBATIM): two STRUCTURAL conjuncts run
# BEFORE any candidate, then _gate(A::valid_rec) as defence-in-depth. valid_rec CANNOT be the
# teeth — a dangling/ragged span is silently re-merged by the atom-grid union-find to a
# coarser-but-VALID partition (the lineops.jq:29-43 finding) — so the guards are load-bearing:
#   (1) _span_block empty (coord on a face / no crossed cell)        → reject.
#   (2) span does NOT anchor the block's two OUTER faces on the span axis → reject.
#   (3) the block's crossed cells do NOT exactly tile their bbox (ragged/non-contiguous run,
#       sum_cell_area != bbox_area, EXACT integer — promote's §10.9 tooth lineops.jq:244)
#       → reject. Disjoint filled cell-bboxes ⇒ sum==bbox IFF a gapless contiguous run.
# The N-cell span is NOT a byte-exact inverse of remove_line (a T-junction line's incident
# count is >2, which _sides_form_rectangle rejects) — the N-cell inverse is a multi-line
# remove, deferred to the gated S18 remainder. NO round-trip is asserted for the N-cell span.
#
# ── _span_block: the contiguous run of cells the line at ($axis,$coord) crosses ─
# whose SPAN-axis extent ⊆ [$span.lo,$span.hi]. The N-cell generalization of _target_cell,
# composing A::cells VERBATIM. For an "h" line the SPLIT (perpendicular) axis is y (the line
# cuts each crossed cell's y-extent → the cell's y-extent must STRICTLY contain $coord) and
# the SPAN axis is x (the line runs along x → the crossed cell's x-extent must lie within
# [$span.lo,$span.hi]); mirrored for "v" (split axis x, span axis y). An empty list = reject
# (coord on a face / no cell crossed / no cell within the span). N=1 reduces to _target_cell.
def _span_block($segs; $cv; $axis; $coord; $span):
  [ A::cells($segs; $cv)[]
    | .frame as $f
    | if $axis == "v"
      then select((G::frame_min_x($f) + TOL < $coord) and ($coord < G::frame_max_x($f) - TOL))
           | select((G::frame_min_y($f) >= $span.lo - TOL) and (G::frame_max_y($f) <= $span.hi + TOL))
      else select((G::frame_min_y($f) + TOL < $coord) and ($coord < G::frame_max_y($f) - TOL))
           | select((G::frame_min_x($f) >= $span.lo - TOL) and (G::frame_max_x($f) <= $span.hi + TOL))
      end ];

# ── _span_anchors_block_faces: the N-cell span guard — ZERO clamp/min/feasibility ──
# Two conjuncts of pure coordinate algebra over the block (_block_rect lineops.jq:224 gives
# the union bbox):
#   (1) ANCHOR: $span [lo,hi] == the block bbox OUTER faces on the SPAN axis (±TOL). For "h"
#       the span axis is x (block x-faces {$R.x, $R.x+$R.w}); for "v" the span axis is y.
#   (2) AREA-TILE (contiguity): sum(block cell area) == bbox area, EXACT integer (promote's
#       §10.9 tooth lineops.jq:244 VERBATIM). Filled cells have disjoint bboxes ⇒ equality
#       holds IFF the block exactly tiles its bbox with no gap — a skipped/ragged cell fails.
# The N-cell generalization of _span_anchors_both_faces; for N=1 (bbox == the one cell) it
# reduces to it (span-axis outer faces == that cell's both faces, area-tile == cell_area
# trivially). ZERO clamp / min-size / feasibility — the SAME algebra class as the S14a guard.
def _span_anchors_block_faces($blk; $axis; $span):
  (_block_rect($blk)) as $R
  | (if $axis == "h"
     then (G::fabs($R.x - $span.lo) <= TOL) and (G::fabs(($R.x + $R.w) - $span.hi) <= TOL)
     else (G::fabs($R.y - $span.lo) <= TOL) and (G::fabs(($R.y + $R.h) - $span.hi) <= TOL)
     end)
    and (([ $blk[] | (.frame.w // 0) * (.frame.h // 0) ] | add) == ($R.w * $R.h));

# ── insert_line (P-INSERT, span-generalized): split a CONTIGUOUS RUN of N cells ──
# spanning a shared gridline (N=1 byte-identical to the S14a single-cell split). The append
# + id stamp + _gate are the S14a body VERBATIM; only the target locator + span guard are
# generalized (_target_cell → _span_block, _span_anchors_both_faces → _span_anchors_block_faces).
def insert_line($arr; $T; $axis; $coord; $span; $relation):
  (P::norm_topology($T)) as $NT
  | ({ axis: $axis, coord: $coord, lo: $span.lo, hi: $span.hi }) as $probe
  | (_home_bag(($arr.segments // []); $NT; $probe)) as $bag
  | if $bag == null then { ok: false, reason: "insert_line: line homes to no display" }
    else
      (_span_block($bag.segments; $bag.rect; $axis; $coord; $span)) as $blk
      | if ($blk | length) == 0
        then { ok: false, reason: "insert_line: coord \($coord) lands on a face / no cell crossed within span on axis \($axis)" }
        elif (_span_anchors_block_faces($blk; $axis; $span) | not)
        then { ok: false, reason: "insert_line: span [\($span.lo),\($span.hi)] does not anchor the block's outer faces / the spanned cells are not a contiguous gapless run on axis \($axis)" }
        else
          ( { axis: $axis, coord: $coord, lo: $span.lo, hi: $span.hi, id: _next_line_id($arr) }
            + (if $relation == "free" then {} else { relation: $relation } end) ) as $seg
          | ($arr | .segments = ((.segments // []) + [$seg])) as $candidate
          | _gate($candidate; $NT)
        end
    end;

# ─────────────────────────────────────────────────────────────────────────────
# SIGN-OFF #3 (spec §10.6) — promotion invalidation, REJECT-by-default (S14b).
#
# A remove_line that touches a promoted region (its line is INTERIOR-to or ON-A-FACE-of
# a promotion's coord_map) is REJECTED via a STRUCTURAL guard spliced into remove_line
# BEFORE _gate — NOT delegated to valid_rec. The reject-by-default ruling: a promotion's
# block structure is frozen; to edit lines inside it the operator must DEMOTE first
# (dissolving the label), then re-promote. This keeps the promotion's line-set a
# guaranteed filled rectangle — a removal cannot silently un-rectangle it.
#
# WHY STRUCTURAL, NOT valid_rec-delegated (the load-bearing finding, verified):
#  (1) An un-rectangling removal SILENTLY re-merges to a coarser-but-VALID cell with
#      valid_md.ok==true (the documented L-fuse silent-collapse pathology, lineops.jq:29-43,
#      now promotion-aware), so valid_rec(derive_nested) CANNOT catch it.
#  (2) A::valid over the residual interior ALSO under-detects: a dangling interior line
#      over an otherwise-empty region union-finds to ONE valid cell (verified: a T-stem
#      v@500[0,500] left over a 1000-square reads ok:true), so a re-run-valid check is
#      not reliable teeth either. The HONEST, constructible structural rule is therefore
#      "you cannot edit a line inside/bounding a promotion" — checked geometrically.
#
# WHY BEFORE _sides_form_rectangle (the constructibility correction to the design prose):
#  the locked design framed the "unique teeth" as interior-line removals S14a ALLOWS
#  (|incident|==2) that nonetheless un-rectangle a promotion. EMPIRICALLY that case is
#  NOT CONSTRUCTIBLE: for removing line X to orphan another line Y, Y must terminate ON X
#  (a T-junction) ⇒ X has a cell corner there ⇒ |incident(X)| ≥ 3 ⇒ S14a's
#  _sides_form_rectangle ALREADY rejects X (verified: the T-crossbar h@500 removal reds
#  with incident=3). So an elif AFTER _sides_form_rectangle would be DEAD on the true arm.
#  Placing the guard FIRST makes it LIVE: it rejects the promotion-touching removal with a
#  promotion-aware reason (demote-first), BEFORE S14a's generic L-fuse reason. The
#  SECOND case — removing an EXTERIOR line not touching any promotion — falls through the
#  guard and proceeds through S14a verbatim.
#
# Reuses A::_seg_interior_to (the SAME interior predicate derive_nested + promote use) +
# a face-coincidence check — zero forked geometry. On reject the store (segments AND
# promotions) is LEFT INTACT (jq purity, lineops.jq:24-27).

# _seg_on_face: $seg coincides with one of $R's four faces (so removing it touches the
# promotion's bounding box even if it is not strictly interior).
def _seg_on_face($seg; $R):
  if $seg.axis == "v"
  then (G::fabs($seg.coord - $R.x) <= TOL) or (G::fabs($seg.coord - ($R.x + $R.w)) <= TOL)
  else (G::fabs($seg.coord - $R.y) <= TOL) or (G::fabs($seg.coord - ($R.y + $R.h)) <= TOL)
  end;

# _removal_breaks_promotion: true iff removing $seg touches ANY promotion's coord_map —
# i.e. $seg is strictly interior-to OR coincident-with-a-face-of a promoted region. The
# reject-by-default structural condition (edit inside a promotion ⇒ demote first). An
# EXTERIOR line (touching no promotion) returns false and the removal proceeds.
def _removal_breaks_promotion($arr; $line_id; $seg; $T):
  any( ($arr.promotions // [])[];
       . as $p
       | (A::_seg_interior_to($seg; $p.coord_map) or _seg_on_face($seg; $p.coord_map)) );

# ── remove_line (P-MERGE): fuse two rectangle-forming sides, elect a survivor ──
def remove_line($arr; $T; $line_id):
  (P::norm_topology($T)) as $NT
  | ( [ (($arr.segments // []) | to_entries[]) | select(.value.id == $line_id) ][0] // null ) as $hit
  | if $hit == null then { ok: false, reason: "remove_line: no segment with id \($line_id)" }
    else
      ($hit.value) as $seg
      | (_home_bag(($arr.segments // []); $NT; $seg)) as $bag
      | if $bag == null then { ok: false, reason: "remove_line: segment homes to no display" }
        else
          # incident derives sides over the SINGLE bag, so its cells are display-0-tagged
          # locally; tag each with the home bag's display_id (the SAME `. + {display_id}`
          # cells_md applies) so A::_anchor_key produces the store's display-qualified key.
          ( [ A::incident($bag.segments; $bag.rect; $seg)[] | . + { display_id: $bag.display_id } ] ) as $sides
          | if (($arr.promotions // [] | length) > 0 and _removal_breaks_promotion($arr; $line_id; $seg; $NT))
            then { ok: false, reason: "remove_line: rejected — line is inside/bounding a promoted region (would un-rectangle its line-set; demote first to dissolve) [sign-off #3]" }
            elif (_sides_form_rectangle($sides; $seg) | not)
            then { ok: false, reason: "remove_line: L-fusing removal rejected (incident=\($sides | length), unequal perpendicular extent → non-rectangle)" }
            else
              # SURVIVOR ELECTION — the shipped P::descriptor_specificity ladder VERBATIM.
              # Records the kept binding + drops the loser; re-keying onto the new anchor is S15.
              ( [ $sides[0], $sides[1] ]
                | map({ cell_id: (A::_anchor_key(.)),
                        binding: (($arr.bindings // {})[A::_anchor_key(.)].binding // {}) })
                | sort_by([ (0 - P::descriptor_specificity(.binding // {})),
                            (.binding.ordinal // 1000000), .cell_id ])
                | .[0] ) as $survivor
              | ($survivor) as $_keep   # the elected binding (S15 re-keys it; S14a only records the election)
              # DROP-BY-INDEX (S15 id-uniqueness hardening): remove the ADDRESSED segment by its
              # to_entries INDEX ($hit.key), not select(.id != $line_id) which would drop ALL
              # id-matches. The monotone _next_line_id never stamps a duplicate, but a forged/
              # duplicate id must not be able to alias two cells onto ONE line-set key (T4
              # totality, spec §8.1) by silently dropping both sides — index removal makes the
              # primary-key guarantee TOTAL. Byte-exact on the inverse-pair (a single id-match
              # store removes the same element either way; the append-tail discipline holds).
              | ($arr | .segments = [ (.segments // []) | to_entries[] | select(.key != $hit.key) | .value ]) as $candidate
              | _gate($candidate; $NT)
            end
        end
    end;

# ─────────────────────────────────────────────────────────────────────────────
# THE BOUNDED LOCAL DRAG (S17, R-drag) — move_line, the SIXTH/FINAL generating
# primitive (spec §6.1 P-MOVE, §7). A DISCRETE move_line(δ) at the TEST/CLI seam:
# translate a line's coord by a clamped δ, RIDE every perpendicular endpoint that
# anchors on it (a span edit), and reflow the incident cells — a BOUNDED LOCAL
# SOLVE, not a global re-derive. S18 wires the continuous gesture; this is the
# pure op, the 6th arm of apply (joins insert/remove/promote/demote/rebind), SAME
# {ok,arr}/{ok:false,reason} envelope + _gate(A::valid_rec) backstop.
#
# WHY THIS IS A SCALAR EDIT, NEVER A TOPOLOGY EDIT (the INV-preserving spine):
# move_line maps each segment to itself-with-an-edited-scalar — it NEVER appends
# to / filters .segments (unlike insert/remove). So |segments| is invariant, every
# id survives, no axis flips, and a ridden endpoint stays anchored on L's new wire
# (M.lo == L_new.coord by construction) → no border goes partially-covered (the
# lineops.jq:29-43 silent-re-merge pathology is STRUCTURALLY avoided — it requires
# a DANGLING endpoint, which the ride prevents). valid_rec is therefore a no-op
# BACKSTOP on a clamped drag; the teeth are the clamp arithmetic + the ride
# keeping endpoints anchored, NOT valid_rec.
#
# THE BLAST RADIUS is bounded to the smallest enclosing parcel by THREE structural
# layers, all in shipped code: (1) _home_bag (per-display _bags exclusion — a
# segment on display 1 cannot reflow a cell on display 2); (2) the FLAT store +
# coord_map geometry (move_line edits the flat .segments; a promotion's interior
# lines stay flat — promote only appends a label, derive_nested is a per-VIEW
# relocation — so a child-interior drag's A::incident set is interior to coord_map,
# and a sibling cell with no face on L is never incident → carried verbatim); (3)
# INV preservation (a scalar coord/span edit cannot create a cross-parcel atom
# merge — that needs a covering segment added/removed).
#
# SIGN-OFF #1 (structural, spec §7.5/§10.4): the drag STICKS at the descendant's
# CURRENT min and does NOT invoke B::valve mid-gesture. lineops imports NO balance
# (lineops.jq:94-96 — only arrangement/parcel/geometry), so B::valve is structurally
# NEVER in the move path. The clamp reads each shrinking cell's CURRENT learned
# floor; when δ would push a min-bound cell past its floor, cδ stops the line flush
# AT the floor (never below). Freeing space by FOLDING is deferred to the NEXT
# settle (the S13 two-pass reads the stored arrangement and folds an infeasible
# node). The trade: bounded-and-predictable over free-space-by-folding.
# // DEFER: pinwheel fixpoint iteration (spec §10.3, §7.1). S17 ships slicing (depth-1)
# // + single-T (one anchored ride, one BFS layer) closed-form. The maximal pinwheel
# // (a ridden line's far endpoint on a THIRD interior line → 2nd hop + chain
# // re-convergence cycle) may need one fixpoint iteration of the LP — NOT implemented.
# // _translate_and_ride rides depth-1 anchored endpoints only; the single-pass min is
# // SOUND (never below min) but may UNDER-travel in a non-slicing cycle. The clamp
# // min-over-incident is already order-independent (the LP collapses to it for
# // slicing/single-T); the iterated solve is the deferred S18+ work.
# ─────────────────────────────────────────────────────────────────────────────

# ── _cell_min: the cell→binding→learned-floor min, composing P::subtree_min ───
# An incident cell's drag-axis floor. Looks up the cell's binding via A::_anchor_key
# (the SAME composition the fuse_check harness arm runs), pulls the leaf's learned
# min_size (binding.contents[0].min_size // binding.binding.min_size // binding.min_size
# — the minsize.jq bundle_id-keyed floor child_slots/project already read), builds a
# 1-leaf node-map, and composes P::subtree_min VERBATIM — ZERO forked min rule, ZERO
# hardcoded min constant. A VACANT / reserved / unbound cell has min_size {} → P::leaf_fit_min
# defaults each axis to 0 → {w:0,h:0}, ceding its whole extent (matching project's vacant
# leaf, parcel.jq:310). Returns {w,h}; the caller indexes by the drag axis.
def _cell_min($bag; $cell; $bindings):
  ((($bindings // {})[A::_anchor_key($cell)]) // null) as $entry
  | ( ($entry.contents[0].min_size)
      // ($entry.binding.min_size)
      // ($entry.min_size)
      // {} ) as $ms
  | ({ "c": { min_size: $ms } }) as $nodemap
  | P::subtree_min($nodemap; "c"; 0);

# ── _clamped_delta: the ONE order-independent solve (composes P::fit_sizes/subtree_min) ──
# cδ = sign(δ)·min(|δ|, room), where room = min over the SHRINKING-side incident cells
# of (size_on_drag_axis − _cell_min). The drag axis is PERPENDICULAR to L: a `v` line
# slides on x (shrinks cell WIDTH), an `h` line slides on y (shrinks HEIGHT). A +δ move
# pushes L's coord toward LARGER x/y, so the cell on the FAR side (its MIN-face on
# L.coord) SHRINKS and the NEAR side (its MAX-face on L.coord) grows; −δ is the mirror.
# So the clamp FILTERS A::incident to the shrinking side per sign(δ):
#   for v: δ>0 shrinks frame_min_x==coord cells; δ<0 shrinks frame_max_x==coord.
#   for h: δ>0 shrinks frame_min_y==coord cells; δ<0 shrinks frame_max_y==coord.
# room is ONE min over a DEDUPED set (A::incident dedups by cell — a re-converging shared
# cell contributes ONCE; min is commutative/associative/idempotent → order-independent).
# `(size − cell_min)` IS P::fit_sizes' donor-slack term (parcel.jq:197), and fit_sizes'
# Σmin>avail pass-through (parcel.jq:192) is the algebraic "sticks at min" witness — the
# clamp ROUTES through the same arithmetic, never re-codes a min dialect. NEVER calls
# B::valve (sign-off #1). cδ=0 when room is exhausted (sticks) or δ is a no-op.
def _clamped_delta_d($bag; $L; $delta; $bindings; $demote):
  ($L.coord) as $lc | ($L.axis) as $lax
  # The demote dialect (z-demotion Z-1): a shrinking cell whose ACROSS-the-line
  # (growing-side) neighbour was settle-stamped same-app contributes room down to
  # DEMOTE_EXTENT instead of its learned min — the divider rides past the floor
  # and the bridge authors the slide-under frame. The pushed face is the
  # neighbour's direction per axis+sign; $demote=false (every caller except the
  # single-line drag with the zdemote knob on) is byte-identical to the old clamp.
  | ( if $lax == "v" then (if $delta >= 0 then "left" else "right" end)
      else                (if $delta >= 0 then "above" else "below" end) end ) as $pface
  | (A::incident($bag.segments; $bag.rect; $L)) as $inc
  | ( [ $inc[] | . + { display_id: $bag.display_id }
        | .frame as $f
        | ( if $lax == "v"
            then (if $delta >= 0 then (G::fabs(G::frame_min_x($f) - $lc) <= TOL)
                                 else (G::fabs(G::frame_max_x($f) - $lc) <= TOL) end)
            else (if $delta >= 0 then (G::fabs(G::frame_min_y($f) - $lc) <= TOL)
                                 else (G::fabs(G::frame_max_y($f) - $lc) <= TOL) end)
            end ) as $shrinking
        | select($shrinking)
        | ( $demote
            and (((($bindings // {})[A::_anchor_key(.)] // {}).demotable_faces // [])
                 | index($pface)) != null ) as $demotable
        | ( if $lax == "v"
            then (($f.w // 0) - (if $demotable then DEMOTE_EXTENT else _cell_min($bag; .; $bindings).w end))
            else (($f.h // 0) - (if $demotable then DEMOTE_EXTENT else _cell_min($bag; .; $bindings).h end)) end ) ] ) as $rooms
  | (if ($rooms | length) == 0 then null else ($rooms | min) end) as $room
  # No shrinking cell on the drag side ⇒ the line is FLUSH at the canvas/parcel face there
  # (A::incident returns NO cell beyond the boundary — the prior assumption "always returns
  # the abutting cell" is FALSE at an edge). A flush line is BOUNDED by the face: it has ZERO
  # room to move further in that direction, so $r=0 (NOT $delta — letting it ride $delta would
  # escape off-canvas, and the δ<0 branch would sign-FLIP the direction; the segment would then
  # home to no display and be STUCK). This is the §7.4 "bounded to the enclosing parcel" floor.
  | (if $room == null then 0 else ([$room, 0] | max) end) as $r
  | (if $delta >= 0 then ([$delta, $r] | min) else ([$delta, (0 - $r)] | max) end);

# The historical 4-arg clamp — every caller except the demote-gated single-line
# drag (move_lines, the fixture harness's direct arm) routes here: demote=false
# is byte-identical to the pre-Z1 clamp.
def _clamped_delta($bag; $L; $delta; $bindings):
  _clamped_delta_d($bag; $L; $delta; $bindings; false);

# ── _translate_and_ride: translate L.coord by cδ + ride anchored perpendicular endpoints ──
# ONE pass over to_entries (index-stable by $hitkey, append-order preserved, NO re-sort —
# so cδ=0 round-trips BYTE-EXACT, the revert-clean/determinism floor). (1) TRANSLATE: L's
# coord += cδ. (2) RIDE: every perpendicular segment M (M.axis != L.axis) whose lo/hi
# coincides with L.coord (±TOL) has that endpoint += cδ — a SPAN edit (M.coord FROZEN, the
# endpoint stays on L's new wire → no dangling half-line, INV-preserving). (3) collinear /
# unanchored segments: carried verbatim. Rides DEPTH-1 anchored endpoints only (// DEFER the
# deeper pinwheel chain — a ridden line's far endpoint on a THIRD interior line).
def _translate_and_ride($segments; $hitkey; $L; $cd):
  # // DEFER: pinwheel fixpoint iteration (spec §10.3, §7.1) — this rides DEPTH-1
  # // anchored endpoints only; a ridden line's FAR endpoint on a THIRD interior
  # // line (a cycle through L) is NOT propagated. SOUND (never below min,
  # // valid_rec holds) but may UNDER-travel on a non-slicing pinwheel — the S18+ work.
  ($L.coord) as $lc | ($L.axis) as $lax
  | ($L.lo) as $llo | ($L.hi) as $lhi
  # SPAN-KEYED ride (colinear-run unification, 2026-06-13): a perpendicular M
  # rides ONLY when its coord falls within L's [lo,hi] span (±TOL) — i.e. M
  # structurally crosses THE MOVED SEGMENT, not merely any line sharing L's coord.
  # Coord-keyed riding (the prior `axis != lax` alone) over-rode an out-of-span
  # endpoint at the same coord (a colinear partner's stem in another region),
  # wrongly rejecting or corrupting a partial-line move. In-span junctions (every
  # shipped T/4-way fixture) are UNCHANGED — their stems lie within the span.
  | [ ($segments // []) | to_entries[] | .value as $s
      | if (.key == $hitkey) then ($s | .coord += $cd)
        elif (($s.axis != $lax)
              and (($llo - TOL) <= $s.coord) and ($s.coord <= ($lhi + TOL))) then
            ( (if (G::fabs($s.lo - $lc) <= TOL) then ($s | .lo += $cd) else $s end)
              | (if (G::fabs(.hi - $lc) <= TOL) then (.hi += $cd) else . end) )
        else $s end ];

# PARTITION-ONLY EDIT (the bound-window-frame staleness — verified, scoped): move_line
# edits the SEGMENT bag (coords/spans) and reflows the derived PARTITION (cells_rec); it
# does NOT re-project the bound windows' STORED .frame (in bindings/contents). So immediately
# after a move the bindings carry STALE frames — they refresh on the NEXT settle's P::project
# (the S13 derived-frame residual). Consequence: the arrangement_targets / derive_nested
# emitters READ those stored frames, so the IMMEDIATE window-keyed view of a moved store is
# stale, and derive_nested's frame-min-corner block re-home can DROP a bound window in a
# promoted region (its stale frame no longer matches a reflowed child cell) until the next
# settle re-homes it. Therefore: test the drag's geometry on the PARTITION (cells_rec), NOT
# the bound-window emission (move_line_bounded_to_parcel asserts via cells_rec for exactly
# this reason). Re-projecting frames live + the promoted-region bound-window survival is the
# S18 live-settle work (cross-ref the S13 residual); S17 is the pure discrete partition edit.
# ── move_line (P-MOVE): translate a line by a clamped δ, ride anchored endpoints ──
# move_line_d threads the z-demotion gate into the clamp (Z-1: the SINGLE-LINE
# drag is the only demote-admitted gesture — move_lines refuses, M6); the 4-arg
# move_line is the historical byte-identical face every other caller keeps.
def move_line_d($arr; $T; $line_id; $delta; $demote):
  (P::norm_topology($T)) as $NT
  | ( [ (($arr.segments // []) | to_entries[]) | select(.value.id == $line_id) ][0] // null ) as $hit
  | if $hit == null then { ok: false, reason: "move_line: no segment with id \($line_id)" }
    else ($hit.value) as $L
    | (_home_bag(($arr.segments // []); $NT; $L)) as $bag
    | if $bag == null then { ok: false, reason: "move_line: segment homes to no display" }
    else (_clamped_delta_d($bag; $L; $delta; ($arr.bindings // {}); $demote)) as $cd
       | (_translate_and_ride($arr.segments; $hit.key; $L; $cd)) as $segs2
       | ($arr | .segments = $segs2) as $candidate
       | _gate($candidate; $NT)
    end end;

def move_line($arr; $T; $line_id; $delta):
  move_line_d($arr; $T; $line_id; $delta; false);

# ── move_lines (J1, junction drag): the COMPOUND multi-line move ──────────────
# One gesture moves several lines — a v+h junction OR an N-entry same-axis
# colinear RUN (rigid). $moves = [{line_id, delta}, …]. Moves are GROUPED into
# runs by (axis, coord); composes the EXISTING internals per GROUP — _clamped_delta
# (each clamp reads the CURRENT segs, so a T-stem clamps over its post-ride
# geometry) then _translate_and_ride — in CANONICAL ORDER: v groups first, then
# h. A run's shared clamp is the MIN-magnitude member clamp (the tightest wall
# stops the whole run); a v+h junction is two size-1 groups, byte-identical. Stable
# within an axis. At a 4-way the per-axis clamps are independent and commute
# (the order-independence fixture pins it — the canonicalization also makes
# input order trivially irrelevant); at a T the crossbar-move can change the
# stem's incident set at the margins, so the canonical order makes that case
# DETERMINISTIC instead of reaching for a joint 2D solve. Per-axis stuck is a
# FEATURE (cδ=0 on one axis with the other moving = slide along the wall);
# EVERY-axis-stuck is a clean refusal (the caller's rc1 — nothing to author).
# F7 lives HERE (pure, both lines): any moved line interior-to or bounding a
# promoted region rejects before composing — a moved line would drift the
# region's coord_map and derive_nested would drop it on read (the same
# predicate gesture.sh's single-line drag checks shell-side). ONE _gate on the
# final store. Returns {ok, arr, applied: [{line_id, cdelta}, …]}.
def move_lines($arr; $T; $moves):
  (P::norm_topology($T)) as $NT
  | ($moves // []) as $mv
  | if ($mv | length) == 0 then { ok: false, reason: "move_lines: no moves" }
    else
      ( [ $mv[] | . as $m
          | ( [ ($arr.segments // [])[] | select(.id == $m.line_id) ][0] // null ) as $seg
          | $m + { axis: ($seg.axis // null), coord: ($seg.coord // null), lo: ($seg.lo // null), hi: ($seg.hi // null) } ] ) as $tagged
      | if any($tagged[]; .axis == null)
        then { ok: false,
               reason: "move_lines: no segment with id \([ $tagged[] | select(.axis == null) | .line_id ] | first)" }
        elif any($tagged[]; . as $m
               | ( [ ($arr.segments // [])[] | select(.id == $m.line_id) ][0] ) as $seg
               | any(($arr.promotions // [])[]; . as $p | (.coord_map) as $R
                     | ( A::_seg_interior_to($seg; $R)
                         or ( if $seg.axis == "v"
                              then (G::fabs($seg.coord - $R.x) <= TOL) or (G::fabs($seg.coord - ($R.x + $R.w)) <= TOL)
                              else (G::fabs($seg.coord - $R.y) <= TOL) or (G::fabs($seg.coord - ($R.y + $R.h)) <= TOL) end ) ) ))
        then { ok: false,
               reason: "move_lines: a line is inside/bounding a promoted region (a move would drift its coord_map; demote first) [F7]" }
        else
          # Group moves into RIGID RUNS by (axis, coord): colinear same-coord
          # entries share ONE clamped delta so the run stays straight (DL4). A
          # single v + single h = two size-1 groups → byte-identical to the old
          # per-entry path. Groups compose in canonical order (v then h); within a
          # group the parallel members clamp over the SAME pre-group segs (after
          # A1's span-keyed ride a run's members are span-disjoint, so they neither
          # perturb each other's clamp nor over-ride each other's perpendiculars).
          ( $tagged | group_by([.axis, .coord]) ) as $runs
          # RUN-CONTIGUITY GUARD (A3 adversarial finding): a multi-member
          # (axis,coord) group must tile a GAPLESS interval — else move_lines
          # would BEND the gridline into a staircase, a LEGAL partition valid_rec
          # CANNOT reject (so this structural guard is the only tooth, per the
          # closure-by-rejection thesis at the top of this file). Single-member
          # groups (every live v+h junction caller) pass trivially; completeness
          # vs an omitted span-adjacent partner is the resolver's job.
          | ( [ $runs[] | (sort_by(.lo)) as $g
                | select( any( range(0; (($g | length) - 1)); . as $i
                               | G::fabs(($g[$i+1].lo) - ($g[$i].hi)) > TOL ) )
                | { axis: $g[0].axis, coord: $g[0].coord } ] ) as $broken_runs
          | if ($broken_runs | length) > 0
            then { ok: false,
                   reason: "move_lines: a colinear run is non-contiguous (members leave a gap; pass the full contiguous run) [run-contiguity]" }
            else
          ( [ $runs[] | select(.[0].axis == "v") ] + [ $runs[] | select(.[0].axis == "h") ] ) as $ordered
          | ( reduce $ordered[] as $grp
              ( { segs: ($arr.segments // []), applied: [], err: null };
                if .err != null then .
                else
                  . as $st
                  | ( [ $grp[] | . as $m
                        | ( [ ($st.segs | to_entries[]) | select(.value.id == $m.line_id) ][0] // null ) as $hit
                        | { m: $m, hit: $hit } ] | sort_by(.m.line_id) ) as $members
                  | if any($members[]; .hit == null)
                    then $st | .err = "move_lines: id \([ $members[] | select(.hit == null) | .m.line_id ] | first) vanished mid-compose"
                    else
                      ( [ $members[] | .hit.value as $L
                          | (_home_bag($st.segs; $NT; $L)) as $bag
                          | if $bag == null then null
                            else _clamped_delta($bag; $L; .m.delta; ($arr.bindings // {})) end ] ) as $cds
                      | if any($cds[]; . == null)
                        then $st | .err = "move_lines: a segment in a run homes to no display"
                        else
                          # rigid: shared clamp = the MIN-magnitude member clamp
                          # (run members share a delta sign by contract; if any
                          # member is flush at cδ=0 the whole run sticks).
                          ( $cds | min_by(G::fabs(.)) ) as $cd
                          | reduce $members[] as $mem
                              ( $st;
                                .segs = _translate_and_ride(.segs; $mem.hit.key; $mem.hit.value; $cd)
                                | .applied += [ { line_id: $mem.m.line_id, cdelta: $cd } ] )
                        end
                    end
                end ) ) as $folded
          | if $folded.err != null then { ok: false, reason: $folded.err }
            elif all($folded.applied[]; (G::fabs(.cdelta)) <= 1e-6)
            then { ok: false,
                   reason: "move_lines: stuck (every line clamped to zero — flush at a min/face)",
                   applied: $folded.applied }
            else
              ($arr | .segments = $folded.segs) as $candidate
              | (_gate($candidate; $NT)) as $g
              | if $g.ok then { ok: true, arr: $g.arr, applied: $folded.applied }
                else $g end
            end
            end
        end
    end;

# ── colinear_run: the contiguous same-axis/same-coord chain containing $seg ────
# (colinear-run unification B1, DL3). Collects every segment sharing $seg's axis
# and coord (±TOL), groups them into maximal ABUTTING chains (sorted by lo), and
# returns the one chain that contains $seg. A lone segment with no colinear
# partner returns [$seg]; a same-coord segment in a DISJOINT (gapped) region is a
# different chain and is NOT included. This is the "run" a grab anywhere on a
# split gridline resolves to — move it as one (move_lines' rigid run).
def colinear_run($arr; $seg):
  ( [ ($arr.segments // [])[]
      | select((.axis == $seg.axis) and (G::fabs(.coord - $seg.coord) <= TOL)) ]
    | sort_by(.lo) ) as $cands
  | ( reduce $cands[] as $s ([];
        if (length == 0) then [[$s]]
        else (.[-1][-1]) as $prev
          | if (G::fabs($s.lo - $prev.hi) <= TOL)
            then (.[0:-1] + [ (.[-1] + [$s]) ])
            else (. + [[$s]]) end
        end ) ) as $chains
  | ( [ $chains[]
        | select( any(.[]; (G::fabs(.lo - $seg.lo) <= TOL) and (G::fabs(.hi - $seg.hi) <= TOL)) ) ][0]
      // [$seg] );

# ── line_at: the point → segment(s) hit-test (mouse-line-drag M0; run-aware B1) ─
# The geometric mirror of gesture.sh's face resolver: a point within $tol of a
# segment's coord (perpendicular distance) and inside its [lo,hi] span (±tol)
# hits it. Promotion-touching segments are EXCLUDED (the F7 un-grabbable rule —
# A::seg_touches_promotion, the SAME predicate the drag gate uses). The nearest v
# and h hit are each EXPANDED to their contiguous colinear RUN (colinear_run) —
# so grabbing ANYWHERE on a split gridline resolves the WHOLE run. kind:
# "junction" (both axes — a crossing; an arm may itself be a run), "run" (one
# axis, ≥2 members), "segment" (one axis, one member), "none". Hits are the v-run
# then the h-run, each sorted by lo (the move_lines canonical/contiguity order).
# Read-only — no ids minted.
def line_at($arr; $x; $y; $tol):
  ($arr.promotions // []) as $promos
  | ( [ ($arr.segments // [])[]
        | select(A::seg_touches_promotion(.; $promos) | not)
        | ( if .axis == "v"
            then { seg: ., dist: G::fabs($x - .coord),
                   inspan: ((.lo - $tol <= $y) and ($y <= .hi + $tol)) }
            else { seg: ., dist: G::fabs($y - .coord),
                   inspan: ((.lo - $tol <= $x) and ($x <= .hi + $tol)) } end )
        | select(.inspan and (.dist <= $tol)) ] ) as $cand
  | ( [ $cand[] | select(.seg.axis == "v") ] | sort_by(.dist) | (.[0] // null) | (if . == null then null else .seg end) ) as $vhit
  | ( [ $cand[] | select(.seg.axis == "h") ] | sort_by(.dist) | (.[0] // null) | (if . == null then null else .seg end) ) as $hhit
  | ( if $vhit == null then [] else [ colinear_run($arr; $vhit)[] | select(A::seg_touches_promotion(.; $promos) | not) ] end ) as $vrun
  | ( if $hhit == null then [] else [ colinear_run($arr; $hhit)[] | select(A::seg_touches_promotion(.; $promos) | not) ] end ) as $hrun
  | { kind: ( if ($vhit != null) and ($hhit != null) then "junction"
              elif (($vrun | length) > 1) or (($hrun | length) > 1) then "run"
              elif ($vhit != null) or ($hhit != null) then "segment"
              else "none" end ),
      hits: ( $vrun + $hrun ) };

# ── extend_run: grow a staged drop edge along its collinear run by ONE cell (follow-up #3) ──
# Given the CURRENT span (window ids — [target] on the first call), the staged $drop_side, and an
# extend $dir, append the next COLLINEAR-ABUTTING cell perpendicular to the drop face. The drop edge
# is the spanned cells' drop_side OUTER face (east→max_x, west→min_x, north→min_y, south→max_y); the
# run grows along the face axis (v-face → up/down, h-face → left/right). A neighbour qualifies iff:
# same display, its drop_side face is COLLINEAR (same coord ±TOL), it ABUTS the span's leading edge
# in $dir (±TOL), and it carries a window. STOPS (reason "runend") at a gap / non-collinear / an
# already-spanned cell / an empty cell / a shared divider that is PINNED (don't silently eat a sticky
# size) or PROMOTION-touching (the F7 un-grabbable rule). Rejects: empty span → "nospan"; $dir
# PARALLEL to the face → "perp". Returns { ok, reason, span_wids, span_box }. PURE — no mutation.
def extend_run($arr; $T; $span_wids; $drop_side; $dir):
  (A::cells_md(($arr.segments // []); $T)) as $cells
  | ($arr.bindings // {}) as $binds
  | ($arr.promotions // []) as $promos
  | ([ $span_wids[] as $w
       | ([ $binds | to_entries[] | select(((.value.contents[0].window_id) // .value.window_id) == $w) ][0].key) as $ak
       | ([ $cells[] | select(A::_anchor_key(.) == $ak) ][0]) | select(. != null) ]) as $scells
  | if ($scells | length) == 0 then { ok:false, reason:"nospan", span_wids:$span_wids }
    else
      ($scells[0].frame) as $af
      | ( if   $drop_side == "east"  then { fax:"v", coord:G::frame_max_x($af) }
          elif $drop_side == "west"  then { fax:"v", coord:G::frame_min_x($af) }
          elif $drop_side == "north" then { fax:"h", coord:G::frame_min_y($af) }
          else                            { fax:"h", coord:G::frame_max_y($af) } end ) as $face
      | ( ($face.fax == "v" and ($dir == "up" or $dir == "down"))
          or ($face.fax == "h" and ($dir == "left" or $dir == "right")) ) as $perp_ok
      | if ($perp_ok | not) then { ok:false, reason:"perp", span_wids:$span_wids }
        else
          ($scells[0].display_id) as $did
          | ( if $face.fax == "v"
              then { lo:([ $scells[].frame | G::frame_min_y(.) ]|min), hi:([ $scells[].frame | G::frame_max_y(.) ]|max) }
              else { lo:([ $scells[].frame | G::frame_min_x(.) ]|min), hi:([ $scells[].frame | G::frame_max_x(.) ]|max) } end ) as $ext
          | ( if ($dir == "up" or $dir == "left") then $ext.lo else $ext.hi end ) as $edge
          | ( [ $cells[]
                | select(.display_id == $did) | .frame as $f
                | select(
                    if $face.fax == "v"
                    then ( if $drop_side == "east" then (G::fabs(G::frame_max_x($f) - $face.coord) <= TOL)
                           else (G::fabs(G::frame_min_x($f) - $face.coord) <= TOL) end )
                         and ( if $dir == "up" then (G::fabs(G::frame_max_y($f) - $edge) <= TOL)
                               else (G::fabs(G::frame_min_y($f) - $edge) <= TOL) end )
                    else ( if $drop_side == "north" then (G::fabs(G::frame_min_y($f) - $face.coord) <= TOL)
                           else (G::fabs(G::frame_max_y($f) - $face.coord) <= TOL) end )
                         and ( if $dir == "left" then (G::fabs(G::frame_max_x($f) - $edge) <= TOL)
                               else (G::fabs(G::frame_min_x($f) - $edge) <= TOL) end )
                    end ) ] ) as $cands
          | ( $cands[0] // null ) as $next
          | if $next == null then { ok:false, reason:"runend", span_wids:$span_wids }
            else
              # the SHARED divider between the span edge and $next (perpendicular to the face, at
              # $edge): STOP only at a PROMOTION-touching seam (a frozen region). A PINNED seam is
              # FINE to cross — the carve SHORTENS it (trims its drop-side span), preserving its
              # coord/sticky-size for the occupants' far halves; it never DELETES it (the old
              # remove_line-merge concern that motivated a pinned-stop is moot for the carve, and
              # since every divider is pinned after any arrange op, stopping here froze the walk).
              ( [ ($arr.segments // [])[]
                  | select((.axis == (if $face.fax == "v" then "h" else "v" end))
                           and (G::fabs(.coord - $edge) <= TOL)
                           and (.lo - TOL <= $face.coord) and ($face.coord <= .hi + TOL)) ] ) as $seam
              | if ( $seam | any(A::seg_touches_promotion(.; $promos)) )
                then { ok:false, reason:"runend", span_wids:$span_wids }
                else
                  (A::_anchor_key($next)) as $nak
                  | (($binds[$nak].contents[0].window_id) // ($binds[$nak].window_id) // null) as $nwid
                  # STOP at an empty cell, an already-spanned cell, or a z-ORDER STACK (contents>1):
                  # carve_drop hard-rejects a spanned stack, so the run must not offer one (else the
                  # overlay would draw a bold edge for an un-carveable span — review #3).
                  | if ($nwid == null) or (($span_wids | index($nwid)) != null) or ((($binds[$nak].contents // []) | length) > 1)
                    then { ok:false, reason:"runend", span_wids:$span_wids }
                    else
                      ($span_wids + [$nwid]) as $nspan
                      | ([ $nspan[] as $w
                           | ([ $binds | to_entries[] | select(((.value.contents[0].window_id) // .value.window_id) == $w) ][0].key) as $ak2
                           | ([ $cells[] | select(A::_anchor_key(.) == $ak2) ][0].frame) ]) as $frames
                      | { ok:true, reason:"ok", span_wids:$nspan,
                          span_box: { x:([ $frames[] | G::frame_min_x(.) ]|min),
                                      y:([ $frames[] | G::frame_min_y(.) ]|min),
                                      w:(([ $frames[] | G::frame_max_x(.) ]|max) - ([ $frames[] | G::frame_min_x(.) ]|min)),
                                      h:(([ $frames[] | G::frame_max_y(.) ]|max) - ([ $frames[] | G::frame_min_y(.) ]|min)) } }
                    end
                end
            end
        end
    end;

# ── run_from: the maximal collinear run containing an anchor cell (follow-up #3 walk-the-line) ──
# The ordered list of window ids whose $drop_side face is COLLINEAR with $anchor_wid's and form a
# contiguous chain THROUGH the anchor along the run axis — i.e. the cells the move-to cursor can
# WALK to stretch the staged drop edge. Composes extend_run (so the SAME collinear/contiguity/
# pinned-seam/promotion guards apply) by growing from the anchor in BOTH run-axis directions until
# runend, then sorting the union along the run axis. east/west → run along y (down+up); north/south
# → along x (right+left). Returns [wids] (>=1; just [$anchor_wid] when there is no collinear
# neighbor). PURE — no mutation. The caller slices [anchor..cursor] out of this for the drop_span.
def run_from($arr; $T; $anchor_wid; $drop_side):
  ( if ($drop_side == "east" or $drop_side == "west")
    then { a: "down", b: "up", axis: "y" } else { a: "right", b: "left", axis: "x" } end ) as $D
  | def grow($span; $dir):
      (extend_run($arr; $T; $span; $drop_side; $dir)) as $r
      | if ($r.ok) then grow($r.span_wids; $dir) else $span end;
  (grow([$anchor_wid]; $D.a)) as $down
  | (grow($down; $D.b)) as $both
  | (A::cells_md(($arr.segments // []); $T)) as $cells
  | ($arr.bindings // {}) as $binds
  | [ $both[]
      | . as $w
      | ( [ $binds | to_entries[] | select(((.value.contents[0].window_id) // .value.window_id) == $w) ][0].key ) as $ak
      | ( [ $cells[] | select(A::_anchor_key(.) == $ak) ][0].frame ) as $f
      | { wid: $w, pos: (if $f == null then 0 elif $D.axis == "y" then G::frame_min_y($f) else G::frame_min_x($f) end) } ]
  | sort_by(.pos) | map(.wid);

# ── line_at_resolve: the hit-test + transient-id mint (the drag-at resolver) ──
# line_at, then mint _next_line_id onto each hit segment (sequentially — the
# junction resolver's two-mint pattern, v first). This is the M5 mouse-up
# COORDINATE re-resolve: ids minted at mouse-down are settle-transient, so the
# commit re-resolves against the CURRENT store and refuses when nothing is
# there. Returns { kind, ids: [{id, axis}], arr: <minted store> } (ids v-first;
# kind "none" carries the store untouched).
def line_at_resolve($arr; $x; $y; $tol):
  line_at($arr; $x; $y; $tol) as $hit
  | if $hit.kind == "none" then { kind: "none", ids: [], arr: $arr }
    else
      reduce $hit.hits[] as $seg ({ ids: [], arr: $arr };
        . as $st
        # a pinned store can still carry an id from a prior gesture write (sync
        # drops them, but mid-session stores may retain them) — REUSE it; mint
        # only onto an id-less hit (matched by axis+coord+span, the resolver's
        # own predicate).
        | ( if ($seg.id // null) != null then { id: $seg.id, arr: $st.arr }
            else
              (_next_line_id($st.arr)) as $mid
              | { id: $mid,
                  arr: ( $st.arr | .segments = [ .segments[]
                           | if (.axis == $seg.axis) and (G::fabs(.coord - $seg.coord) <= TOL)
                                and (G::fabs(.lo - $seg.lo) <= TOL) and (G::fabs(.hi - $seg.hi) <= TOL)
                             then (. + { id: $mid }) else . end ] ) }
            end ) as $r
        | { ids: ($st.ids + [ { id: $r.id, axis: $seg.axis } ]), arr: $r.arr })
      | { kind: $hit.kind, ids: .ids, arr: .arr }
    end;

# ── mint_run: mint ids onto every member of a hit segment's colinear run ──────
# The keyboard/face analog of line_at_resolve's mint, but AXIS-SCOPED to ONE run
# (colinear_run — no perpendicular crossing). Given a hit segment, returns
# { ids: [id…] (lo-order), arr: <minted store> }, reusing any existing id and
# minting onto the id-less members. Feeds a move_lines run from the face resolver
# (gesture.sh's private directional resize author), so a Hyper+r resize of a split gridline moves the
# whole run — the keyboard twin of drag-at's point-resolved run.
def mint_run($arr; $seg):
  reduce (colinear_run($arr; $seg))[] as $m ({ ids: [], arr: $arr };
    . as $st
    | ( if ($m.id // null) != null then { id: $m.id, arr: $st.arr }
        else (_next_line_id($st.arr)) as $mid
          | { id: $mid,
              arr: ( $st.arr | .segments = [ .segments[]
                       | if (.axis == $m.axis) and (G::fabs(.coord - $m.coord) <= TOL)
                            and (G::fabs(.lo - $m.lo) <= TOL) and (G::fabs(.hi - $m.hi) <= TOL)
                         then (. + { id: $mid }) else . end ] ) }
        end ) as $r
    | { ids: ($st.ids + [ $r.id ]), arr: $r.arr });

# ── dots_md: grabbable dot locations for the overlay (colinear-run D1) ─────────
# Combines v×h JUNCTIONS (A::edges_md corners — a crossing; the overlay grab
# expands each arm to its run) with run SEAMS (where two collinear same-(axis,
# coord) segments abut — grab moves the run). Each dot is {x, y, display_id,
# kind} (kind: "junction" | "seam") in absolute CG coords. The overlay places a
# grab handle at each; both routes resolve a run at the point via line_at.
def dots_md($arr; $T):
  (P::norm_topology($T)) as $NT
  | (A::edges_md(($arr.segments // []); $NT)) as $em
  | ( [ $em.corners[] | { x: .x, y: .y, display_id: .display_id, kind: "junction" } ] )
    + ( [ $em.edges
          | group_by([.display_id, .axis, .coord])[]
          | sort_by(.lo) as $g
          | range(0; (($g | length) - 1)) as $i
          | select(G::fabs(($g[$i+1].lo) - ($g[$i].hi)) <= TOL)
          | $g[$i] as $a
          | if $a.axis == "v"
            then { x: $a.coord, y: $a.hi, display_id: $a.display_id, kind: "seam" }
            else { x: $a.hi, y: $a.coord, display_id: $a.display_id, kind: "seam" } end ] );

# ── claim_edge: claim a DISPLAY EDGE as one full-extent strip (group-drop B1) ──
# The engine half of the movemode display-level drop ("safari full top-to-bottom
# on the far left"): insert a line PARALLEL to the $edge of display $did at the
# equal-share offset, TRIM every perpendicular segment whose endpoint touched
# that edge back to the new line (span-insert alone would CROSS them — a
# T-junction strip of N cells, not ONE), re-key the squeezed survivors by frame
# centre (the _prune_rekey discipline, composed from A::), and BIND $wid into
# the new strip frame-LESS (the insert --fill contract — the settle's re-derive
# materializes it). The new line is returned un-pinned; the CALLER pins (the
# gesture pin-all pass). Refusals (closure-by-rejection, guards before _gate):
#   (1) no bag for $did; (2) a PARALLEL segment already inside the claimed strip
#       (v1 never swallows existing lines); (3) the strip cell fails to derive;
#   (4) A::valid_md on the candidate (defence-in-depth).
# $frac (0<f<1, default equal-share = 1/(parallel bands + 1)) is the strip's
# share of the display extent. Returns {ok, arr, anchor, line: {axis, coord}}.
def claim_edge($arr; $T; $did; $edge; $frac; $wid):
  (P::norm_topology($T)) as $NT
  | ( [ A::_bags(($arr.segments // []); $NT)[] | select((.display_id | tostring) == ($did | tostring)) ][0] // null ) as $bag
  | if $bag == null then { ok: false, reason: "claim_edge: no bag for display \($did)" }
    else
      ($bag.rect) as $R
      | ( if $edge == "west" or $edge == "east" then "v" else "h" end ) as $axis
      # equal share: parallel in-bag coords partition the extent into bands+1… the
      # NEW strip takes 1/(bands+2)? No: bands = existing parallel lines + 1 regions;
      # the new strip takes 1/(regions+1) of the extent (3 cols + a claim → quarters
      # is wrong for the operator example; 2 cols + claim → thirds ✓ regions+1).
      | ( [ $bag.segments[] | select(.axis == $axis) | .coord ] | unique | length ) as $nlines
      | ( $frac // (1 / ($nlines + 2)) ) as $f
      | ( if   $edge == "west"  then ($R.x + ($R.w * $f))
          elif $edge == "east"  then ($R.x + $R.w - ($R.w * $f))
          elif $edge == "north" then ($R.y + ($R.h * $f))
          else                       ($R.y + $R.h - ($R.h * $f)) end ) as $coord
      | ( if $axis == "v" then { lo: $R.y, hi: ($R.y + $R.h) } else { lo: $R.x, hi: ($R.x + $R.w) } end ) as $span
      # the claimed strip's parallel-line exclusion (v1: never swallow a line)
      | ( [ $bag.segments[] | select(.axis == $axis)
            | select( if   $edge == "west"  then (.coord < $coord - TOL)
                      elif $edge == "east"  then (.coord > $coord + TOL)
                      elif $edge == "north" then (.coord < $coord - TOL)
                      else                       (.coord > $coord + TOL) end ) ] ) as $inside
      | if ($inside | length) > 0
        then { ok: false, reason: "claim_edge: \($inside | length) parallel line(s) already inside the claimed \($edge) strip (narrow the claim or move them first)" }
        else
          # the edge face coordinate the perpendiculars touched
          ( if   $edge == "west"  then $R.x
              elif $edge == "east"  then ($R.x + $R.w)
              elif $edge == "north" then $R.y
              else                       ($R.y + $R.h) end ) as $face
          | ( [ ($arr.segments // [])[]
                | if (.axis != $axis)
                     and ( ( if $edge == "west" or $edge == "north"
                             then (G::fabs(.lo - $face) <= TOL)
                             else (G::fabs(.hi - $face) <= TOL) end )
                           # only THIS display's perpendiculars (their span midpoint homes here)
                           and ( (if .axis == "v" then [.coord, ((.lo + .hi) / 2)] else [((.lo + .hi) / 2), .coord] end) as $mp
                                 | ($mp[0] >= $R.x - TOL) and ($mp[0] <= $R.x + $R.w + TOL)
                                   and ($mp[1] >= $R.y - TOL) and ($mp[1] <= $R.y + $R.h + TOL) ) )
                  then ( if $edge == "west" or $edge == "north" then (.lo = $coord) else (.hi = $coord) end )
                  else . end ]
              + [ { axis: $axis, coord: $coord, lo: $span.lo, hi: $span.hi } ] ) as $segs2
          | ($arr | .segments = $segs2) as $cand0
          | (A::cells_md(($cand0.segments // []); $NT)) as $cells2
          # the strip cell: contains a probe point just inside the claimed edge
          | ( if   $edge == "west"  then { x: ($R.x + 2),         y: ($R.y + ($R.h / 2)) }
              elif $edge == "east"  then { x: ($R.x + $R.w - 2),  y: ($R.y + ($R.h / 2)) }
              elif $edge == "north" then { x: ($R.x + ($R.w / 2)), y: ($R.y + 2) }
              else                       { x: ($R.x + ($R.w / 2)), y: ($R.y + $R.h - 2) } end ) as $p
          | ( [ $cells2[] | select( ((.display_id | tostring) == ($did | tostring))
                  and (.frame.x - TOL <= $p.x) and ($p.x <= .frame.x + .frame.w + TOL)
                  and (.frame.y - TOL <= $p.y) and ($p.y <= .frame.y + .frame.h + TOL) ) ][0] // null ) as $strip
          | if $strip == null then { ok: false, reason: "claim_edge: the claimed strip failed to derive" }
            else
              (A::_anchor_key($strip)) as $sanchor
              # re-key EVERY survivor by ANCHOR TRANSLATION: the no-parallel-inside
              # guard guarantees the claim adds EXACTLY ONE atom cut on the claimed
              # side and the trim removes no coordinate, so a west/north claim
              # shifts every prior i0/j0 by one and east/south leave them unchanged.
              # (Geometric re-keys are structurally ambiguous here: a claim wider
              # than the squeezed first band steals both its centre AND its max
              # overlap.) Each translated anchor must exist in the new partition
              # and must not be the strip — else reject (defence-in-depth).
              | ( if   $edge == "west"  then { di: 1, dj: 0 }
                  elif $edge == "north" then { di: 0, dj: 1 }
                  else                       { di: 0, dj: 0 } end ) as $shift
              | ( [ $cells2[] | A::_anchor_key(.) ] ) as $valid_anchors
              | ( [ ($arr.bindings // {}) | to_entries[] ] ) as $surv
              | ( reduce $surv[] as $b ({ ok: true, m: {} };
                    if (.ok | not) then .
                    else
                      ($b.key | split(":")) as $parts
                      | if ($parts | length) != 3 then { ok: false, m: {} }
                        else
                          "\($parts[0]):\(($parts[1] | tonumber) + $shift.di):\(($parts[2] | tonumber) + $shift.dj)" as $nk
                          | if (($valid_anchors | index($nk)) == null) or ($nk == $sanchor) or (.m | has($nk))
                            then { ok: false, m: {} }
                            else { ok: true, m: (.m + { ($nk): $b.value }) }
                            end
                        end
                    end ) ) as $rk
              | if ($rk.ok | not) or (($rk.m | length) != ($surv | length))
                then { ok: false, reason: "claim_edge: survivor anchor translation failed (unmappable/collision) — refused" }
                else
                  # bind WITH the strip's (raw) cell frame — a frame-less binding
                  # would force the next settle COLD (carryable_windows re-keys by
                  # frame) and flatten the claim; the settle re-stamps the proper
                  # inset frame from the partition regardless.
                  ($cand0 | .bindings = ($rk.m
                     | .[$sanchor] = { window_id: $wid, presented: true, frame: $strip.frame,
                                       contents: [ { window_id: $wid, presented: true, frame: $strip.frame } ] })) as $candidate
                  | (_gate($candidate; $NT)) as $g
                  | if $g.ok then { ok: true, arr: $g.arr, anchor: $sanchor, line: { axis: $axis, coord: $coord } }
                    else $g end
                end
            end
        end
    end;

# ── drag_at_tick: the v2 live-drag tick (mouse-line-drag M3) ──────────────────
# ONE mid-drag frame computation, run from the overlay host's HELD jq coprocess
# at ~20Hz: select (the SAME line_at_resolve the commit uses), move (clamped —
# the line sticks at mins live, never below; demote never previews), then
# re-derive frames via the SAME bridge the settle runs, emitting ONLY the
# frames that changed vs the base. PURE PREVIEW: no store write, no carry /
# min-fit gates (those run at the mouse-up commit; a refusal there snaps back).
# `lines` carries each moved line's CLAMPED coord — the host draws the ghost
# THERE, not at the cursor (the tactile wall, F6). {ok:false, stuck:true} on an
# every-axis-stuck junction (the host freezes the ghost and keeps streaming).
def drag_at_tick($arr; $T; $x; $y; $tol; $dx; $dy):
  line_at_resolve($arr; $x; $y; $tol) as $res
  | if $res.kind == "none" then { ok: false, stuck: false, reason: "no gridline at (\($x),\($y))" }
    else
      ( [ $res.ids[] | { line_id: .id, delta: (if .axis == "v" then $dx else $dy end) } ] ) as $moves
      | ( if $res.kind == "segment"
          then move_line_d($res.arr; $T; $moves[0].line_id; $moves[0].delta; false)
          else move_lines($res.arr; $T; $moves) end ) as $r
      | if (($r.ok // false) | not)
        then { ok: false, stuck: true, reason: ($r.reason // "stuck") }
        else
          (A::bridge_arrangement_native($res.arr; $T)) as $bb
          | (A::bridge_arrangement_native($r.arr; $T)) as $mb
          | { ok: true, stuck: false,
              lines: [ $moves[] | .line_id as $lid
                       | ($r.arr.segments[] | select(.id == $lid)) | { axis, coord } ],
              reframe: [ ($mb.bindings // {}) | to_entries[]
                         | .key as $k | .value as $b
                         | select( ((($bb.bindings // {})[$k] // {}).frame // null) != ($b.frame // null) )
                         | select(($b.window_id // null) != null)
                         | { window_id: $b.window_id, frame: $b.frame } ] }
        end
    end;

# ── apply: the single test/CLI seam door (its OWN verb-switch — NOT O::apply_op) ─
def apply($arr; $T; $op; $args):
  if   $op == "insert_line" then insert_line($arr; $T; $args.axis; $args.coord; $args.span; ($args.relation // "free"))
  elif $op == "remove_line" then remove_line($arr; $T; $args.line_id)
  elif $op == "promote"     then promote($arr; $T; $args.cells)
  elif $op == "demote"      then demote($arr; $T; $args.promotion_id)
  elif $op == "rebind"      then rebind($arr; $T; $args.cell_key; ($args.descriptor // null))
  elif $op == "claim_edge"  then claim_edge($arr; $T; $args.display; $args.edge; ($args.frac // null); $args.window_id)
  elif $op == "move_line"   then move_line_d($arr; $T; $args.line_id; $args.delta; ($args.demote // false))
  elif $op == "move_lines"  then move_lines($arr; $T; ($args.moves // []))   # NEVER demote-gated (Z-1/M6: single-line only)
  elif $op == "swap"        then swap($arr; $T; $args.cell_a; $args.cell_b)
  else { ok: false, reason: "lineops: unknown op \($op)" } end;
