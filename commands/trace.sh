#!/usr/bin/env bash
# Read native trace evidence through the canonical resident socket.
trace_main() {
  local client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  [[ -x "$client" ]] || { wm_err 'resident command client unavailable'; return 69; }
  "$client" trace "$@"
}
