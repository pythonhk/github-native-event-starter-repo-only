#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'submission.sh --request FILE --actual-author ID --registry FILE [--bundle FILE --actual-pr NUMBER --actual-pr-id ID --actual-fork-repository-id ID --actual-head-owner NAME --actual-head-branch NAME --actual-head-sha SHA]'
}

request=''
actual_author=''
registry=''
bundle=''
actual_pr=''
actual_pr_id=''
actual_fork_repository_id=''
actual_head_owner=''
actual_head_branch=''
actual_head_sha=''
while (($# > 0)); do
	case "$1" in
		--request)
			(($# >= 2)) || usage
			request=$2
			shift 2
			;;
		--actual-author)
			(($# >= 2)) || usage
			actual_author=$2
			shift 2
			;;
		--registry)
			(($# >= 2)) || usage
			registry=$2
			shift 2
			;;
		--bundle)
			(($# >= 2)) || usage
			bundle=$2
			shift 2
			;;
		--actual-pr)
			(($# >= 2)) || usage
			actual_pr=$2
			shift 2
			;;
		--actual-pr-id)
			(($# >= 2)) || usage
			actual_pr_id=$2
			shift 2
			;;
		--actual-fork-repository-id)
			(($# >= 2)) || usage
			actual_fork_repository_id=$2
			shift 2
			;;
		--actual-head-owner)
			(($# >= 2)) || usage
			actual_head_owner=$2
			shift 2
			;;
		--actual-head-branch)
			(($# >= 2)) || usage
			actual_head_branch=$2
			shift 2
			;;
		--actual-head-sha)
			(($# >= 2)) || usage
			actual_head_sha=$2
			shift 2
			;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$request" && -n "$actual_author" && -n "$registry" ]] || usage
if [[ -n "$actual_pr" || -n "$actual_pr_id" || -n "$actual_fork_repository_id" || -n "$actual_head_owner" || -n "$actual_head_branch" || -n "$actual_head_sha" ]]; then
	[[ -n "$actual_pr" && -n "$actual_pr_id" && -n "$actual_fork_repository_id" && -n "$actual_head_owner" && -n "$actual_head_branch" && -n "$actual_head_sha" ]] || usage
	[[ "$actual_pr" =~ ^[1-9][0-9]*$ && "$actual_pr_id" =~ ^[1-9][0-9]*$ && "$actual_fork_repository_id" =~ ^[1-9][0-9]*$ && "$actual_head_sha" =~ ^[0-9a-f]{40}$ ]] || event_die 'actual PR metadata is invalid'
fi
event_require_command jq
event_require_file 'submission request' "$request"
event_require_file 'registry state' "$registry"
event_assert_canonical_json "$request"
event_decimal_id "$actual_author" || event_die 'actual PR author ID is invalid'

jq -e '
  .schema == "pythonhk.submission-request/v2"
  and (.event_id | type == "string")
  and (.repository_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.team_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.attempt_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.github_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.pr_number | type == "number" and floor == . and . >= 1)
  and (.pr_id | type == "string" and test("^[1-9][0-9]{0,31}$"))
  and (.fork_repository_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.head_owner | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
  and (.head_branch | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"))
  and (.head_sha | type == "string" and test("^[0-9a-f]{40}$"))
  and (.bundle_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.eventctl_request | type == "object" and length > 0 and length <= 48)
' "$request" >/dev/null || event_die 'submission request failed strict structural validation'

claimed_id=$(jq -er '.github_id' "$request")
[[ "$claimed_id" == "$actual_author" ]] || event_die "submission actor mismatch: claimed $claimed_id, authenticated PR author $actual_author"

phase=$(jq -er '.phase' "$registry")
enabled=$(jq -er '.enabled' "$registry")
[[ "$phase" == 'submissions_open' || "$phase" == 'frozen' ]] || event_die "submissions are not open in registry phase $phase"
[[ "$enabled" == 'true' ]] || event_die 'event is disabled in registry'

team_id=$(jq -er '.team_id' "$request")
jq -e --arg id "$claimed_id" --arg team "$team_id" '.memberships[$id] == $team' "$registry" >/dev/null || \
	event_die 'authenticated actor is not an active member of the claimed team'
authoritative_team_digest=$(jq -er --arg team "$team_id" '.teams[$team].proposal_digest' "$registry")

eventctl_request=$(mktemp "${TMPDIR:-/tmp}/eventctl-submission.XXXXXX")
trap 'rm -f -- "$eventctl_request"' EXIT
jq -e -cS '.eventctl_request' "$request" > "$eventctl_request" || event_die 'submission has no embedded eventctl request'
jq -e --arg event "$(jq -er '.event_id' "$request")" --arg repository "$(jq -er '.repository_id' "$request")" --arg actor "$claimed_id" --arg team "$team_id" --arg team_digest "$authoritative_team_digest" --arg attempt "$(jq -er '.attempt_id' "$request")" --arg pr "$(jq -er '.pr_number' "$request")" --arg pr_id "$(jq -er '.pr_id' "$request")" --arg fork "$(jq -er '.fork_repository_id' "$request")" --arg owner "$(jq -er '.head_owner' "$request")" --arg branch "$(jq -er '.head_branch' "$request")" --arg sha "$(jq -er '.head_sha' "$request")" --arg bundle_digest "$(jq -er '.bundle_sha256' "$request")" '
  .kind == "submission_envelope"
  and .event_id == $event
  and .actor_id == $actor
  and .team_id == $team
  and .attempt_id == $attempt
  and (.base_repository.id | tostring) == $repository
  and (.pull_request.number | tostring) == $pr
  and (.pull_request.id | tostring) == $pr_id
  and (.pull_request.head_repository_id | tostring) == $fork
  and .pull_request.head_owner == $owner
  and .pull_request.head_ref == $branch
  and .pull_request.head_sha == $sha
  and (.pull_request.number | numbers and . >= 1)
  and (.pull_request.id | tostring | test("^[1-9][0-9]{0,31}$"))
  and (.pull_request.head_owner | type == "string")
  and .bundle.sha256 == $bundle_digest
  and .team_proposal_digest == $team_digest
  and .signature.key_id == .key_id
' "$eventctl_request" >/dev/null || event_die 'embedded eventctl submission request does not match the repository request'

if [[ -n "$actual_pr" ]]; then
	request_pr=$(jq -er '.pr_number' "$request")
	request_pr_id=$(jq -er '.pr_id' "$request")
	request_fork=$(jq -er '.fork_repository_id' "$request")
	request_owner=$(jq -er '.head_owner' "$request")
	request_branch=$(jq -er '.head_branch' "$request")
	request_sha=$(jq -er '.head_sha' "$request")
	[[ "$request_pr" == "$actual_pr" && "$request_pr_id" == "$actual_pr_id" && "$request_fork" == "$actual_fork_repository_id" && "$request_owner" == "$actual_head_owner" && "$request_branch" == "$actual_head_branch" && "$request_sha" == "$actual_head_sha" ]] || event_die 'submission request does not bind the immutable authenticated PR metadata'
fi

if [[ -n "$bundle" ]]; then
	event_require_file 'submission bundle' "$bundle"
	actual_bundle_digest=$(event_sha256_file "$bundle")
	want_bundle_digest=$(jq -er '.bundle_sha256' "$request")
	[[ "$actual_bundle_digest" == "$want_bundle_digest" ]] || event_die 'bundle digest does not match signed request'
fi

attempt_id=$(jq -er '.attempt_id' "$request")
existing_attempt=$(jq -c --arg attempt "$attempt_id" '(.attempts[$attempt] // null)' "$registry")
if [[ "$existing_attempt" != 'null' ]]; then
	jq -e --arg attempt "$attempt_id" --arg team "$team_id" --arg actor "$claimed_id" --arg digest "$(jq -er '.bundle_sha256' "$request")" \
		'.attempts[$attempt].team_id == $team and .attempts[$attempt].github_id == $actor and .attempts[$attempt].bundle_sha256 == $digest' "$registry" >/dev/null || \
		event_die 'attempt_id is already bound to a different actor, team, or bundle'
	printf '%s\n' 'exact submission replay matches the existing authoritative attempt'
	exit 0
fi

printf '%s\n' 'submission request structurally valid, actor-bound, active-team-bound, and unseen'
