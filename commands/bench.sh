#!/usr/bin/env bash
# Run native evidence tooling; each tool enforces its own mandatory admission gates.
bench_main() {
  local runner
  case "${1:-}" in
    crash) shift; runner="$LEYLINE_HOME/tests/native-acceptance/measure-crash-recovery.py" ;;
    native) shift; runner="$LEYLINE_HOME/tests/native-acceptance/collect-and-validate.py" ;;
    *) runner="$LEYLINE_HOME/tests/native-acceptance/collect-and-validate.py" ;;
  esac
  [[ -f "$runner" ]] || { wm_err "native acceptance runner unavailable: $runner"; return 69; }
  /usr/bin/python3 "$runner" "$@"
}
