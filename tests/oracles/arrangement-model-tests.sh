#!/usr/bin/env bash
# Differential harness for the leylined arrangement-model port (model-port plan
# step 2; docs/architecture/leylined-shadow-cutover.md S1). Nav-tests-shaped:
#
#   LEYLINE_ARRANGEMENT_TEST_BACKEND={jq|core}   (default jq)
#
# Every assertion compares a BACKEND producer against a fixed REFERENCE, both
# normalized through `jq -S -c` (canonical re-parse/re-print — number/key
# formatting parity by construction):
#
#   targets  reconcile fixtures (tree-shaped): backend target map vs the
#            reference R::reconcile_targets(.tree; .topology). The jq backend
#            routes via A::bridge_arrangement — replicating the
#            arrangement-bridge oracle; the core backend (plan step 4) must
#            match the same reference.
#   golden   engine_bridge fixtures: backend targets vs the FROZEN
#            .expect_targets. strategy_author fixtures: the pure 7-arg strategy
#            seam (no bin/ley) authored from .seed/.observed, targets vs the
#            frozen .expect_targets — golden-equiv.sh's assertions replicated
#            at the engine seam (the CLI-integrated arm stays in golden-equiv).
#
# The core backend starts UNWIRED: with zero wired verbs it exits 2 loudly
# (never a vacuous green); plan steps 3-7 wire verbs as their ports land.
#
# Exit: 0 all rows ok · 1 assertion failures · 2 shell/vacuity error.
set -uo pipefail

AM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
REPO="$(cd "$AM_SCRIPT_DIR/../.." && pwd -P)"
JQ=(jq -L "$REPO/tests/oracles/jq")
BACKEND="${LEYLINE_ARRANGEMENT_TEST_BACKEND:-jq}"
CORE_BIN="${LEYLINE_CORE_BIN:-$REPO/bin/leylined}"

RECONCILE_DIR="$REPO/tests/oracles/fixtures/reconcile"
GOLDEN_DIR="$REPO/tests/oracles/fixtures/golden"
STRATEGY_DIR="$REPO/tests/oracles/fixtures/arrangement_strategy"

# Verbs the core backend has WIRED so far (space-separated). Steps 3-7 extend
# this list as ports land; an unwired verb row prints SKIP under core.
#   targets         tree-shaped fixtures, DIRECT projection (step 3)
#   bridge-targets  arrangement bridge route (step 4)
#   author          the 7-arg strategy seam (step 7)
CORE_WIRED="targets bridge-targets author"

# ---------------------------------------------------------------------------
# Reference producers — ALWAYS jq, the incumbent engine.
# ---------------------------------------------------------------------------
ref_targets_tree() {
  "${JQ[@]}" -S -c 'import "reconcile" as R; R::reconcile_targets(.tree; .topology)' "$1"
}

ref_frozen_targets() {
  jq -S -c '.expect_targets' "$1"
}

# ---------------------------------------------------------------------------
# Backends.
# ---------------------------------------------------------------------------
backend_jq_targets() {
  "${JQ[@]}" -S -c '
    import "arrangement" as A;
    A::arrangement_targets(A::bridge_arrangement(.tree; .topology); .topology)
  ' "$1"
}

# The pure 7-arg strategy seam: seed store + observed world -> authored store
# -> target map. No bin/ley, no runtime — the engine boundary the core port
# must match (plan step 7 wires the core side of this exact seam).
backend_jq_author() {
  local f="$1" t obs topo rules config
  t="$(jq -c '.seed // {}' "$f")" || return 2
  obs="$(jq -c '.observed // []' "$f")" || return 2
  topo="$(jq -c '.topology' "$f")" || return 2
  rules="$(jq -c '.' "$REPO/tests/oracles/float-rules.json" 2>/dev/null || printf '{"rules":[]}')"
  config="$(jq -c '.strategies[] | select(.id == "arrangement") | .config' "$REPO/tests/oracles/strategies/manifest.json")" || return 2
  "${JQ[@]}" -c -n \
    --argjson t "$t" \
    --argjson obs "$obs" \
    --argjson topo "$topo" \
    --argjson rules "$rules" \
    --arg foc "" \
    --argjson config "$config" \
    --argjson minstore '{}' \
    -f "$REPO/tests/oracles/strategies/arrangement.jq" \
  | "${JQ[@]}" -S -c '
      import "arrangement" as A;
      .arrangement as $s | A::arrangement_targets($s; $s.topology)
    '
}

