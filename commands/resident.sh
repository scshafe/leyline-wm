#!/usr/bin/env bash
# Read resident health/snapshots or observe a request result through the sole core socket.
# Usage: ley resident {hello|status|snapshot|health|result|perf|trace} [arguments]

resident_main() {
  local operation="${1:-health}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    hello|status|snapshot|health|result|perf|trace) ;;
    *)
      printf '%s\n' '{"data":null,"error":{"code":"operation_invalid","message":"Use hello, status, snapshot, health, result, perf, or trace"},"meta":{"transport":"resident_socket","mutation_fallback":false}}'
      return 64
      ;;
  esac
  local resident_client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  if [[ ! -x "$resident_client" ]]; then
    printf '%s\n' '{"data":null,"error":{"code":"core_client_unavailable","message":"Build the resident command client"},"meta":{"transport":"resident_socket","mutation_fallback":false}}'
    return 69
  fi
  "$resident_client" "$operation" "$@"
}
