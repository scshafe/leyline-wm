#!/usr/bin/env bash
# Read resident performance diagnostics; unmeasured distributions never count as release evidence.
# Usage: ley perf [--socket PATH] [--timeout-seconds N] [--json]

perf_main() {
  local resident_client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  if [[ ! -x "$resident_client" ]]; then
    printf '%s\n' '{"data":null,"error":{"code":"core_client_unavailable","message":"Build the resident command client"},"meta":{"transport":"resident_socket","mutation_fallback":false}}'
    return 69
  fi
  "$resident_client" perf "$@"
}
