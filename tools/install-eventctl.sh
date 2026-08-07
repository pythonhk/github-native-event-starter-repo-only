#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
LOCK="$ROOT/tools/eventctl.lock.json"
VERSION=''
destination=''
while (($# > 0)); do
  case "$1" in
    --version) (($# >= 2)) || { printf 'usage: install-eventctl.sh --version v1.0.0 [--destination PATH]\n' >&2; exit 2; }; VERSION=$2; shift 2 ;;
    --destination) (($# >= 2)) || { printf 'usage: install-eventctl.sh --version v1.0.0 [--destination PATH]\n' >&2; exit 2; }; destination=$2; shift 2 ;;
    -h|--help) printf '%s\n' 'usage: install-eventctl.sh --version v1.0.0 [--destination PATH]'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n "$VERSION" ]] || { printf '%s\n' 'error: --version is required' >&2; exit 2; }
[[ -f "$LOCK" ]] || { printf '%s\n' "error: lock file missing: $LOCK" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf '%s\n' 'error: curl is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'error: jq is required' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | awk '{print $1}'; }
else
  command -v shasum >/dev/null 2>&1 || { printf '%s\n' 'error: sha256sum or shasum is required' >&2; exit 1; }
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

platform=$(uname -s | tr '[:upper:]' '[:lower:]')
architecture=$(uname -m)
case "$platform:$architecture" in
  darwin:arm64) asset_key='darwin-arm64'; binary_name='eventctl_darwin_arm64' ;;
  darwin:x86_64) asset_key='darwin-amd64'; binary_name='eventctl_darwin_amd64' ;;
  linux:x86_64) asset_key='linux-amd64'; binary_name='eventctl_linux_amd64' ;;
  linux:aarch64|linux:arm64) asset_key='linux-arm64'; binary_name='eventctl_linux_arm64' ;;
  mingw*:x86_64|msys*:x86_64|cygwin*:x86_64) asset_key='windows-amd64'; binary_name='eventctl_windows_amd64.exe' ;;
  *) printf 'error: unsupported platform %s/%s\n' "$platform" "$architecture" >&2; exit 1 ;;
esac
locked_version=$(jq -er '.version' "$LOCK")
[[ "$VERSION" == "v$locked_version" || "$VERSION" == "$locked_version" ]] || { printf 'error: requested version %s is not the locked version %s\n' "$VERSION" "$locked_version" >&2; exit 1; }
archive_name=$(jq -er --arg key "$asset_key" '.assets[$key].name' "$LOCK")
archive_format=$(jq -er --arg key "$asset_key" '.assets[$key].archive' "$LOCK")
archive_digest=$(jq -er --arg key "$asset_key" '.assets[$key].sha256' "$LOCK")
binary_digest=$(jq -er --arg key "$asset_key" '.assets[$key].binary_sha256' "$LOCK")
if [[ -z "$destination" ]]; then
  destination="$ROOT/tools/.cache/$binary_name"
fi
destination_dir=$(dirname -- "$destination")
mkdir -p -- "$destination_dir"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/eventctl-install.XXXXXX")
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT
archive="$tmp_dir/$archive_name"
url="https://github.com/pythonhk/eventctl/releases/download/v$locked_version/$archive_name"
curl --fail --silent --show-error --location --retry 3 "$url" --output "$archive"
actual_archive_digest=$(hash_file "$archive")
[[ "$actual_archive_digest" == "$archive_digest" ]] || { printf 'error: archive checksum mismatch\n' >&2; exit 1; }
case "$archive_format" in
  tar.gz) tar -xzf "$archive" -C "$tmp_dir" ;;
  zip) command -v unzip >/dev/null 2>&1 || { printf '%s\n' 'error: unzip is required for the locked Windows asset' >&2; exit 1; }; unzip -q "$archive" -d "$tmp_dir" ;;
  *) printf 'error: unsupported archive format %s\n' "$archive_format" >&2; exit 1 ;;
esac
binary=$(find "$tmp_dir" -type f \( -name eventctl -o -name eventctl.exe -o -name "$binary_name" \) -print -quit)
[[ -n "$binary" ]] || { printf '%s\n' 'error: release archive did not contain an executable eventctl' >&2; exit 1; }
actual_binary_digest=$(hash_file "$binary")
[[ "$actual_binary_digest" == "$binary_digest" ]] || { printf 'error: binary checksum mismatch\n' >&2; exit 1; }
install -m 0755 "$binary" "$destination"
printf '%s\n' "installed eventctl $locked_version at $destination"
