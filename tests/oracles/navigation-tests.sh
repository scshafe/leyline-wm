#!/usr/bin/env bash
# Read-only jq/native navigation equality against independent frozen scenes.
set -uo pipefail
ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LEYLINE_ROOT="$(cd "$ORACLE_DIR/../.." && pwd -P)"
LEYLINE_LIB_DIR="$ORACLE_DIR"
NAV_FIXTURES_DIR="$ORACLE_DIR/navigation/fixtures/nav"
LEYLINE_NAV_TEST_BACKEND="${LEYLINE_NAV_TEST_BACKEND:-core}"
DIRECTIONS=(north east south west)
backend_jq() {
  local scene="$1" direction="$2"
  jq -L "$LEYLINE_LIB_DIR/jq" -c --arg dir "$direction" '
    import "spatial_nav" as S;
    . as $scene
    | ($scene.source.window_id // null) as $src_id
    | if $src_id == null then
        {direction: $dir, outcome: "noFocus", winner: null}
      else
        ($scene.windows
         | map(select((.id // null) == $src_id)
               | select((if has("is_visible") then .is_visible
                         elif has("is-visible") then .["is-visible"]
                         else true end) == true)
               | select((if has("is_minimized") then .is_minimized
                         elif has("is-minimized") then .["is-minimized"]
                         else false end) != true))[0]) as $source
        | if $source == null then
            {direction: $dir, outcome: "noFocus", winner: null}
          else
            ($scene.windows | map(select((.id // null) != $src_id))) as $cands
            | S::rank_candidates(
                $source.frame;
                $dir;
                $cands;
                {surface_displays: ($scene.displays // []),
                 source_id: $src_id}
                + ($scene.opts // {})
              ) as $r
            | {direction: $dir,
               outcome: $r.outcome,
               winner: ($r.winner.id // null),
               ranked: ($r.candidates | map(.id))}
          end
      end
  ' "$scene"
}

backend_core() {
  local scene="$1" direction="$2"
  local core_bin="${LEYLINE_CORE_BIN:-$LEYLINE_ROOT/bin/leylined}"
  if [[ ! -x "$core_bin" ]]; then
    printf 'nav-tests: leylined binary not executable: %s (run: bin/leylined-build)\n' "$core_bin" >&2
    return 2
  fi
  "$core_bin" nav-explain --scene "$scene" --direction "$direction" \
  | jq -c --arg dir "$direction" '
      {direction: $dir,
       outcome: (.outcome // "<missing>"),
       winner:  (.winner  // null),
       ranked:  (.ranked  // [])}
    '
}

run_backend() {
  case "$LEYLINE_NAV_TEST_BACKEND" in
    jq) backend_jq "$@" ;;
    core) backend_core "$@" ;;
    *) printf 'navigation: require jq or core backend\n' >&2; return 2 ;;
  esac
}
assert_outcome() {
  local label="$1" expected_outcome="$2" expected_winner="$3" expected_ranked="$4" actual_json="$5"
  local actual_outcome actual_winner actual_ranked
  actual_outcome="$(printf '%s' "$actual_json" | jq -r '.outcome // "<missing>"')"
  actual_winner="$(printf '%s' "$actual_json" | jq -r '
    if .winner == null then "null" else (.winner | tostring) end
  ')"
  actual_ranked="$(printf '%s' "$actual_json" | jq -c '.ranked // []')"

  if [[ "$actual_outcome" == "$expected_outcome" \
        && "$actual_winner" == "$expected_winner" \
        && "$actual_ranked" == "$expected_ranked" ]]; then
    printf 'ok %s\n' "$label"
    return 0
  fi


  printf 'not ok %s: expected outcome=%s winner=%s ranked=%s; got outcome=%s winner=%s ranked=%s\n' \
    "$label" "$expected_outcome" "$expected_winner" "$expected_ranked" \
    "$actual_outcome" "$actual_winner" "$actual_ranked"
  return 1
}

run_scene() {
  local scene="$1"
  local name expected
  name="$(basename "$scene" .scene.json)"
  expected="${scene%.scene.json}.expected.json"

  if [[ ! -f "$expected" ]]; then
    printf 'not ok %s: missing expected.json (%s)\n' "$name" "$expected"
    return 1
  fi

  local rc=0 direction expected_outcome expected_winner expected_ranked actual
  for direction in "${DIRECTIONS[@]}"; do
    expected_outcome="$(jq -r --arg d "$direction" \
      '.results[$d].outcome // "<missing>"' "$expected")"
    expected_winner="$(jq -r --arg d "$direction" '
      .results[$d].winner as $w
      | if $w == null then "null" else ($w | tostring) end
    ' "$expected")"
    expected_ranked="$(jq -c --arg d "$direction" '.results[$d].ranked // []' "$expected")"


    if ! actual="$(run_backend "$scene" "$direction")"; then
      printf 'not ok %s/%s: backend %s errored\n' \
        "$name" "$direction" "$LEYLINE_NAV_TEST_BACKEND"
      rc=1
      continue
    fi

    assert_outcome "$name/$direction" \
      "$expected_outcome" "$expected_winner" "$expected_ranked" "$actual" \
      || rc=1
  done

  return "$rc"
}

main() {
  local cmd="${1:-run}"
  case "$cmd" in
    run|"")
      if [[ ! -d "$NAV_FIXTURES_DIR" ]]; then
        printf 'nav-tests: no fixtures dir: %s\n' "$NAV_FIXTURES_DIR" >&2
        return 2
      fi

      local rc=0 scene any=0
      for scene in "$NAV_FIXTURES_DIR"/*.scene.json; do
        [[ -f "$scene" ]] || continue
        any=1

        if ! jq empty "$scene" 2>/dev/null; then
          printf 'not ok %s: scene.json does not parse\n' \
            "$(basename "$scene")"
          rc=1
          continue
        fi
        local expected="${scene%.scene.json}.expected.json"
        if [[ -f "$expected" ]] && ! jq empty "$expected" 2>/dev/null; then
          printf 'not ok %s: expected.json does not parse\n' \
            "$(basename "$expected")"
          rc=1
          continue
        fi

        run_scene "$scene" || rc=1
      done

      if [[ "$any" -eq 0 ]]; then
        printf 'nav-tests: no fixtures found under %s\n' "$NAV_FIXTURES_DIR" >&2
        return 2
      fi
      return "$rc"
      ;;
    list)
      [[ -d "$NAV_FIXTURES_DIR" ]] || {
        printf 'nav-tests: no fixtures dir\n' >&2
        return 2
      }
      local scene
      for scene in "$NAV_FIXTURES_DIR"/*.scene.json; do
        [[ -f "$scene" ]] || continue
        basename "$scene" .scene.json
      done
      ;;
    *)
      printf 'usage: display_geometry/nav-tests.sh [run|list]\n' >&2
      printf '  LEYLINE_NAV_TEST_BACKEND=jq|core (default core)\n' >&2
      return 2
      ;;
  esac
}

main "$@"
