#!/usr/bin/env bash
# Run frozen model fixtures through the production model functions.
# Inputs: committed fixtures (each declares .fn and .expect). Side effects: none.
set -uo pipefail
ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$ORACLE_DIR/../.." && pwd -P)"
CORE_BIN="${LEYLINE_CORE_BIN:-$REPO/bin/leylined-tests}"
FAMILIES=(arrangement arrangement_valid arrangement_targets autotile geometry minsize prune)
[[ -x "$CORE_BIN" ]] || { printf 'model-tests: developer runner unavailable: %s\n' "$CORE_BIN" >&2; exit 2; }
rows=0 failures=0
for family in "${FAMILIES[@]}"; do
  count=0
  for fixture in "$ORACLE_DIR/fixtures/$family"/*.json; do
    [[ -f "$fixture" ]] || continue
    count=$((count+1)) rows=$((rows+1))
    name="$family/$(basename "$fixture" .json)"
    expected="$(jq -S -c '.expect' "$fixture")"
    if actual="$("$CORE_BIN" model fn --fixture "$fixture" 2>/dev/null | jq -S -c .)" && [[ "$actual" == "$expected" ]]; then
      printf 'ok %s\n' "$name"
    else
      printf 'not ok %s\n  expected %s\n  actual   %s\n' "$name" "$expected" "${actual:-<error>}"
      failures=$((failures+1))
    fi
  done
  if (( count == 0 )); then printf 'not ok %s/empty-fixture-family\n' "$family"; failures=$((failures+1)); fi
done
printf 'model-tests: %s rows, %s failures\n' "$rows" "$failures"
[[ "$rows" -gt 0 && "$failures" == 0 ]]
