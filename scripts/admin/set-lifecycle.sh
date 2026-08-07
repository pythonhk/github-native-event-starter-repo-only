#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'set-lifecycle.sh --state FILE --phase PHASE --enabled true|false --reason TEXT --commit SHA --out FILE'
}
state=''
phase=''
enabled=''
reason=''
commit_sha=''
output=''
while (($# > 0)); do
  case "$1" in
    --state) (($# >= 2)) || usage; state=$2; shift 2 ;;
    --phase) (($# >= 2)) || usage; phase=$2; shift 2 ;;
    --enabled) (($# >= 2)) || usage; enabled=$2; shift 2 ;;
    --reason) (($# >= 2)) || usage; reason=$2; shift 2 ;;
    --commit) (($# >= 2)) || usage; commit_sha=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; output=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$state" && -n "$phase" && -n "$enabled" && -n "$commit_sha" && -n "$output" ]] || usage
[[ "$enabled" == true || "$enabled" == false ]] || event_die '--enabled must be true or false'
[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || event_die 'lifecycle commit must be a 40-character lowercase SHA'
event_require_command jq
event_require_file 'registry state' "$state"
event_assert_canonical_json "$state"
case "$phase" in
	draft|registration_open|formation_open|submissions_open|frozen|closed|archived) ;;
	*) event_die "invalid lifecycle phase: $phase" ;;
esac
[[ "$reason" != *$'\n'* && ${#reason} -le 512 ]] || event_die 'lifecycle reason is too long or contains a newline'
if [[ "$enabled" == false && -z "$reason" ]]; then
  event_die 'disabling an event requires a bounded reason'
fi
if [[ "$enabled" == true && -n "$reason" ]]; then
  event_die 'an enabled event cannot carry a disabled reason'
fi
current=$(jq -er '.phase' "$state")
order='{"draft":0,"registration_open":1,"formation_open":2,"submissions_open":3,"frozen":4,"closed":5,"archived":6}'
current_index=$(jq -er --arg phase "$current" '.[$phase]' <<< "$order")
target_index=$(jq -er --arg phase "$phase" '.[$phase]' <<< "$order")
[[ "$target_index" -ge "$current_index" ]] || event_die "lifecycle cannot move backward from $current to $phase"
if [[ "$phase" == "closed" || "$phase" == "archived" ]]; then
  [[ "$enabled" == false ]] || event_die 'closed and archived events must be disabled'
fi
revision=$(jq -er '.revision' "$state")
new_revision=$((revision + 1))
tmp_output=$(mktemp "${TMPDIR:-/tmp}/event-lifecycle-state.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
jq --arg phase "$phase" --arg reason "$reason" --arg commit "$commit_sha" --argjson enabled "$enabled" --argjson revision "$new_revision" \
  '.phase=$phase | .enabled=$enabled | .disabled_reason=$reason | .lifecycle_commit=$commit | .revision=$revision' "$state" > "$tmp_output"
jq -e -cS . "$tmp_output" > "$output" || event_die 'failed to produce canonical lifecycle state'
rm -f -- "$tmp_output"
printf '%s\n' "moved event lifecycle to $phase (enabled=$enabled) at revision $new_revision"
