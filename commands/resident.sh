#!/usr/bin/env bash
# Read resident health/snapshots or observe a request result through the sole core socket.
# Usage: ley resident {hello|status|snapshot|health|result|trace} [arguments]

resident_main() {
  local operation="${1:-health}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    hello|status|snapshot|health|result|trace) ;;
    *)
      printf '%s\n' '{"data":null,"error":{"code":"operation_invalid","message":"Use hello, status, snapshot, health, result, or trace"},"meta":{"transport":"resident_socket"}}'
      return 64
      ;;
  esac
  wm_resident_client_json || return $?
  "$LEYLINE_RESIDENT_CLIENT_BIN" "$operation" "$@"
}
