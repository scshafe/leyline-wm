#!/usr/bin/env bash
# @canonical cli_output -- terminal diagnostics for the explicit native CLI.
LEYLINE_FAIL_COUNT=${LEYLINE_FAIL_COUNT:-0}
wm_say() { printf '%s\n' "$*"; }
wm_dim() { printf '  %s\n' "$*"; }
wm_ok() { printf 'ok %s\n' "$*"; }
wm_info() { printf 'info %s\n' "$*"; }
wm_warn() { printf 'warn %s\n' "$*"; }
wm_err() { printf 'error %s\n' "$*" >&2; }
wm_head() { printf '\n%s\n' "$*"; }
wm_fail() { LEYLINE_FAIL_COUNT=$((LEYLINE_FAIL_COUNT+1)); wm_err "$*"; }
