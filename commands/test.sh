#!/usr/bin/env bash
# Required native/oracle/interface checks; missing binaries or corpora fail visibly.
test_native() {
  local binary="${LEYLINE_CORE_BIN:-$LEYLINE_HOME/bin/leylined-tests}" suite failed=0
  [[ -x "$binary" ]] || { wm_err "native test binary unavailable: $binary"; return 69; }
  for suite in model decode fsm perf store socket projection feed responsiveness effector resident resident-commands resident-client space-partitions maintenance startup claims input-stop-barrier input shell presentation installation; do
    wm_head "native/$suite"
    "$binary" self-test "$suite" || failed=$((failed+1))
  done
  (( failed == 0 ))
}
test_oracles() (
  local binary="${LEYLINE_CORE_BIN:-$LEYLINE_HOME/bin/leylined-tests}" oracle_jq_directory
  oracle_jq_directory="$("$LEYLINE_HOME/scripts/development/setup-oracle-jq.sh" --verify)" || return $?
  export PATH="$oracle_jq_directory:$PATH"
  [[ -x "$binary" ]] || { wm_err 'native oracle binary unavailable'; return 69; }
  "$LEYLINE_HOME/tests/oracles/frozen-models.sh" || return $?
  LEYLINE_CORE_BIN="$binary" LEYLINE_ARRANGEMENT_TEST_BACKEND=core "$LEYLINE_HOME/tests/oracles/arrangement-model-tests.sh" || return $?
  LEYLINE_CORE_BIN="$binary" LEYLINE_NAV_TEST_BACKEND=core "$LEYLINE_HOME/tests/oracles/navigation-tests.sh" run || return $?
  "$LEYLINE_HOME/tests/oracles/landed-equiv.sh" || return $?
  /usr/bin/python3 "$LEYLINE_HOME/tests/oracles/test_largest_first_insertion.py" --core-bin "$binary"
)
test_cli() {
  /usr/bin/python3 "$LEYLINE_HOME/tests/native-cli/test_cli.py" || return $?
  /bin/bash "$LEYLINE_HOME/tests/native-cli/keymap.sh"
}
test_recovery() {
  local binary="${LEYLINE_RECOVERY_BIN:-$LEYLINE_HOME/bin/Leyline Recovery Tests.app/Contents/MacOS/leyline-recovery}"
  [[ -x "$binary" ]] || { wm_err "recovery test binary unavailable: $binary"; return 69; }
  "$LEYLINE_HOME/bin/leyline-grant-free-check" "$LEYLINE_HOME/bin/leyline-recovery.swift" || return $?
  "$binary" --self-test-core || return $?
  "$binary" --disable --plan
}
test_acceptance_tools() {
  local name suite
  for name in test_collect_and_validate.py test_measure_crash_recovery.py; do
    suite="$LEYLINE_HOME/tests/native-acceptance/$name"
    [[ -f "$suite" ]] || { wm_err "native acceptance test suite unavailable: $suite"; return 69; }
    /usr/bin/python3 "$suite" || return $?
  done
}
test_release() {
  local corpus="$LEYLINE_HOME/tests/release" count=0 suite
  [[ -d "$corpus" ]] || { wm_err 'release verification corpus unavailable'; return 69; }
  for suite in "$corpus"/test_*.py; do [[ ! -f "$suite" ]] || count=$((count+1)); done
  (( count>0 )) || { wm_err 'release verification corpus empty'; return 69; }
  LEYLINE_CORE_BIN="${LEYLINE_CORE_BIN:-$LEYLINE_HOME/bin/leylined-tests}" /usr/bin/python3 -m unittest discover -s "$corpus" -p 'test_*.py' -v
}
test_main() {
  case "${1:-all}" in
    native) test_native ;;
    oracles) test_oracles ;; cli) test_cli ;;
    recovery) test_recovery ;; acceptance-tools) test_acceptance_tools ;; release) test_release ;;
    syntax|json|links|dependencies) /usr/bin/python3 "$LEYLINE_HOME/tests/source_checks.py" "$1" ;;
    all)
      test_native && test_oracles && test_cli && test_recovery && test_acceptance_tools && test_release && /usr/bin/python3 "$LEYLINE_HOME/tests/source_checks.py" all ;;
    *) wm_err 'usage: ley test [all|native|oracles|cli|recovery|acceptance-tools|release|syntax|json|links|dependencies]'; return 64 ;;
  esac
}
