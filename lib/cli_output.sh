#!/usr/bin/env bash
# @canonical cli_output -- terminal diagnostics for the explicit native CLI.
wm_ok() { printf 'ok %s\n' "$*"; }
wm_warn() { printf 'warn %s\n' "$*"; }
wm_err() { printf 'error %s\n' "$*" >&2; }
wm_head() { printf '\n%s\n' "$*"; }
# bin/ley resolves LEYLINE_RESIDENT_CLIENT_BIN before sourcing a command. An
# absent client stops the command with 69 and never falls back to another binary.
wm_resident_client() { [[ -x "$LEYLINE_RESIDENT_CLIENT_BIN" ]] || { wm_err "$1"; return 69; }; }
wm_resident_client_json() {
  [[ -x "$LEYLINE_RESIDENT_CLIENT_BIN" ]] && return 0
  printf '%s\n' '{"data":null,"error":{"code":"core_client_unavailable","message":"Build the resident command client"},"meta":{"transport":"resident_socket"}}'
  return 69
}
