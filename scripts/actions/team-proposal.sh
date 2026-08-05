#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'team-proposal.sh --proposal FILE --signatures FILE [--status-out FILE]'
}

proposal=''
signatures=''
status_out=''
while (($# > 0)); do
	case "$1" in
		--proposal)
			(($# >= 2)) || usage
			proposal=$2
			shift 2
			;;
		--signatures)
			(($# >= 2)) || usage
			signatures=$2
			shift 2
			;;
		--status-out)
			(($# >= 2)) || usage
			status_out=$2
			shift 2
			;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$proposal" && -n "$signatures" ]] || usage
event_require_command jq
event_require_file 'team proposal' "$proposal"
event_require_file 'team signature envelope' "$signatures"
event_require_command mktemp
event_assert_canonical_json "$proposal"
event_assert_canonical_json "$signatures"

jq -e '
  .schema == "pythonhk.team-proposal/v2"
  and (.event_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{2,63}$"))
  and (.repository_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.registration_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.team_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.proposer_github_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.members | type == "array" and length >= 1 and length <= 64)
  and (.members | all(.[ ];
    type == "object"
    and (keys_unsorted | sort) == ["github_id", "key_id", "public_key", "role"]
    and (.github_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
    and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.public_key | type == "string" and length >= 1 and length <= 256)
    and (.role == "captain" or .role == "member")
  ))
  and ([.members[].github_id] | all(test("^[1-9][0-9]{0,19}$")) and length == (unique | length) and . == (sort_by(tonumber)))
  and ([.members[].key_id] | all(test("^[0-9a-f]{64}$")) and length == (unique | length))
  and ([.members[].role] | map(select(. == "captain")) | length == 1)
  and (.eventctl_proposal | type == "object" and length > 0 and length <= 32)
  and (.issued_at | type == "string")
  and (.expires_at | type == "string")
' "$proposal" >/dev/null || event_die 'team proposal failed strict structural validation'

proposer_id=$(jq -er '.proposer_github_id' "$proposal")
jq -e --arg proposer "$proposer_id" 'any(.members[]; .github_id == $proposer)' "$proposal" >/dev/null || \
	event_die 'team proposal proposer is not listed as a member'

proposal_digest=$(event_json_digest "$proposal")
registration_id=$(jq -er '.registration_id' "$proposal")
eventctl_proposal=$(mktemp "${TMPDIR:-/tmp}/eventctl-proposal.XXXXXX")
trap 'rm -f -- "$eventctl_proposal"' EXIT
jq -e -cS '.eventctl_proposal' "$proposal" > "$eventctl_proposal" || event_die 'team proposal does not contain a valid eventctl proposal object'
eventctl_proposal_digest=$(event_json_digest "$eventctl_proposal")
proposer_key=$(jq -er --arg proposer "$proposer_id" '.members[] | select(.github_id == $proposer) | .key_id' "$proposal")
jq -e \
	--arg event "$(jq -er '.event_id' "$proposal")" \
	--arg repository "$(jq -er '.repository_id' "$proposal")" \
	--arg registration "$registration_id" \
	--arg team "$(jq -er '.team_id' "$proposal")" \
	--arg proposer "$(jq -er '.proposer_github_id' "$proposal")" \
	--arg proposer_key "$proposer_key" \
	--argjson members "$(jq -c '.members | map(.github_id)' "$proposal")" \
	'
  .kind == "team_proposal"
  and .operation_id == $registration
  and .event_id == $event
  and (.base_repository.id | tostring) == $repository
  and .team_id == $team
  and .proposer_actor_id == $proposer
  and .key_id == $proposer_key
  and .member_actor_ids == $members
' "$eventctl_proposal" >/dev/null || event_die 'embedded eventctl proposal does not match the repository team manifest'

jq -e --arg digest "$proposal_digest" --arg eventctl_digest "$eventctl_proposal_digest" --arg registration "$registration_id" --arg event "$(jq -er '.event_id' "$proposal")" --arg repository "$(jq -er '.repository_id' "$proposal")" --arg team "$(jq -er '.team_id' "$proposal")" --argjson members "$(jq -c '.members' "$proposal")" '
  .schema == "pythonhk.team-signatures/v2"
  and .algorithm == "Ed25519-multisignature-v1"
  and .registration_id == $registration
  and .proposal_sha256 == $digest
  and (.signatures | type == "array" and length >= 1 and length <= 64)
  and ([.signatures[].github_id] | length == (unique | length) and . == (sort_by(tonumber)))
  and (.signatures | all(.[];
    . as $sig
    | (keys_unsorted | sort) == ["consent", "github_id", "key_id"]
    and ($sig.github_id | test("^[1-9][0-9]{0,19}$"))
    and ($sig.key_id | test("^[0-9a-f]{64}$"))
    and ($sig.consent | type == "object" and length > 0 and length <= 32)
    and ($sig.consent.kind == "team_consent")
    and ($sig.consent.actor_id == $sig.github_id)
    and ($sig.consent.event_id == $event)
    and (($sig.consent.base_repository.id | tostring) == $repository)
    and ($sig.consent.key_id == $sig.key_id)
    and ($sig.consent.signature.key_id == $sig.key_id)
    and ($sig.consent.team_id == $team)
    and ($sig.consent.proposal_digest == $eventctl_digest)
    and any($members[]; .github_id == $sig.github_id and .key_id == $sig.key_id)
  ))
' "$signatures" >/dev/null || event_die 'team signature envelope failed structural validation or does not bind the proposal'

member_count=$(jq -er '.members | length' "$proposal")
signature_count=$(jq -er '.signatures | length' "$signatures")
if ((signature_count == member_count)); then
	member_keys=$(jq -cS '[.members[] | {github_id, key_id}]' "$proposal")
	signature_keys=$(jq -cS '[.signatures[] | {github_id, key_id}]' "$signatures")
	[[ "$member_keys" == "$signature_keys" ]] || event_die 'complete signature envelope is not exactly the sorted proposal members'
fi
missing_count=$((member_count - signature_count))
if ((signature_count < member_count)); then
	status='PENDING_KEY_PROOFS'
	message="${signature_count}/${member_count} member signatures are present; proof PRs remain required"
else
	status='READY_TO_ACTIVATE'
	message='all proposal signatures are present; organizer activation is still required'
fi

if [[ -n "$status_out" ]]; then
	jq -n --arg status "$status" --arg message "$message" --argjson missing "$missing_count" \
		'{status:$status, missing_signature_count:$missing, message:$message}' > "$status_out"
fi
printf '%s\n' "$status"
