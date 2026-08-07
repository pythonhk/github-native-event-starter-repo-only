#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

event_die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

event_usage() {
	printf 'usage error: %s\n' "$*" >&2
	exit 2
}

event_require_command() {
	command -v "$1" >/dev/null 2>&1 || event_die "required command not found: $1"
}

event_require_file() {
	local label=$1
	local path=$2
	[[ -f "$path" ]] || event_die "$label is not a regular file: $path"
	[[ ! -L "$path" ]] || event_die "$label must not be a symlink: $path"
}

event_require_directory() {
	local label=$1
	local path=$2
	[[ -d "$path" ]] || event_die "$label is not a directory: $path"
	[[ ! -L "$path" ]] || event_die "$label must not be a symlink: $path"
}

event_sha256_file() {
	local path=$1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
	else
		shasum -a 256 "$path" | awk '{print $1}'
	fi
}

event_sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}

# Hash the canonical JSON document bytes without jq's presentation newline.
# eventctl document digests use the same no-newline convention. Keeping this
# helper separate from event_sha256_file prevents a transport newline from
# becoming part of a signed/request binding.
event_json_digest() {
	local input=$1
	event_require_file 'JSON input' "$input"
	jq -e -cS . "$input" | awk 'NR == 1 {printf "%s", $0}' | event_sha256_stdin
}

event_canonical_json() {
	local input=$1
	local output=$2
	event_require_file 'JSON input' "$input"
	jq -e -cS . "$input" > "$output" || event_die "invalid JSON: $input"
}

event_assert_canonical_json() {
	local input=$1
	local temporary
	temporary=$(mktemp "${TMPDIR:-/tmp}/event-canonical.XXXXXX")
	event_canonical_json "$input" "$temporary"
	if ! cmp -s "$input" "$temporary"; then
		rm -f -- "$temporary"
		event_die "JSON is not canonical compact sorted JSON: $input"
	fi
	rm -f -- "$temporary"
}

event_decimal_id() {
	[[ "$1" =~ ^[1-9][0-9]{0,19}$ ]]
}

event_digest() {
	[[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

event_uuid4() {
	[[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

event_read_pr_number() {
	local event_path=${1:-${GITHUB_EVENT_PATH:-}}
	[[ -n "$event_path" ]] || event_die 'GITHUB_EVENT_PATH is required'
	event_require_file 'GitHub event payload' "$event_path"
	jq -er '.pull_request.number | numbers and . >= 1' "$event_path"
}

event_read_pr_author_id() {
	local event_path=${1:-${GITHUB_EVENT_PATH:-}}
	[[ -n "$event_path" ]] || event_die 'GITHUB_EVENT_PATH is required'
	event_require_file 'GitHub event payload' "$event_path"
	jq -er '.pull_request.user.id | numbers and . >= 1 | tostring' "$event_path"
}

event_read_pr_head_sha() {
	local event_path=${1:-${GITHUB_EVENT_PATH:-}}
	[[ -n "$event_path" ]] || event_die 'GITHUB_EVENT_PATH is required'
	event_require_file 'GitHub event payload' "$event_path"
	jq -er '.pull_request.head.sha | strings | select(test("^[0-9a-f]{40}$"))' "$event_path"
}

event_read_pr_base_ref() {
	local event_path=${1:-${GITHUB_EVENT_PATH:-}}
	[[ -n "$event_path" ]] || event_die 'GITHUB_EVENT_PATH is required'
	event_require_file 'GitHub event payload' "$event_path"
	jq -er '.pull_request.base.ref | strings | select(test("^[A-Za-z0-9._/-]{1,128}$"))' "$event_path"
}

event_require_base_main() {
	local base_ref
	base_ref=$(event_read_pr_base_ref "$1")
	[[ "$base_ref" == "main" ]] || event_die "request PR base must be main, got $base_ref"
}

event_changed_paths() {
	local repository=$1
	local pr_number=$2
	local output=$3
	event_require_command gh
	gh api --paginate \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2026-03-10' \
		"repos/${repository}/pulls/${pr_number}/files?per_page=100" \
		--jq '.[].filename' > "$output"
}

event_assert_exact_paths() {
	local paths_file=$1
	shift
	local expected_file
	expected_file=$(mktemp "${TMPDIR:-/tmp}/event-paths.XXXXXX")
	printf '%s\n' "$@" | LC_ALL=C sort > "$expected_file"
	if ! LC_ALL=C sort "$paths_file" | cmp -s - "$expected_file"; then
		printf 'changed paths:\n' >&2
		sed 's/^/  /' "$paths_file" >&2
		rm -f -- "$expected_file"
		event_die 'PR changed paths are not exactly the allowed request files'
	fi
	rm -f -- "$expected_file"
}

event_fetch_pr_blob() {
	local repository=$1
	local ref=$2
	local path=$3
	local output=$4
	event_require_command gh
	gh api \
		-H 'Accept: application/vnd.github.raw+json' \
		-H 'X-GitHub-Api-Version: 2026-03-10' \
		"repos/${repository}/contents/${path}?ref=${ref}" > "$output"
}

event_require_no_secrets_for_pr() {
	[[ "${GITHUB_EVENT_NAME:-}" == pull_request_target ]] || event_die 'validator must run only on pull_request_target'
	[[ "${GITHUB_REF:-}" == refs/heads/main ]] || event_die 'validator must run from trusted main'
}
