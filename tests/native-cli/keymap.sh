#!/usr/bin/env bash
# Hermetic v1-route checks through the canonical validator; no tap/AX/launchd start.
set -uo pipefail
validator_repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
validator_task_dir="$(mktemp -d "${TMPDIR:-/tmp}/ley-keymap-owner.XXXXXX")" || exit 1
trap 'rm -rf "$validator_task_dir"' EXIT
export LEYLINE_HOME="$validator_repo_root" LEYLINE_ROOT="$validator_repo_root" LEYLINE_LIB_DIR="$validator_repo_root/lib"
export LEYLINE_RESIDENT_CLIENT_BIN="$validator_task_dir/native"
export NATIVE_CLAIM_ORACLE="$validator_repo_root/leylined/Fixtures/input/v1-claims.json"
export NATIVE_CLAIM_CALL_LOG="$validator_task_dir/calls"
unset LEYLINE_KEYMAP_MODES LEYLINE_KEYMAP_MANIFEST LEYLINE_RESIDENT_CLAIM_ORACLE
source "$LEYLINE_LIB_DIR/resident_keymap.sh" || exit 1
cat > "$LEYLINE_RESIDENT_CLIENT_BIN" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == --dump-claims ]] || exit 64
mode="${2:-}"; shift 2
json=0
while (($#)); do
  case "$1" in --json) json=1; shift ;; --home) shift 2 ;; *) exit 64 ;; esac
done
printf '%s\n' "$mode" >> "$NATIVE_CLAIM_CALL_LOG"
[[ "${NATIVE_CLAIM_MUTATION:-}" != fail ]] || exit 1
dump="$(jq -c --arg mode "$mode" --arg mutation "${NATIVE_CLAIM_MUTATION:-}" '
  (.expected_action_routes[$mode] // {}) as $routes |
  (if $mutation=="missing_route" and $mode=="default" then $routes|del(."cmd + ctrl + alt + shift - l")
   elif $mutation=="rotation_removed" and $mode=="move" then $routes|del(.c, ."cmd + ctrl + alt + shift - c")
   elif $mutation=="rotated_routes" and $mode=="move" then $routes|.h="move.cursor.east"
   elif $mutation=="zero" then {} else $routes end) as $actual |
  {schema:"leyline/resident-input-claims/v1",mode:$mode,claims:($actual|keys),claim_count:($actual|length),
   action_routes:$actual,retained_action_ids:.retained_action_ids,unsupported_action_ids:.unsupported_action_ids} |
  if $mutation=="rotated_order" and $mode=="move" then .claims|=reverse
  elif $mutation=="extra_action" then .unsupported_action_ids=["unknown.action"] else . end
' "$NATIVE_CLAIM_ORACLE")" || exit 1
if (( json )); then printf '%s\n' "$dump"; else printf '%s' "$dump" | jq -r '.claims[]'; fi
STUB
chmod +x "$LEYLINE_RESIDENT_CLIENT_BIN"
checks=0 failures=0
check() {
  checks=$((checks+1))
  if [[ "$2" == yes ]]; then printf 'ok native-keymap/%s\n' "$1"
  else printf 'not ok native-keymap/%s\n' "$1"; failures=$((failures+1)); fi
}
has_code() { printf '%s' "$1" | jq -e --arg code "$2" 'any(.[]; .code==$code and .level=="error")' >/dev/null 2>&1; }
clean() { printf '%s' "$1" | jq -e 'type=="array" and ([.[]|select(.level=="error")]|length)==0' >/dev/null 2>&1; }
out="$(wm_keymap_tap_disjoint_claims)"
verdict=no; clean "$out" && verdict=yes
check canonical-v1-routes "$verdict"
for mutation in missing_route rotation_removed rotated_routes rotated_order extra_action zero fail; do
  export NATIVE_CLAIM_MUTATION="$mutation"
  out="$(wm_keymap_tap_disjoint_claims)"
  case "$mutation" in
    missing_route|rotation_removed|rotated_routes) code=resident_claims_route_mismatch ;;
    extra_action) code=resident_claims_disposition_mismatch ;;
    rotated_order) code=resident_claims_dump_invalid ;;
    zero) code=tap_coverage_vacuous ;;
    fail) code=resident_claims_dump_failed ;;
  esac
  verdict=no; has_code "$out" "$code" && verdict=yes
  check "mutation-$mutation-rejected" "$verdict"
done
unset NATIVE_CLAIM_MUTATION
out="$(LEYLINE_RESIDENT_CLIENT_BIN="$validator_task_dir/absent" wm_keymap_tap_disjoint_claims)"
verdict=no; has_code "$out" resident_claims_binary_unavailable && verdict=yes
check missing-native-owner-fails-closed "$verdict"
jq '.expected_action_routes.move.c="unknown.action"' "$NATIVE_CLAIM_ORACLE" > "$validator_task_dir/changed-oracle.json"
out="$(LEYLINE_RESIDENT_CLAIM_ORACLE="$validator_task_dir/changed-oracle.json" wm_keymap_tap_disjoint_claims)"
verdict=no; has_code "$out" resident_claims_oracle_invalid && verdict=yes
check edited-oracle-cannot-bless-rotated-route "$verdict"
mkdir -p "$validator_task_dir/empty/keymap"
printf '{"bindings":[]}\n' > "$validator_task_dir/empty/keymap/global.json"
printf '{"modes":[]}\n' > "$validator_task_dir/empty/keymap/modes.json"
out="$(LEYLINE_KEYMAP_HOME="$validator_task_dir/empty" wm_keymap_tap_disjoint_claims)"
verdict=no; has_code "$out" resident_claims_source_invalid && verdict=yes
check empty-source-coverage-cannot-green "$verdict"
# Actual canonical loader versus a changed native home, not only the mock binary.
actual="${LEYLINE_CORE_BIN:-$validator_repo_root/bin/leylined-tests}"
if [[ -x "$actual" ]]; then
  native_home="$validator_task_dir/native-home"
  mkdir -p "$native_home/keymap"
  cp "$validator_repo_root/keymap/modes.json" "$native_home/keymap/modes.json"
  cp "$validator_repo_root/keymap/decode-us.json" "$native_home/keymap/decode-us.json"
  jq '.bindings|=map(select(.action_id!="nav.focus.east"))' "$validator_repo_root/keymap/global.json" > "$native_home/keymap/global.json"
  out="$(LEYLINE_RESIDENT_CLIENT_BIN="$actual" LEYLINE_KEYMAP_HOME="$native_home" wm_keymap_tap_disjoint_claims)"
  verdict=no; has_code "$out" resident_claims_source_mismatch && has_code "$out" resident_claims_route_mismatch && verdict=yes
  check actual-loader-missing-retained-route-rejected "$verdict"
else
  check actual-loader-required no
fi
[[ "$checks" -ge 12 ]] || failures=$((failures+1))
printf 'native-keymap: %s checks, %s failures\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
