#!/usr/bin/env bash
# @canonical native_setup_cli -- per-user installation/service administration through the bundled resident.
setup_main() {
  [[ "${1:-}" != launchd ]] || shift
  local operation="${1:-service-status}"
  [[ $# -eq 0 ]] || shift
  case "$operation" in
    --help|-h)
      printf '%s\n' 'ley setup launchd {install|uninstall|service-status|service-start|service-stop|service-restart} [--plan] [native options]'
      return 0 ;;
    install|uninstall|service-status|service-start|service-stop|service-restart) ;;
    *) wm_err 'setup requires a native installation or service operation'; return 64 ;;
  esac
  local client="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  [[ -x "$client" ]] || { wm_err 'native installer unavailable'; return 69; }
  "$client" "$operation" "$@"
}
