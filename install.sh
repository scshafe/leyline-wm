#!/usr/bin/env bash
# Install the downloaded apps for this user; preserve all configuration/state.
# Usage: install.sh [--application-dir DIR] [--bin-dir DIR] [--start|--no-start] [--update]
set -euo pipefail
[[ "$(id -u)" -ne 0 ]] || { printf 'Install as your normal user, without sudo.\n' >&2; exit 65; }
installer_source="$(cd "$(dirname "$0")" && pwd -P)"
installer_apps="$HOME/Applications"
installer_bin="$HOME/.local/bin"
installer_start=--no-start
installer_update=()
while (($#)); do
  case "$1" in
    --application-dir) [[ $# -ge 2 ]] || exit 64; installer_apps="$2"; shift 2 ;;
    --bin-dir) [[ $# -ge 2 ]] || exit 64; installer_bin="$2"; shift 2 ;;
    --start|--no-start) installer_start="$1"; shift ;;
    --update) installer_update=(--update); shift ;;
    --help|-h) printf '%s\n' 'install.sh [--application-dir DIR] [--bin-dir DIR] [--start|--no-start] [--update]' 'Default: ~/Applications, ~/.local/bin, service registered without starting.'; exit 0 ;;
    *) printf 'Unknown install option: %s\n' "$1" >&2; exit 64 ;;
  esac
