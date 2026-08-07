#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'prepare-submission-request.sh --eventctl-request FILE --out FILE'
}

eventctl_request=''
output=''
while (($# > 0)); do
  case "$1" in
    --eventctl-request) (($# >= 2)) || usage; eventctl_request=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; output=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$eventctl_request" && -n "$output" ]] || usage
event_require_command jq
event_require_file 'eventctl submission request' "$eventctl_request"
event_assert_canonical_json "$eventctl_request"

jq -e '
  .kind == "submission_envelope"
  and (.event_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{2,63}$"))
  and (.attempt_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.actor_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.team_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.base_repository.id | tostring | test("^[1-9][0-9]{0,19}$"))
  and (.pull_request.number | numbers and . >= 1)
  and (.pull_request.id | tostring | test("^[1-9][0-9]{0,31}$"))
  and (.pull_request.head_owner | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
  and (.pull_request.head_repository_id | tostring | test("^[1-9][0-9]{0,19}$"))
  and (.pull_request.head_ref | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"))
  and (.pull_request.head_sha | type == "string" and test("^[0-9a-f]{40}$"))
  and (.bundle.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$eventctl_request" >/dev/null || event_die 'eventctl submission request is not structurally valid'

jq -n -cS --slurpfile request "$eventctl_request" '
  ($request[0]) as $r
  | {schema:"pythonhk.submission-request/v2",
     event_id:$r.event_id,
     repository_id:($r.base_repository.id | tostring),
     team_id:$r.team_id,
     attempt_id:$r.attempt_id,
     github_id:$r.actor_id,
     pr_number:$r.pull_request.number,
     pr_id:$r.pull_request.id,
     fork_repository_id:($r.pull_request.head_repository_id | tostring),
     head_owner:$r.pull_request.head_owner,
     head_branch:$r.pull_request.head_ref,
     head_sha:$r.pull_request.head_sha,
     bundle_sha256:$r.bundle.sha256,
     eventctl_request:$r,
     issued_at:$r.issued_at,
     expires_at:$r.expires_at}' > "$output"
event_assert_canonical_json "$output"
printf '%s\n' "prepared actor-bound submission request for $(jq -er '.actor_id' "$eventctl_request")"
