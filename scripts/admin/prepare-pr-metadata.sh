#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'prepare-pr-metadata.sh --github-event FILE --out FILE'
}
event=''
output=''
while (($# > 0)); do
  case "$1" in
    --github-event) (($# >= 2)) || usage; event=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; output=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$event" && -n "$output" ]] || usage
event_require_command jq
event_require_file 'GitHub pull-request event' "$event"

jq -e '
  (.repository.id | numbers and . >= 1)
  and (.repository.owner.login | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
  and (.repository.name | type == "string" and test("^[A-Za-z0-9._-]{1,100}$"))
  and (.pull_request.number | numbers and . >= 1)
  and (.pull_request.id | numbers and . >= 1)
  and (.pull_request.user.id | numbers and . >= 1)
  and (.pull_request.base.ref | type == "string" and test("^[A-Za-z0-9._/-]+$"))
  and (.pull_request.head.ref | type == "string" and test("^[A-Za-z0-9._/-]+$"))
  and (.pull_request.head.sha | type == "string" and test("^[0-9a-f]{40,64}$"))
  and (.pull_request.head.repo.id | numbers and . >= 1)
  and (.pull_request.head.repo.owner.login | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
' "$event" >/dev/null || event_die 'GitHub event does not contain bounded pull-request metadata'

jq -n -cS --slurpfile event "$event" '
  ($event[0]) as $e
  | {kind:"github_pr_metadata",
     actor_id:($e.pull_request.user.id | tostring),
     pull_request_author_id:($e.pull_request.user.id | tostring),
     base_repository:{id:($e.repository.id | tostring), owner:$e.repository.owner.login, name:$e.repository.name},
     pull_request:{
       number:$e.pull_request.number,
       id:($e.pull_request.id | tostring),
       base_repository_id:($e.repository.id | tostring),
       base_ref:$e.pull_request.base.ref,
       head_repository_id:($e.pull_request.head.repo.id | tostring),
       head_owner:$e.pull_request.head.repo.owner.login,
       head_ref:$e.pull_request.head.ref,
       head_sha:$e.pull_request.head.sha
     }}' > "$output"
event_assert_canonical_json "$output"
printf '%s\n' "prepared canonical eventctl PR metadata at $output"
