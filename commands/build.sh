#!/usr/bin/env bash
# Build the two production artifacts explicitly: leylined and Finder Recovery.
build_main() {
  local target="${1:-all}"
  [[ $# -eq 0 ]] || shift
  case "$target" in all|native|leylined|recovery) ;; --help|-h) printf '%s\n' 'ley build [all|native|leylined|recovery]'; return 0 ;; *) wm_err "unknown native build target: $target"; return 64 ;; esac
  [[ $# -eq 0 ]] || { wm_err 'build: unexpected arguments'; return 64; }
  case "$target" in all|native|leylined) "$LEYLINE_HOME/bin/leylined-build" || return $? ;; esac
  case "$target" in all|native|recovery) "$LEYLINE_HOME/bin/leyline-recovery-app-build" || return $? ;; esac
}
