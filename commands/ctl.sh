#!/usr/bin/env bash
# Resident lifecycle and the resident-owned, journal-preserving reset through the core socket.
ctl_reset() {
  local mode=soft resume=null apply=1
  while (($#)); do
    case "$1" in
      --soft) mode=soft ;; --hard) mode=hard ;; --no-restart) resume=false ;;
      --dry-run) apply=0 ;;
      --help|-h) printf '%s\n' 'ley ctl reset [--soft|--hard] [--no-restart] [--dry-run]'; return 0 ;;
      *) wm_err "reset: unknown argument: $1"; return 64 ;;
    esac
    shift
  done
  local root="$LEYLINE_ROOT"
  [[ "$root" = /* && "$root" != / ]] || { wm_err 'reset requires an absolute resident root'; return 64; }
  if (( apply == 0 )); then
    printf 'Resident-owned reset mode=%s resume=%s\n' "$mode" "$resume"
    printf '  [resident-authoritative:D] %s/state/leylined/journal.jsonl — soft preserves; hard quarantines and checkpoints\n' "$root"
    printf '  [resident-audit:D] %s/state/leylined/journal.jsonl.quarantined-* — preserved\n' "$root"
    printf '  [resident-live] %s/sockets/leylined.sock — process/socket/menu survive\n' "$LEYLINE_RUNTIME_DIR"
    return 0
  fi
  wm_resident_client 'resident reset client unavailable' || return $?
  local args
  args="$(jq -cn --arg mode "$mode" --argjson resume "$resume" 'if $resume==null then {mode:$mode} else {mode:$mode,resume:$resume} end')" || return 65
  "$LEYLINE_RESIDENT_CLIENT_BIN" control reset --args-json "$args" --wait --timeout-seconds 8
}
ctl_main() {
  local operation="${1:-status}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    reset) ctl_reset "$@" ;;
    status) "$LEYLINE_HOME/bin/ley" resident status "$@" ;;
    start|stop|restart)
      wm_resident_client 'resident control client unavailable' || return $?
      "$LEYLINE_RESIDENT_CLIENT_BIN" control "$operation" --wait --timeout-seconds 8 "$@" ;;
    *) wm_err 'usage: ley ctl [status|start|stop|restart|reset]'; return 64 ;;
  esac
}