done
[[ "$installer_apps" == /* && "$installer_bin" == /* ]] || { printf 'Install directories must be absolute.\n' >&2; exit 64; }
installer_validate_path() {
  local checked="$1" parent owner mode
  [[ "$checked" != / && ! "$checked" =~ (^|/)\.\.?(/|$) ]] || { printf 'Canonical non-root install paths are required.\n' >&2; return 65; }
  case "$checked" in /tmp/*) checked="/private$checked" ;; /var/*) checked="/private$checked" ;; esac
  while [[ "$checked" != / ]]; do
    [[ ! -L "$checked" ]] || { printf 'Symlink install ancestry refused.\n' >&2; return 65; }
    if [[ -e "$checked" ]]; then
      [[ -d "$checked" ]] || { printf 'Nondirectory install ancestry refused.\n' >&2; return 65; }
      owner="$(stat -f '%u' "$checked")";mode="$(stat -f '%Lp' "$checked")"
      [[ "$owner" == "$(id -u)" || "$owner" == 0 ]] || { printf 'Foreign-owned install ancestry refused.\n' >&2; return 65; }
      if (( (8#$mode & 0022) != 0 )); then
        [[ "$owner" == 0 && "$checked" == /private/tmp && $((8#$mode & 01000)) != 0 ]] || { printf 'Writable shared install ancestry refused.\n' >&2; return 65; }
      fi
    fi
    checked="$(dirname "$checked")"
  done
}
installer_validate_path "$installer_apps"
installer_validate_path "$installer_bin"
installer_bundles=('Leyline.app' 'Leyline Recovery.app')
installer_expected_bundle_id() {
  case "$1" in 'Leyline Recovery.app') printf '%s\n' org.leyline.recovery ;; *) printf '%s\n' org.leyline ;; esac
}
# The resident inside a bundle, without the developer LEYLINE_HOME so it uses that bundle's resources.
installer_native() { local installer_bundle_root="$1"; shift; /usr/bin/env -u LEYLINE_HOME "$installer_bundle_root/Contents/MacOS/leylined" "$@"; }
umask 077
for installer_bundle in "${installer_bundles[@]}"; do
  [[ -d "$installer_source/$installer_bundle" ]] || { printf 'Missing app bundle: %s\n' "$installer_bundle" >&2; exit 66; }
  codesign --verify --strict --deep "$installer_source/$installer_bundle"
done
for installer_dir in "$installer_apps" "$installer_bin"; do
  [[ ! -L "$installer_dir" ]] || { printf 'Symlink install directory refused.\n' >&2; exit 65; }
  mkdir -p "$installer_dir"
  [[ "$(stat -f '%u' "$installer_dir")" == "$(id -u)" ]] || { printf 'Install directory must belong to this user.\n' >&2; exit 65; }
  installer_mode="$(stat -f '%Lp' "$installer_dir")"
  (( (8#$installer_mode & 0022) == 0 )) || { printf 'Install directory must not be writable by others.\n' >&2; exit 65; }
done
installer_cli="$installer_apps/Leyline.app/Contents/Resources/leyline/bin/ley"
if [[ -e "$installer_bin/ley" || -L "$installer_bin/ley" ]]; then
  [[ -L "$installer_bin/ley" && "$(readlink "$installer_bin/ley")" == "$installer_cli" ]] || { printf 'Existing unrelated ley command refused.\n' >&2; exit 65; }
fi
for installer_bundle in "${installer_bundles[@]}"; do
  installer_dest="$installer_apps/$installer_bundle"
  [[ ! -L "$installer_dest" ]] || { printf 'Symlink app destination refused.\n' >&2; exit 65; }
  if [[ -e "$installer_dest" ]]; then
    [[ ${#installer_update[@]} -gt 0 ]] || { printf 'App already installed; review an explicit --update.\n' >&2; exit 65; }
    installer_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installer_dest/Contents/Info.plist")"
    [[ "$installer_bundle_id" == "$(installer_expected_bundle_id "$installer_bundle")" ]] || { printf 'Unrelated app destination refused.\n' >&2; exit 65; }
  fi
done
installer_prior_registered=0
installer_prior_status="$(installer_native "$installer_source/Leyline.app" service-status)"
if printf '%s' "$installer_prior_status" | /usr/bin/grep -Eq '"registered"[[:space:]]*:[[:space:]]*true'; then installer_prior_registered=1; fi
installer_staging="$(mktemp -d "$installer_apps/.leyline-install.XXXXXX")"
installer_changed=()
installer_success=0
installer_link_created=0
installer_cleanup() {
  installer_rc=$?
  if [[ "$installer_success" == 0 ]]; then
    for installer_bundle in ${installer_changed[@]+"${installer_changed[@]}"}; do
      rm -rf "$installer_apps/$installer_bundle"
      if [[ -d "$installer_staging/old-$installer_bundle" ]]; then mv "$installer_staging/old-$installer_bundle" "$installer_apps/$installer_bundle"; fi
    done
    [[ "$installer_link_created" == 0 ]] || rm -f "$installer_bin/ley"
    if [[ "$installer_prior_registered" == 1 && ${#installer_changed[@]} -gt 0 && -x "$installer_apps/Leyline.app/Contents/MacOS/leylined" ]]; then
      if ! installer_native "$installer_apps/Leyline.app" service-restart; then
        printf 'Application files restored, but prior service restart failed; use Leyline Recovery.\n' >&2
        installer_rc=70
      fi
    fi
  fi
  rm -rf "$installer_staging"
  exit "$installer_rc"
}
trap installer_cleanup EXIT
for installer_bundle in "${installer_bundles[@]}"; do
  /usr/bin/ditto "$installer_source/$installer_bundle" "$installer_staging/$installer_bundle"
  codesign --verify --strict --deep "$installer_staging/$installer_bundle"
done
for installer_bundle in "${installer_bundles[@]}"; do
  installer_dest="$installer_apps/$installer_bundle"
  if [[ -e "$installer_dest" ]]; then mv "$installer_dest" "$installer_staging/old-$installer_bundle"; fi
  installer_changed+=("$installer_bundle")
  mv "$installer_staging/$installer_bundle" "$installer_dest"
done
if [[ ! -L "$installer_bin/ley" ]]; then ln -s "$installer_cli" "$installer_bin/ley"; installer_link_created=1; fi
installer_native "$installer_apps/Leyline.app" install "$installer_start" ${installer_update[@]+"${installer_update[@]}"}
if [[ ${#installer_update[@]} -gt 0 && "$installer_start" == --start ]]; then
  installer_native "$installer_apps/Leyline.app" service-restart
fi
installer_success=1
printf 'Installed. CLI: %s/ley\n' "$installer_bin"
