#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'validate-result.sh --state FILE --result FILE --payload FILE'
}
state=''
result=''
payload=''
while (($# > 0)); do
  case "$1" in
    --state) (($# >= 2)) || usage; state=$2; shift 2 ;;
    --result) (($# >= 2)) || usage; result=$2; shift 2 ;;
    --payload) (($# >= 2)) || usage; payload=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$state" && -n "$result" && -n "$payload" ]] || usage
event_require_command jq
event_require_file 'registry state' "$state"
event_require_file 'scoring result' "$result"
event_require_file 'scoring payload' "$payload"
event_assert_canonical_json "$state"
event_assert_canonical_json "$result"
payload_digest=$(event_sha256_file "$payload")
jq -e --arg event "$(jq -er '.event_id' "$state")" '
  .schema == "pythonhk.scoring-result/v2"
  and (keys_unsorted | sort) == ["attempt_id", "event_id", "issued_at", "payload_sha256", "schema", "scorer_id", "scorer_version", "source_attempt_digest", "status", "team_id"]
  and .event_id == $event
  and (.attempt_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.team_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.status == "accepted" or .status == "rejected" or .status == "error")
  and (.payload_sha256 | test("^[0-9a-f]{64}$"))
  and (.scorer_id | test("^[A-Za-z0-9._-]{1,64}$"))
  and (.scorer_version | test("^[A-Za-z0-9._+-]{1,64}$"))
  and (.source_attempt_digest | test("^[0-9a-f]{64}$"))
  and (.issued_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
' "$result" >/dev/null || event_die 'scoring result failed strict structural validation'
[[ "$payload_digest" == "$(jq -er '.payload_sha256' "$result")" ]] || event_die 'scoring payload digest does not match result'
attempt_id=$(jq -er '.attempt_id' "$result")
team_id=$(jq -er '.team_id' "$result")
jq -e --arg attempt "$attempt_id" --arg team "$team_id" \
  '.attempts[$attempt].team_id == $team and (.attempts[$attempt].status == "reserved" or .attempts[$attempt].status == "completed")' "$state" >/dev/null || \
  event_die 'scoring result references no reserved attempt for the claimed team'
attempt_digest=$(jq -er --arg attempt "$attempt_id" '.attempts[$attempt].request_digest' "$state")
[[ "$attempt_digest" == "$(jq -er '.source_attempt_digest' "$result")" ]] || event_die 'scoring result is not bound to the exact accepted attempt request'
jq -e --arg attempt "$attempt_id" '(.results[$attempt] // null) == null' "$state" >/dev/null || event_die 'a result already exists for this attempt'
printf '%s\n' 'scoring result structurally valid, payload-bound, attempt-bound, and unseen'
