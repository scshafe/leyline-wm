#!/usr/bin/env bash
# Execute a registered resident action through the core socket.
# Usage: ley act <action-id> [--request-id ID] [--expected-revision N] [--args-json OBJECT] [--no-wait]

act_main() {
  wm_resident_client_json || return $?
  "$LEYLINE_RESIDENT_CLIENT_BIN" act "$@"
}