backend_core_targets() {
  "$CORE_BIN" model targets --fixture "$1" 2>/dev/null | jq -S -c .
}

backend_core_bridge_targets() {
  "$CORE_BIN" model bridge-targets --fixture "$1" 2>/dev/null | jq -S -c .
}

# The core author: synthesize the SAME 7-arg input backend_jq_author builds
# (seed store, observed world, float rules, manifest config), then the pure
# ArrangementStrategy.settle → targets.
backend_core_author() {
  local f="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/am-author.XXXXXX")" || return 2
  jq -c --argjson rules "$(jq -c '.' "$REPO/tests/oracles/float-rules.json" 2>/dev/null || printf '{"rules":[]}')" \
        --argjson config "$(jq -c '.strategies[] | select(.id == "arrangement") | .config' "$REPO/tests/oracles/strategies/manifest.json")" \
        '{ t: (.seed // {}), obs: (.observed // []), topology: .topology,
           rules: $rules, foc: "", config: $config, minstore: {} }' "$f" > "$tmp" || { rm -f "$tmp"; return 2; }
  "$CORE_BIN" model settle --fixture "$tmp" --emit targets 2>/dev/null | jq -S -c .
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Full strategy settle over an already-synthesized fixture. The fixture carries
# the exact same seven pure inputs for both engines; only policy transport differs
# (environment for the incumbent JQ program, explicit Policies for LeylineModel).
strategy_jq_settle() {
  local f="$1" t obs topo rules foc config minstore
  t="$(jq -c '.t' "$f")" || return 2
  obs="$(jq -c '.obs // []' "$f")" || return 2
  topo="$(jq -c '.topology' "$f")" || return 2
  rules="$(jq -c '.rules // []' "$f")" || return 2
  foc="$(jq -r '.foc // ""' "$f")" || return 2
  config="$(jq -c '.config // {}' "$f")" || return 2
  minstore="$(jq -c '.minstore // {}' "$f")" || return 2
  LEYLINE_PARCEL_RECLAIM=absorber \
  LEYLINE_PARCEL_NATIVE_PRUNE=1 \
  LEYLINE_PARCEL_NATIVE_ADOPT=1 \
  LEYLINE_PARCEL_NATIVE_PROMOTE=1 \
    "${JQ[@]}" -S -c -n \
      --argjson t "$t" --argjson obs "$obs" --argjson topo "$topo" \
      --argjson rules "$rules" --arg foc "$foc" --argjson config "$config" \
      --argjson minstore "$minstore" \
      -f "$REPO/tests/oracles/strategies/arrangement.jq"
}

strategy_core_settle() {
  "$CORE_BIN" model settle --fixture "$1" 2>/dev/null | jq -S -c .
}

strategy_backend_settle() {
  case "$BACKEND" in
    jq) strategy_jq_settle "$1" ;;
    core) strategy_core_settle "$1" ;;
    *) return 2 ;;
  esac
}

