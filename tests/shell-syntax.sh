#!/usr/bin/env bash
# Verify Bash 3.2 syntax and runtime-incompatible constructs over permanent shell roots.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
_wm_test_bash4_constructs() {
  awk '
    /^[[:space:]]*#[[:space:]]*bash4-lint:off[[:space:]]+--[[:space:]]*[^[:space:]]/ {
      skip = 1; next }
    /^[[:space:]]*#[[:space:]]*bash4-lint:on([[:space:]]|$)/ { skip = 0; next }
    skip { next }
    /^[[:space:]]*#/ { next }
    # bash4-lint:off -- a construct lint must spell the constructs it hunts for
    /\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)[^}]*\}/ {
      print NR ": bash-4 case-conversion expansion" }
    /(^|[^A-Za-z0-9_])(declare|local|typeset)[[:space:]]+-[A-Za-z]*[An][A-Za-z]*([[:space:]]|$)/ {
      print NR ": bash-4 declare -A (associative) or -n (nameref)" }
    /(^|[^A-Za-z0-9_])(mapfile|readarray)([[:space:]]|$)/ {
      print NR ": bash-4 mapfile/readarray" }
    /&>>/ { print NR ": bash-4 &>> append redirect" }
    /\[\[[[:space:]]+!?[[:space:]]*-v[[:space:]]/ { print NR ": bash-4 [[ -v ]]" }
    /(^|[^A-Za-z0-9_])coproc([[:space:]]|$)/ { print NR ": bash-4 coproc" }
    # bash4-lint:on
  ' "$1" 2>/dev/null
}


checks=0 failures=0
while IFS= read -r file; do
  [[ -f "$REPO/$file" ]] || continue
  first="$(head -1 "$REPO/$file")"
  case "$file:$first" in *.sh:*|*:\#!*bash*) ;; *) continue ;; esac
  checks=$((checks+1))
  /bin/bash -n "$REPO/$file" || failures=$((failures+1))
  hits="$(_wm_test_bash4_constructs "$REPO/$file")"
  if [[ -n "$hits" ]]; then printf 'not ok bash32/%s\n%s\n' "$file" "$hits"; failures=$((failures+1)); fi
done < <(git -C "$REPO" ls-files --cached --others --exclude-standard)
canary="$REPO/tests/fixtures/bash32-constructs-canary.txt"
expected="$(awk '!/^[[:space:]]*(#|$)/ {n++} END {print n+0}' "$canary")"
found="$(_wm_test_bash4_constructs "$canary" | wc -l | tr -d ' ')"
[[ "$expected" -gt 0 && "$found" == "$expected" ]] || failures=$((failures+1))
[[ "$(/bin/bash --version | head -1)" == *'version 3.'* ]] || failures=$((failures+1))
printf 'shell-syntax: %s files, %s/%s canary constructs, %s failures\n' "$checks" "$found" "$expected" "$failures"
[[ "$checks" -gt 0 && "$failures" == 0 ]]
