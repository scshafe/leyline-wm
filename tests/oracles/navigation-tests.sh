#!/usr/bin/env bash
# Read-only native navigation ranking against independent frozen scenes.
set -uo pipefail
ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$ORACLE_DIR/../.." && pwd -P)"
NAV_FIXTURES_DIR="$ORACLE_DIR/navigation/fixtures/nav"
DIRECTIONS=(north east south west)
run_backend() {
  local scene="$1" direction="$2"
  local core_bin="${LEYLINE_CORE_BIN:-$REPO/bin/leylined-tests}"
  if [[ ! -x "$core_bin" ]]; then
    printf 'nav-tests: developer runner not executable: %s (run: bin/leylined-build --tests)\n' "$core_bin" >&2
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
      printf 'not ok %s/%s: native ranking errored\n' "$name" "$direction"
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
    run)
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
    *)
      printf 'usage: tests/oracles/navigation-tests.sh [run]\n' >&2
      return 2
      ;;
  esac
}

main "$@"
