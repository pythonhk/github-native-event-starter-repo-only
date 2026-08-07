#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
lock_file="$SCRIPT_DIR/eventctl.lock.json"
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is required' >&2; exit 1; }
[[ -f "$lock_file" && ! -L "$lock_file" ]] || { printf '%s\n' 'eventctl lock is missing' >&2; exit 1; }
jq -e '
  .schema_version == 1
  and .repository == "pythonhk/eventctl"
  and (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and (.checksums.name == "SHA256SUMS")
  and (.checksums.sha256 | test("^[0-9a-f]{64}$"))
  and ([.assets | keys[]] | sort) == ["darwin-amd64","darwin-arm64","linux-amd64","linux-arm64","windows-amd64","windows-arm64"]
  and all(.assets[]; (.name | type == "string" and length > 0) and (.sha256 | test("^[0-9a-f]{64}$")) and (.binary_sha256 | test("^[0-9a-f]{64}$")))
' "$lock_file" >/dev/null
printf 'eventctl lock is complete for version %s\n' "$(jq -er '.version' "$lock_file")"
