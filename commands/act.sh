#!/usr/bin/env bash
# Execute a registered resident action through the sole core socket; never falls back to legacy actuation.
# Usage: ley act <action-id> [--request-id ID] [--expected-revision N] [--args-json OBJECT] [--no-wait]

act_main() {
  local resident_client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  if [[ ! -x "$resident_client" ]]; then
    printf '%s\n' '{"data":null,"error":{"code":"core_client_unavailable","message":"Build the resident command client"},"meta":{"transport":"resident_socket","mutation_fallback":false}}'
    return 69
  fi
  "$resident_client" act "$@"
}
