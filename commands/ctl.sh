#!/usr/bin/env bash
# Resident lifecycle and exclusive reset; no filesystem clearing or legacy owner dispatch.
ctl_reset() {
  local mode=soft resume=null apply=1
  while (($#)); do
    case "$1" in
      --soft) mode=soft ;; --hard) mode=hard ;; --no-restart) resume=false ;;
      --dry-run) apply=0 ;; --apply) apply=1 ;;
      --help|-h) printf '%s\n' 'ley ctl reset [--soft|--hard] [--no-restart] [--dry-run]'; return 0 ;;
      *) wm_err "reset: unknown argument: $1"; return 64 ;;
    esac
    shift
  done
  local root="$LEYLINE_ROOT" client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  [[ "$root" = /* && "$root" != / ]] || { wm_err 'reset requires an absolute resident root'; return 64; }
  if (( apply == 0 )); then
    printf 'Resident-owned reset mode=%s resume=%s\n' "$mode" "$resume"
    printf '  [resident-authoritative:D] %s/state/leylined/journal.jsonl — soft preserves; hard quarantines and checkpoints\n' "$root"
    printf '  [resident-audit:D] %s/state/leylined/journal.jsonl.quarantined-* — preserved\n' "$root"
    printf '  [resident-live] %s/sockets/leylined.sock — process/socket/menu survive\n' "$LEYLINE_RUNTIME_DIR"
    return 0
  fi
  [[ -x "$client" ]] || { wm_err 'resident reset client unavailable'; return 69; }
  local args
  args="$(jq -cn --arg mode "$mode" --argjson resume "$resume" 'if $resume==null then {mode:$mode} else {mode:$mode,resume:$resume} end')" || return 65
  "$client" control reset --args-json "$args" --wait --timeout-seconds 8
}
ctl_main() {
  local operation="${1:-status}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    reset) ctl_reset "$@" ;;
    status) "$LEYLINE_HOME/bin/ley" resident status "$@" ;;
    start|stop|restart)
      local client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
      [[ -x "$client" ]] || { wm_err 'resident control client unavailable'; return 69; }
      "$client" control "$operation" --wait --timeout-seconds 8 "$@" ;;
    recovery)
      local executable="$LEYLINE_HOME/bin/Leyline Recovery.app/Contents/MacOS/leyline-recovery"
      [[ -x "$executable" ]] || { wm_err 'Finder Recovery app unavailable'; return 69; }
      "$executable" "$@" ;;
    *) wm_err 'usage: ley ctl [status|start|stop|restart|reset|recovery]'; return 64 ;;
  esac
}