# Project a settle pair onto hand-authored behavioral claims. Full JQ/Swift
# byte parity is asserted separately; this summary keeps the fixture oracle
# focused on the user-visible rehome semantics and the second-settle fixpoint.
strategy_rehome_summary() {
  local f="$1" first="$2" second="$3"
  "${JQ[@]}" -S -c --argjson first "$first" --argjson second "$second" '
    import "arrangement" as AR;
    import "parcel" as P;
    . as $fx
    | ($first.arrangement) as $arr
    | ([ (($arr.bindings // {}) | to_entries[]) | .value.window_id ]
       + [ ($arr.off_top // [])[] | .window_id ]) as $bound
    | ([ ($fx.obs // [])[] | select(.minimized != true) | .window_id ] | sort | unique) as $managed
    | (reduce ((($arr.bindings // {}) | to_entries[])) as $binding ({};
        ($binding.key | split(":")[0]) as $display
        | .[$display] = ((.[$display] // []) + [$binding.value.window_id]))
       | with_entries(.value |= sort)) as $display_windows
    | ([ AR::_bags(($arr.segments // []); P::norm_topology($fx.topology))[]
         | {key: (.display_id | tostring), value: (.segments | length)} ]
       | from_entries) as $display_segment_counts
    | {
        facts: [ ($first.facts // [])[]
          | if .kind == "rehome"
            then {kind, window_id, from_display, to_display}
            elif .kind == "adopt"
            then {kind, window_id}
            else {kind, window_id}
            end ],
        display_windows: $display_windows,
        display_segment_counts: $display_segment_counts,
        segments: ([ ($arr.segments // [])[] | {axis, coord, lo, hi} ]
                   | sort_by([.axis, .coord, .lo, .hi])),
        conserved_exactly_once: (($bound | sort) == $managed
          and (($bound | length) == ($bound | unique | length))),
        first_arrangement_changed: ($arr != $fx.t),
        second_arrangement_byte_stable: (($second.arrangement | tojson) == ($arr | tojson)),
        second_facts: ($second.facts // [])
      }
  ' "$f"
}

core_wired() {
  local verb="$1" w
  for w in $CORE_WIRED; do
    [[ "$w" == "$verb" ]] && return 0
  done
  return 1
}

run_backend() {
  local verb="$1" fixture="$2"
  case "$BACKEND" in
    jq)
      case "$verb" in
        # The jq backend routes BOTH target verbs through the bridge — that IS
        # the arrangement-bridge oracle (bridge == direct projection). The core
        # backend's `targets` is the DIRECT projection (reconcile_targets).
        targets|bridge-targets) backend_jq_targets "$fixture" ;;
        author)  backend_jq_author "$fixture" ;;
        *) printf 'arrangement-model-tests: unknown verb %s\n' "$verb" >&2; return 2 ;;
      esac
      ;;
    core)
      core_wired "$verb" || return 2   # 3 = clean SKIP (verb not ported yet)
      case "$verb" in
        targets)        backend_core_targets "$fixture" ;;
        bridge-targets) backend_core_bridge_targets "$fixture" ;;
        author)         backend_core_author "$fixture" ;;
        *) return 2 ;;
      esac
      ;;
    *)
      printf 'arrangement-model-tests: unknown backend %s\n' "$BACKEND" >&2
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Rows.
# ---------------------------------------------------------------------------
ROWS=0 FAILS=0 SKIPS=0 JQ_ONLY=0

assert_row() {
  local label="$1" expected="$2" actual="$3" rc="$4"
  ROWS=$((ROWS + 1))
  if [[ "$rc" != "0" || -z "$actual" ]]; then
    FAILS=$((FAILS + 1))
    printf 'not ok %s: backend errored (rc=%s)\n' "$label" "$rc"
    return
  fi
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok %s\n' "$label"
  else
    FAILS=$((FAILS + 1))
    printf 'not ok %s: backend output diverges from reference\n' "$label"
    printf '    expected: %.220s\n' "$expected"
    printf '    actual:   %.220s\n' "$actual"
  fi
}

main() {
  local fixture name expected actual rc kind tmpd

  if [[ "$BACKEND" == "core" && ! -x "$CORE_BIN" ]]; then
    printf 'arrangement-model-tests: leylined not built (run: bin/leylined-build)\n' >&2
    exit 2
  fi

  for fixture in "$RECONCILE_DIR"/*.json; do
    [[ -f "$fixture" ]] || continue
    name="$(basename "$fixture" .json)"
    expected="$(ref_targets_tree "$fixture")" || { printf 'not ok %s: reference errored\n' "$name"; FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    actual="$(run_backend targets "$fixture")"; rc=$?
    assert_row "targets/$name" "$expected" "$actual" "$rc"
    # The bridge route against the SAME reference — under jq this restates the
    # arrangement-bridge oracle; under core it proves bridge==direct ACROSS
    # engines (core bridge vs the jq reference).
    actual="$(run_backend bridge-targets "$fixture")"; rc=$?
    assert_row "bridge-targets/$name" "$expected" "$actual" "$rc"
  done

  # Active-strategy display rehome regressions. The fixture synthesizes a real
  # line-primary prior store from each prior tree, then keeps the managed ID set
  # unchanged while moving one observed frame across a display. This is the seam
  # the native-noop guard used to miss. Every case also settles its first result a
  # second time, proving the rehome reaches a byte-stable fixpoint.
  local strategy_fixture strategy_fixture_name strategy_fixture_count=0
  local strategy_case_count strategy_case_index strategy_case_file strategy_case_declared_name
  local strategy_declared_case_count=0 strategy_executed_case_count=0
  local strategy_second_file strategy_first strategy_second strategy_summary strategy_expected
  local strategy_jq_first strategy_jq_second strategy_jq_second_file
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/arrangement-rehome.XXXXXX")" || exit 2
  for strategy_fixture in "$STRATEGY_DIR"/*.json; do
    [[ -f "$strategy_fixture" ]] || continue
    strategy_fixture_count=$((strategy_fixture_count + 1))
    strategy_fixture_name="$(basename "$strategy_fixture" .json)"
    strategy_case_count="$(jq -er '
      if (.cases | type) == "array"
      then (.cases | length)
      else error("fixture must declare a cases array")
      end
    ' "$strategy_fixture")"; rc=$?
    if [[ "$rc" != "0" ]]; then
      assert_row "strategy-rehome-synthesis/$strategy_fixture_name" \
        "valid-cases-array" "" "$rc"
      continue
    fi
    strategy_declared_case_count=$((strategy_declared_case_count + strategy_case_count))
    for ((strategy_case_index=0; strategy_case_index<strategy_case_count; strategy_case_index++)); do
      strategy_case_declared_name="$(jq -er --argjson case_index "$strategy_case_index" '
        .cases[$case_index].name
        | select(type == "string" and length > 0)
      ' "$strategy_fixture")"; rc=$?
      if [[ "$rc" != "0" ]]; then
        assert_row "strategy-rehome-synthesis/$strategy_fixture_name#$strategy_case_index" \
          "named-case" "" "$rc"
        continue
      fi
      strategy_case_file="$tmpd/$strategy_fixture_name-$strategy_case_index.json"
      "${JQ[@]}" -c --argjson case_index "$strategy_case_index" '
        import "arrangement" as AR;
        import "parcel" as P;
        .cases[$case_index] as $case
        | (AR::bridge_arrangement($case.prior_tree; $case.topology)
           + {topology: P::norm_topology($case.topology), promotions: []}) as $store
        | {name: $case.name, t: $store, obs: ($case.observed // []),
           topology: $case.topology, rules: ($case.rules // []),
           foc: ($case.focused_leaf // ""), config: ($case.config // {}),
           minstore: ($case.minstore // {}),
           policies: {reclaim: "absorber", native_prune: true,
                      native_adopt: true, native_promote: true},
           expect: $case.expect}
      ' "$strategy_fixture" > "$strategy_case_file"; rc=$?
      if [[ "$rc" != "0" ]]; then
        assert_row "strategy-rehome-synthesis/$strategy_case_declared_name" \
          "synthesized-case" "" "$rc"
        continue
      fi
      name="$strategy_case_declared_name"
      strategy_expected="$(jq -e -S -c '.expect | select(type == "object")' \
        "$strategy_case_file")"; rc=$?
      if [[ "$rc" != "0" || -z "$strategy_expected" ]]; then
        assert_row "strategy-rehome-synthesis/$name" "object-expectation" "" "$rc"
        continue
      fi

      strategy_first="$(strategy_backend_settle "$strategy_case_file")"; rc=$?
      # Count only cases that reached the backend. The aggregate assertion below
      # makes every pre-execution failure observable even if another branch grows.
      strategy_executed_case_count=$((strategy_executed_case_count + 1))
      if [[ "$rc" == "0" && -n "$strategy_first" ]]; then
        strategy_second_file="$strategy_case_file.second"
        jq -c --argjson first "$strategy_first" '.t = $first.arrangement' \
          "$strategy_case_file" > "$strategy_second_file"
        strategy_second="$(strategy_backend_settle "$strategy_second_file")"; rc=$?
      else
        strategy_second=""
      fi
      if [[ "$rc" == "0" && -n "$strategy_second" ]]; then
        strategy_summary="$(strategy_rehome_summary "$strategy_case_file" "$strategy_first" "$strategy_second")"; rc=$?
      else
        strategy_summary=""
      fi
      assert_row "strategy-rehome/$name" "$strategy_expected" "$strategy_summary" "$rc"

      # The behavioral oracle intentionally projects the output. Under the core
      # backend, additionally lock the entire first and second results byte-for-byte
      # to the incumbent JQ engine so no unprojected store/fact drift can hide.
      if [[ "$BACKEND" == "core" ]]; then
        strategy_jq_first="$(strategy_jq_settle "$strategy_case_file")"; rc=$?
        assert_row "strategy-rehome-parity/$name/first" "$strategy_jq_first" "$strategy_first" "$rc"
        strategy_jq_second_file="$strategy_case_file.jq-second"
        jq -c --argjson first "$strategy_jq_first" '.t = $first.arrangement' \
          "$strategy_case_file" > "$strategy_jq_second_file"
        strategy_jq_second="$(strategy_jq_settle "$strategy_jq_second_file")"; rc=$?
        assert_row "strategy-rehome-parity/$name/second" "$strategy_jq_second" "$strategy_second" "$rc"
      fi
    done
  done
  actual="false"
  if [[ "$strategy_fixture_count" -gt 0 && "$strategy_declared_case_count" -gt 0 ]]; then
    actual="true"
  fi
  assert_row "strategy-rehome/declarations-present" "true" "$actual" 0
  assert_row "strategy-rehome/all-declared-cases-executed" \
    "$strategy_declared_case_count" "$strategy_executed_case_count" 0
  rm -rf "$tmpd"

  # Prune + store_valid DIFFERENTIALS (CORE backend only; the reference is the
  # jq engine on the IDENTICAL synthesized input). Cases: the committed
  # close-no-hole scene, and each prune-roundtrip prior bridged (via jq — the
  # incumbent) with its goner set derived observed∖observed2 — each × both
  # policies. Multi-goner scenes prove the guard-null path on both engines.
  if [[ "$BACKEND" == "core" ]]; then
    local pcase policy store goners svref svact
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/arrangement-model.XXXXXX")" || exit 2
    # case 1: close-no-hole (committed scene)
    jq -c '{store, topology, goners}' \
      "$REPO/tests/oracles/fixtures/arrangement/prune-scenes/close-no-hole.json" > "$tmpd/close-no-hole.json"
    # cases 2..5: roundtrip priors, bridged + goners derived
    for fixture in "$REPO/tests/oracles/fixtures/arrangement/prune-roundtrip"/*.json; do
      [[ -f "$fixture" ]] || continue
      name="$(basename "$fixture" .json)"
      "${JQ[@]}" -c '
        import "arrangement" as A;
        . as $fx
        | { store: A::bridge_arrangement({nodes: $fx.prior.nodes, root_id: $fx.prior.root_id}; $fx.topology),
            topology: $fx.topology,
            goners: ([ $fx.observed[].window_id ] - [ $fx.observed2[].window_id ]) }
      ' "$fixture" > "$tmpd/$name.json" 2>/dev/null || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    done
    for pcase in "$tmpd"/*.json; do
      name="$(basename "$pcase" .json)"
      for policy in absorber even; do
        jq -c --arg p "$policy" '. + {policy: $p}' "$pcase" > "$pcase.$policy"
        expected="$("${JQ[@]}" -S -c '
          import "arrangement" as AR;
          AR::bridge_arrangement_native_prune(.store; .goners; (.focused // null); .topology; .policy)
        ' "$pcase.$policy" 2>/dev/null)"
        actual="$("$CORE_BIN" model prune --fixture "$pcase.$policy" 2>/dev/null | jq -S -c .)"
        rc=$?
        assert_row "prune/$name/$policy" "$expected" "$actual" "$rc"
      done
      # store_valid differential over the same synthesized store (+topology).
      jq -c '.store + {topology: .topology}' "$pcase" > "$pcase.sv"
      svref="$("${JQ[@]}" -S -c 'import "arrangement" as AR; AR::store_valid(.)' "$pcase.sv" 2>/dev/null)"
      svact="$("$CORE_BIN" model storevalid --fixture "$pcase.sv" 2>/dev/null | jq -S -c .)"
      rc=$?
      assert_row "storevalid/$name" "$svref" "$svact" "$rc"
    done
    rm -rf "$tmpd"
  fi

  # FULL-SETTLE DIFFERENTIALS (CORE only) — the strategy program end-to-end:
  # {arrangement, facts} equality between the jq program (env-pinned) and
  # ArrangementStrategy.settle on IDENTICAL 7-arg inputs, across the fixture
  # scenes × the reclaim policy matrix. Scenes: golden authors (cold path from
  # seed trees), reconcile fixtures (cold path from tree stores), and
  # roundtrip-derived arrangement stores replayed against their observed2
  # worlds (the native noop/prune/adopt dispatch).
  if [[ "$BACKEND" == "core" ]]; then
    local scase spolicy sref sact
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/arrangement-settle.XXXXXX")" || exit 2
    local rules_json config_json
    rules_json="$(jq -c '.' "$REPO/tests/oracles/float-rules.json" 2>/dev/null || printf '{"rules":[]}')"
    config_json="$(jq -c '.strategies[] | select(.id == "arrangement") | .config' "$REPO/tests/oracles/strategies/manifest.json")"
    for fixture in "$GOLDEN_DIR"/author_*.json; do
      [[ -f "$fixture" ]] || continue
      jq -c --argjson rules "$rules_json" --argjson config "$config_json" \
        '{ t: (.seed // {}), obs: (.observed // []), topology: .topology,
           rules: $rules, foc: "", config: $config, minstore: {} }' \
        "$fixture" > "$tmpd/golden-$(basename "$fixture")" 2>/dev/null || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    done
    for fixture in "$RECONCILE_DIR"/*.json; do
      [[ -f "$fixture" ]] || continue
      jq -c --argjson rules "$rules_json" --argjson config "$config_json" \
        '{ t: .tree, obs: (.observed // []), topology: .topology,
           rules: $rules, foc: "", config: $config, minstore: {} }' \
        "$fixture" > "$tmpd/tree-$(basename "$fixture")" 2>/dev/null || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    done
    for fixture in "$REPO/tests/oracles/fixtures/arrangement/prune-roundtrip"/*.json \
                   "$REPO/tests/oracles/fixtures/arrangement/adopt-roundtrip"/*.json; do
      [[ -f "$fixture" ]] || continue
      "${JQ[@]}" -c --argjson rules "$rules_json" --argjson config "$config_json" '
        import "arrangement" as A;
        . as $fx
        | { t: (if ($fx.store // null) != null then $fx.store
                else A::bridge_arrangement({nodes: $fx.prior.nodes, root_id: $fx.prior.root_id}; $fx.topology) end),
            obs: ($fx.observed2 // $fx.observed // []), topology: $fx.topology,
            rules: $rules, foc: "", config: $config, minstore: {} }
      ' "$fixture" > "$tmpd/store-$(basename "$fixture")" 2>/dev/null || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    done
    for scase in "$tmpd"/*.json; do
      [[ -f "$scase" ]] || continue
      name="$(basename "$scase" .json)"
      for spolicy in absorber even; do
        sref="$(LEYLINE_PARCEL_RECLAIM="$spolicy" LEYLINE_PARCEL_NATIVE_PRUNE=1 \
                LEYLINE_PARCEL_NATIVE_ADOPT=1 LEYLINE_PARCEL_NATIVE_PROMOTE=1 \
          "${JQ[@]}" -S -c -n \
            --argjson t "$(jq -c '.t' "$scase")" \
            --argjson obs "$(jq -c '.obs' "$scase")" \
            --argjson topo "$(jq -c '.topology' "$scase")" \
            --argjson rules "$(jq -c '.rules' "$scase")" \
            --arg foc "" \
            --argjson config "$(jq -c '.config' "$scase")" \
            --argjson minstore '{}' \
            -f "$REPO/tests/oracles/strategies/arrangement.jq" 2>/dev/null)"
        jq -c --arg p "$spolicy" '. + {policies: {reclaim: $p}}' "$scase" > "$scase.$spolicy"
        sact="$("$CORE_BIN" model settle --fixture "$scase.$spolicy" 2>/dev/null | jq -S -c .)"
        rc=$?
        assert_row "settle/$name/$spolicy" "$sref" "$sact" "$rc"
      done
    done
    rm -rf "$tmpd"
  fi

  # Adopt DIFFERENTIALS (CORE only; adopt-roundtrip stores are already
  # arrangement-shaped): newcomers = observed2 minus the store's bound set,
  # ndid = the newcomer's home display via the engine's own homing.
  if [[ "$BACKEND" == "core" ]]; then
    local acase
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/arrangement-adopt.XXXXXX")" || exit 2
    for fixture in "$REPO/tests/oracles/fixtures/arrangement/adopt-roundtrip"/*.json; do
      [[ -f "$fixture" ]] || continue
      name="$(basename "$fixture" .json)"
      "${JQ[@]}" -c '
        import "arrangement" as A; import "parcel" as P;
        . as $fx
        | (P::norm_topology($fx.topology)) as $T
        | ([ $fx.store.bindings[] | .window_id ]) as $bound
        | ([ $fx.observed2[].window_id ] - $bound) as $newcomers
        | ($newcomers[0] // null) as $nw
        | ([ $fx.observed2[] | select(.window_id == $nw) ][0].frame // null) as $nf
        | { store: $fx.store, newcomers: $newcomers,
            ndid: (if $nf == null then 0 else A::home_display($nf; $T) end),
            focused: ($fx.focused // null), topology: $fx.topology }
      ' "$fixture" > "$tmpd/$name.json" 2>/dev/null || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    done
    for acase in "$tmpd"/*.json; do
      [[ -f "$acase" ]] || continue
      name="$(basename "$acase" .json)"
      expected="$("${JQ[@]}" -S -c '
        import "arrangement" as AR;
        AR::bridge_arrangement_native_adopt(.store; .newcomers; .ndid; .focused; .topology)
      ' "$acase" 2>/dev/null)"
      actual="$("$CORE_BIN" model adopt --fixture "$acase" 2>/dev/null | jq -S -c .)"
      rc=$?
      assert_row "adopt/$name" "$expected" "$actual" "$rc"
    done
    rm -rf "$tmpd"
  fi

  # The per-def fn corpus (CORE backend only: the jq side of these fixtures is
  # already asserted by `ley test fixtures`; the reference here is the
  # fixture's own hand-authored .expect). An unwired fn (rc 3) prints skip.
  if [[ "$BACKEND" == "core" ]]; then
    local fnname
    for fixture in "$REPO/tests/oracles/fixtures/arrangement"/*.json; do
      [[ -f "$fixture" ]] || continue
      fnname="$(jq -r '.fn // empty' "$fixture")"
      [[ -n "$fnname" ]] || continue
      name="$(basename "$fixture" .json)"
      expected="$(jq -S -c '.expect' "$fixture")"
      # Six engine-only functions have no native model API. They remain named,
      # independently asserted JQ regression cases; this is not native coverage.
      case "$fnname" in
        edges_md|edges_rec|edges_rec_flat_eq|valve_via_rebind)
          JQ_ONLY=$((JQ_ONLY+1))
          source "$AM_SCRIPT_DIR/frozen-models.sh" || exit 2
          actual="$(actual_of arrangement "$fixture" | jq -S -c .)"; rc=$?
          assert_row "jq-only-fn/$fnname/$name" "$expected" "$actual" "$rc"
          continue ;;
      esac
      actual="$("$CORE_BIN" model fn --fixture "$fixture" 2>/dev/null)"; rc=$?
      if [[ "$rc" == "0" ]]; then
        actual="$(printf '%s' "$actual" | jq -S -c . 2>/dev/null)"
      fi
      assert_row "fn/$fnname/$name" "$expected" "$actual" "$rc"
    done
  fi

  for fixture in "$GOLDEN_DIR"/*.json; do
    [[ -f "$fixture" ]] || continue
    name="$(basename "$fixture" .json)"
    kind="$(jq -r '.kind // ""' "$fixture")"
    expected="$(ref_frozen_targets "$fixture")" || { FAILS=$((FAILS+1)); ROWS=$((ROWS+1)); continue; }
    case "$kind" in
      engine_bridge)
        actual="$(run_backend bridge-targets "$fixture")"; rc=$?
        assert_row "golden-bridge/$name" "$expected" "$actual" "$rc"
        ;;
      strategy_author)
        actual="$(run_backend author "$fixture")"; rc=$?
        assert_row "golden-author/$name" "$expected" "$actual" "$rc"
        ;;
      *)
        printf 'not ok golden/%s: unknown kind "%s"\n' "$name" "$kind"
        ROWS=$((ROWS + 1)); FAILS=$((FAILS + 1))
        ;;
    esac
  done

  printf 'arrangement-model-tests: backend=%s rows=%d fails=%d skips=%d\n' \
    "$BACKEND" "$ROWS" "$FAILS" "$SKIPS"
  if [[ "$BACKEND" == core ]]; then
    printf 'oracle-only functions: %s explicitly retained cases; native coverage not claimed\n' "$JQ_ONLY"
    [[ "$JQ_ONLY" == 6 ]] || FAILS=$((FAILS+1))
  fi

  # Vacuity guards: a run that asserted nothing is an error, not a pass. The
  # core backend with zero wired verbs is loud about it.
  if [[ "$ROWS" -eq 0 ]]; then
    if [[ "$BACKEND" == "core" && -z "$CORE_WIRED" ]]; then
      printf 'arrangement-model-tests: core backend has NO wired verbs yet (plan steps 3-7 wire them)\n' >&2
    else
      printf 'arrangement-model-tests: VACUOUS run (zero rows)\n' >&2
    fi
    exit 2
  fi
  [[ "$FAILS" -eq 0 ]] || exit 1
  exit 0
}

case "${1:-run}" in
  run) main ;;
  list)
    ls "$RECONCILE_DIR"/*.json "$GOLDEN_DIR"/*.json 2>/dev/null | while IFS= read -r f; do basename "$f" .json; done
    for f in "$STRATEGY_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      jq -r '.cases[]?.name' "$f"
    done
    ;;
  *)
    printf 'usage: parcel/arrangement-model-tests.sh [run|list]\n' >&2
    printf '  LEYLINE_ARRANGEMENT_TEST_BACKEND=jq|core (default jq)\n' >&2
    exit 2
    ;;
esac
