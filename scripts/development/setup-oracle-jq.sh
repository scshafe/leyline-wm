#!/usr/bin/env bash
# Prepare the checksum-bound jq compiler for trusted frozen regression inputs.
# Explicit setup may download an official binary; --verify is read-only/offline.
# Writes only the ignored per-architecture tool cache, never system jq or user state.
set -euo pipefail
umask 077

oracle_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
oracle_repository_root="$(cd "$oracle_script_dir/../.." && pwd -P)"
oracle_cache_root="${LEYLINE_ORACLE_JQ_DIR:-$oracle_repository_root/.release-build/oracle-jq}"
oracle_verify_only=0
while (( $# )); do
  case "$1" in
    --verify) oracle_verify_only=1; shift ;;
    --directory) (( $#>=2 )) || { printf 'usage: setup-oracle-jq.sh [--directory ABSOLUTE_PATH] [--verify]\n' >&2; exit 64; }
      oracle_cache_root="$2"; shift 2 ;;
    --help) printf 'usage: setup-oracle-jq.sh [--directory ABSOLUTE_PATH] [--verify]\nExplicit setup downloads pinned jq1.8.1; --verify checks offline and prints its directory.\n'; exit 0 ;;
    *) printf 'usage: setup-oracle-jq.sh [--directory ABSOLUTE_PATH] [--verify]\n' >&2; exit 64 ;;
  esac
done
case "$oracle_cache_root" in
  /*) ;;
  *) printf 'oracle jq: cache path must be absolute\n' >&2; exit 64 ;;
esac
case "/${oracle_cache_root#/}/" in
  *'/../'*|*'/./'*|*$'\n'*|*$'\r'*) printf 'oracle jq: invalid cache path\n' >&2; exit 64 ;;
esac
[[ "$(uname -s)" == Darwin ]] || { printf 'oracle jq: supported developer platform is macOS\n' >&2; exit 69; }
case "$(uname -m)" in
  arm64) oracle_asset=jq-macos-arm64; oracle_sha=a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603 ;;
  x86_64) oracle_asset=jq-macos-amd64; oracle_sha=e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f ;;
  *) printf 'oracle jq: unsupported macOS architecture\n' >&2; exit 69 ;;
esac
oracle_tool_directory="$oracle_cache_root/$oracle_asset"
oracle_binary="$oracle_tool_directory/jq"

oracle_verify_binary() {
  [[ -f "$oracle_binary" && ! -L "$oracle_binary" && ! -L "$oracle_tool_directory" && ! -L "$oracle_cache_root" ]] || {
    printf 'oracle jq: pinned tool absent; run scripts/development/setup-oracle-jq.sh explicitly\n' >&2; return 69;
  }
  [[ "$(stat -f '%u' "$oracle_tool_directory")" == "$(id -u)" && "$(stat -f '%OLp' "$oracle_tool_directory")" == 700 ]] || {
    printf 'oracle jq: cached tool directory must be private and owned by the current user\n' >&2; return 65;
  }
  local oracle_actual_sha
  oracle_actual_sha="$(shasum -a 256 "$oracle_binary" | awk '{print $1}')"
  [[ "$oracle_actual_sha" == "$oracle_sha" ]] || {
    printf 'oracle jq: cached binary checksum mismatch; remove the invalid cache and explicitly set up again\n' >&2; return 65;
  }
  [[ -x "$oracle_binary" ]] || { printf 'oracle jq: verified binary is not executable\n' >&2; return 65; }
  [[ "$("$oracle_binary" --version)" == jq-1.8.1 ]] || { printf 'oracle jq: verified tool version mismatch\n' >&2; return 65; }
}

if [[ -e "$oracle_binary" || -L "$oracle_binary" ]] || (( oracle_verify_only )); then
  oracle_verify_binary
else
  [[ ! -L "$oracle_cache_root" && ! -L "$oracle_tool_directory" ]] || { printf 'oracle jq: symlink tool directory refused\n' >&2; exit 65; }
  mkdir -p "$oracle_tool_directory"
  [[ "$(stat -f '%u' "$oracle_tool_directory")" == "$(id -u)" ]] || { printf 'oracle jq: tool directory owner mismatch\n' >&2; exit 65; }
  chmod 700 "$oracle_tool_directory"
  oracle_download="$(mktemp "$oracle_tool_directory/.download.XXXXXX")"
  trap 'rm -f "$oracle_download"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 120 \
    "https://github.com/jqlang/jq/releases/download/jq-1.8.1/$oracle_asset" -o "$oracle_download"
  [[ "$(shasum -a 256 "$oracle_download" | awk '{print $1}')" == "$oracle_sha" ]] || {
    printf 'oracle jq: downloaded binary checksum mismatch; nothing installed\n' >&2; exit 65;
  }
  chmod 700 "$oracle_download"
  mv "$oracle_download" "$oracle_binary"
  oracle_verify_binary
fi
printf '%s\n' "$oracle_tool_directory"
