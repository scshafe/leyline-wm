#!/usr/bin/env bash
# Validate the native claims contract or repository JSON without contacting a resident.
validate_main() {
  case "${1:-keymap}" in
    keymap)
      command -v jq >/dev/null 2>&1 || { wm_err 'keymap validation requires jq'; return 69; }
      source "$LEYLINE_HOME/lib/resident_keymap.sh" || return 70
      local issues
      issues="$(wm_keymap_tap_disjoint_claims)" || return $?
      printf '%s\n' "$issues"
      printf '%s' "$issues" | jq -e 'type=="array" and length>0 and all(.[]; .level!="error") and any(.[]; .code=="resident_claims_audit")' >/dev/null ;;
    json) "$LEYLINE_HOME/bin/ley" test json ;;
    *) wm_err 'usage: ley validate [keymap|json]'; return 64 ;;
  esac
}
