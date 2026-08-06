#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'apply-score.sh --state FILE --result FILE --payload FILE --commit SHA --out FILE'
}
state=''
result=''
payload=''
commit_sha=''
output=''
while (($# > 0)); do
  case "$1" in
    --state) (($# >= 2)) || usage; state=$2; shift 2 ;;
    --result) (($# >= 2)) || usage; result=$2; shift 2 ;;
    --payload) (($# >= 2)) || usage; payload=$2; shift 2 ;;
    --commit) (($# >= 2)) || usage; commit_sha=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; output=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$state" && -n "$result" && -n "$payload" && -n "$commit_sha" && -n "$output" ]] || usage
[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || event_die 'scoring source commit must be a 40-character lowercase SHA'
event_require_command jq
event_require_file 'registry state' "$state"
event_require_file 'scoring result' "$result"
event_require_file 'scoring payload' "$payload"
event_assert_canonical_json "$state"
event_assert_canonical_json "$result"
phase=$(jq -er '.phase' "$state")
[[ "$phase" == 'submissions_open' || "$phase" == 'frozen' || "$phase" == 'closed' ]] || event_die "scoring is not allowed in lifecycle phase $phase"
jq -e '.scoring.enabled == true and .scoring.isolation == "organizer-controlled"' "$state" >/dev/null || event_die 'isolated scoring is disabled'
bash "$SCRIPT_DIR/../scoring/validate-result.sh" --state "$state" --result "$result" --payload "$payload" >/dev/null
attempt_id=$(jq -er '.attempt_id' "$result")
revision=$(jq -er '.revision' "$state")
new_revision=$((revision + 1))
payload_digest=$(jq -er '.payload_sha256' "$result")
team_id=$(jq -er '.team_id' "$result")
status=$(jq -er '.status' "$result")
scorer_id=$(jq -er '.scorer_id' "$result")
scorer_version=$(jq -er '.scorer_version' "$result")
tmp_output=$(mktemp "${TMPDIR:-/tmp}/event-scored-state.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
jq --arg attempt "$attempt_id" --arg team "$team_id" --arg status "$status" --arg payload "$payload_digest" --arg scorer "$scorer_id" --arg version "$scorer_version" --arg commit "$commit_sha" --argjson revision "$new_revision" \
  '.revision = $revision
   | .results[$attempt] = {attempt_id:$attempt, team_id:$team, status:$status, payload_sha256:$payload, scorer_id:$scorer, scorer_version:$version, source_commit:$commit}
   | .attempts[$attempt].status = "completed"' "$state" > "$tmp_output"
jq -e -cS . "$tmp_output" > "$output" || event_die 'failed to produce canonical scored registry state'
rm -f -- "$tmp_output"
printf '%s\n' "applied isolated scoring result for attempt $attempt_id at registry revision $new_revision"
