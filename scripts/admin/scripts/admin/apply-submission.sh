#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'apply-submission.sh --state FILE --request FILE --actual-author ID --pr NUMBER --out FILE [--bundle FILE] [--metadata FILE --source-time RFC3339 --eventctl PATH --config FILE --authority FILE --state-meta FILE --identity-registry FILE] [--plan-only]'
}

state=''
request=''
actual_author=''
pr_number=''
output=''
bundle=''
metadata=''
source_time=''
eventctl=''
config=''
authority=''
state_meta=''
identity_registry=''
plan_only=false
while (($# > 0)); do
	case "$1" in
		--state)
			(($# >= 2)) || usage
			state=$2
			shift 2
			;;
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
		--pr)
			(($# >= 2)) || usage
			pr_number=$2
			shift 2
			;;
		--out)
			(($# >= 2)) || usage
			output=$2
			shift 2
			;;
		--bundle)
			(($# >= 2)) || usage
			bundle=$2
			shift 2
			;;
		--metadata)
			(($# >= 2)) || usage
			metadata=$2
			shift 2
			;;
		--source-time)
			(($# >= 2)) || usage
			source_time=$2
			shift 2
			;;
		--eventctl)
			(($# >= 2)) || usage
			eventctl=$2
			shift 2
			;;
		--config)
			(($# >= 2)) || usage
			config=$2
			shift 2
			;;
		--authority)
			(($# >= 2)) || usage
			authority=$2
			shift 2
			;;
		--state-meta)
			(($# >= 2)) || usage
			state_meta=$2
			shift 2
			;;
		--identity-registry)
			(($# >= 2)) || usage
			identity_registry=$2
			shift 2
			;;
		--plan-only)
			plan_only=true
			shift
			;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$state" && -n "$request" && -n "$actual_author" && -n "$pr_number" && -n "$output" ]] || usage
[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || event_die 'PR number must be a positive integer'
if [[ "$plan_only" == false ]]; then
	[[ -n "$bundle" && -n "$metadata" && -n "$source_time" && -n "$eventctl" && -n "$config" && -n "$authority" && -n "$state_meta" && -n "$identity_registry" ]] || \
		event_usage 'normal submission admission requires bundle, metadata, eventctl trust context, and source time; use --plan-only only for local structural tests'
fi
event_require_command jq
event_require_file 'registry state' "$state"
event_require_file 'submission request' "$request"
event_assert_canonical_json "$state"
event_assert_canonical_json "$request"
if [[ -n "$bundle" ]]; then
	event_require_file 'submission bundle' "$bundle"
fi
if [[ -n "$metadata" ]]; then
	event_require_file 'eventctl PR metadata' "$metadata"
	event_assert_canonical_json "$metadata"
fi

request_pr=$(jq -er '.pr_number' "$request")
request_pr_id=$(jq -er '.pr_id' "$request")
request_fork=$(jq -er '.fork_repository_id' "$request")
request_owner=$(jq -er '.head_owner' "$request")
request_branch=$(jq -er '.head_branch' "$request")
request_sha=$(jq -er '.head_sha' "$request")
if [[ -n "$metadata" ]]; then
	actual_pr=$(jq -er '.pull_request.number' "$metadata")
	actual_pr_id=$(jq -er '.pull_request.id' "$metadata")
	actual_fork=$(jq -er '.pull_request.head_repository_id' "$metadata")
	actual_owner=$(jq -er '.pull_request.head_owner' "$metadata")
	actual_branch=$(jq -er '.pull_request.head_ref' "$metadata")
	actual_sha=$(jq -er '.pull_request.head_sha' "$metadata")
else
	actual_pr=$request_pr
	actual_pr_id=$request_pr_id
	actual_fork=$request_fork
	actual_owner=$request_owner
	actual_branch=$request_branch
	actual_sha=$request_sha
fi
[[ "$actual_pr" == "$pr_number" ]] || event_die 'admin PR number does not match authenticated request metadata'
action_args=(--request "$request" --actual-author "$actual_author" --registry "$state")
if [[ -n "$bundle" ]]; then
	action_args+=(--bundle "$bundle")
fi
action_args+=(--actual-pr "$actual_pr" --actual-pr-id "$actual_pr_id" --actual-fork-repository-id "$actual_fork" --actual-head-owner "$actual_owner" --actual-head-branch "$actual_branch" --actual-head-sha "$actual_sha")
"$SCRIPT_DIR/../actions/submission.sh" "${action_args[@]}" >/dev/null

if [[ "$plan_only" == false ]]; then
	event_require_file 'eventctl binary' "$eventctl"
	[[ -x "$eventctl" ]] || event_die "eventctl binary is not executable: $eventctl"
	event_require_file 'signed event config' "$config"
	event_require_file 'protected organizer authority' "$authority"
	event_require_file 'protected state metadata' "$state_meta"
	event_require_file 'eventctl identity registry' "$identity_registry"
	eventctl_request=$(mktemp "${TMPDIR:-/tmp}/eventctl-submission.XXXXXX")
	verified_request=$(mktemp "${TMPDIR:-/tmp}/verified-submission.XXXXXX")
	trap 'rm -f -- "$eventctl_request" "$verified_request"' EXIT
	jq -e -cS '.eventctl_request' "$request" > "$eventctl_request"
	"$eventctl" submission verify-request --config "$config" --authority "$authority" --state-meta "$state_meta" --registry "$identity_registry" --request "$eventctl_request" --metadata "$metadata" --bundle "$bundle" --expect-actor-id "$actual_author" --source-time "$source_time" --out "$verified_request" >/dev/null
fi

attempt_id=$(jq -er '.attempt_id' "$request")
team_id=$(jq -er '.team_id' "$request")
bundle_digest=$(jq -er '.bundle_sha256' "$request")
existing_attempt=$(jq -c --arg attempt "$attempt_id" '(.attempts[$attempt] // null)' "$state")
if [[ "$existing_attempt" != 'null' ]]; then
	jq -e --arg attempt "$attempt_id" --arg team "$team_id" --arg actor "$actual_author" --arg digest "$bundle_digest" \
		'.attempts[$attempt].team_id == $team and .attempts[$attempt].github_id == $actor and .attempts[$attempt].bundle_sha256 == $digest' "$state" >/dev/null || \
		event_die 'attempt_id is already bound to different immutable submission data'
	jq -e -cS . "$state" > "$output"
	printf '%s\n' "exact replay returned existing attempt $attempt_id without a new registry revision"
	exit 0
fi
phase=$(jq -er '.phase' "$state")
[[ "$phase" == 'submissions_open' || "$phase" == 'frozen' ]] || event_die 'submission is outside the configured lifecycle'
maximum_total=$(jq -er '.quotas.maximum_total_attempts' "$state")
maximum_team=$(jq -er '.quotas.maximum_attempts_per_team' "$state")
reserved_total=$(jq -er '.quotas.reserved_total' "$state")
reserved_team=$(jq -er --arg team "$team_id" '(.quotas.reserved_by_team[$team] // 0)' "$state")
[[ "$reserved_total" -lt "$maximum_total" ]] || event_die 'global submission quota is exhausted'
[[ "$reserved_team" -lt "$maximum_team" ]] || event_die 'team submission quota is exhausted'
revision=$(jq -er '.revision' "$state")
new_revision=$((revision + 1))
new_reserved_total=$((reserved_total + 1))
new_reserved_team=$((reserved_team + 1))
request_digest=$(event_json_digest "$request")
request_fork=$(jq -er '.fork_repository_id' "$request")
request_branch=$(jq -er '.head_branch' "$request")
request_sha=$(jq -er '.head_sha' "$request")
request_pr_id=$(jq -er '.pr_id' "$request")

tmp_output=$(mktemp "${TMPDIR:-/tmp}/event-submission-state.XXXXXX")
jq --arg attempt "$attempt_id" --arg team "$team_id" --arg actor "$actual_author" --arg digest "$bundle_digest" --arg request_digest "$request_digest" \
	--arg fork "$request_fork" --arg branch "$request_branch" --arg sha "$request_sha" --arg pr_id "$request_pr_id" \
	--argjson pr "$pr_number" --argjson revision "$new_revision" --argjson reserved_total "$new_reserved_total" --argjson reserved_team "$new_reserved_team" \
	' .revision = $revision
	| .quotas.reserved_total = $reserved_total
	| .quotas.reserved_by_team[$team] = $reserved_team
	| .attempts[$attempt] = {
	    team_id: $team,
	    github_id: $actor,
	    bundle_sha256: $digest,
	    request_digest: $request_digest,
	    fork_repository_id: $fork,
	    head_branch: $branch,
	    head_sha: $sha,
	    status: "reserved",
	    source_pr: $pr,
	    source_pr_id: $pr_id
	  }' "$state" > "$tmp_output"
jq -e -cS . "$tmp_output" > "$output" || {
	rm -f -- "$tmp_output"
	event_die 'failed to produce canonical submission state'
}
rm -f -- "$tmp_output"
if [[ "$plan_only" == true ]]; then
	printf '%s\n' "planned structural reservation for attempt $attempt_id at registry revision $new_revision (cryptographic verification not run)"
else
	printf '%s\n' "reserved attempt $attempt_id at registry revision $new_revision"
fi
