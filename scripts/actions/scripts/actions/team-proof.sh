#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'team-proof.sh --proposal FILE --proof FILE --actual-author ID'
}

proposal=''
proof=''
actual_author=''
while (($# > 0)); do
	case "$1" in
		--proposal)
			(($# >= 2)) || usage
			proposal=$2
			shift 2
			;;
		--proof)
			(($# >= 2)) || usage
			proof=$2
			shift 2
			;;
		--actual-author)
			(($# >= 2)) || usage
			actual_author=$2
			shift 2
			;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$proposal" && -n "$proof" && -n "$actual_author" ]] || usage
event_require_command jq
event_require_file 'team proposal' "$proposal"
event_require_file 'member key proof' "$proof"
event_assert_canonical_json "$proposal"
event_assert_canonical_json "$proof"
event_decimal_id "$actual_author" || event_die 'actual PR author ID is invalid'

jq -e '
  .schema == "pythonhk.key-proof/v2"
  and (.registration_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.registration | type == "object" and length > 0 and length <= 32)
  and (.consent | type == "object" and length > 0 and length <= 32)
' "$proof" >/dev/null || event_die 'member key proof failed strict structural validation'

claimed_id=$(jq -er '.registration.actor_id' "$proof")
[[ "$claimed_id" == "$actual_author" ]] || event_die "proof actor mismatch: claimed $claimed_id, authenticated PR author $actual_author"

proposal_registration=$(jq -er '.registration_id' "$proposal")
proof_registration=$(jq -er '.registration_id' "$proof")
[[ "$proposal_registration" == "$proof_registration" ]] || event_die 'proof is bound to a different registration'

jq -e --arg id "$claimed_id" 'any(.members[]; .github_id == $id)' "$proposal" >/dev/null || \
	event_die 'proof actor is not a member of the proposal'

proposal_key=$(jq -er --arg id "$claimed_id" '.members[] | select(.github_id == $id) | .key_id' "$proposal")
proposal_public_key=$(jq -er --arg id "$claimed_id" '.members[] | select(.github_id == $id) | .public_key' "$proposal")
proof_key=$(jq -er '.registration.key_id' "$proof")
[[ "$proposal_key" == "$proof_key" ]] || event_die 'proof key does not match the exact proposal member key'

eventctl_proposal=$(mktemp "${TMPDIR:-/tmp}/eventctl-proposal.XXXXXX")
trap 'rm -f -- "$eventctl_proposal"' EXIT
jq -e -cS '.eventctl_proposal' "$proposal" > "$eventctl_proposal" || event_die 'proposal has no embedded eventctl proposal'
eventctl_proposal_digest=$(event_json_digest "$eventctl_proposal")
event_id=$(jq -er '.event_id' "$proposal")
repository_id=$(jq -er '.repository_id' "$proposal")
team_id=$(jq -er '.team_id' "$proposal")
jq -e --arg event "$event_id" --arg repository "$repository_id" --arg id "$claimed_id" --arg team "$team_id" --arg proposal_digest "$eventctl_proposal_digest" --arg key "$proposal_key" --arg public_key "$proposal_public_key" '
  .registration.kind == "registration_request"
  and (.registration.actor_id | test("^[1-9][0-9]{0,19}$"))
  and .registration.actor_id == $id
  and .registration.event_id == $event
  and (.registration.base_repository.id | tostring) == $repository
  and .registration.key_id == $key
  and .registration.participant_key.key_id == $key
  and .registration.participant_key.public_key == $public_key
  and .registration.signature.key_id == $key
  and .consent.kind == "team_consent"
  and .consent.actor_id == $id
  and .consent.event_id == $event
  and (.consent.base_repository.id | tostring) == $repository
  and .consent.team_id == $team
  and .consent.key_id == $key
  and .consent.signature.key_id == $key
  and .consent.proposal_digest == $proposal_digest
' "$proof" >/dev/null || event_die 'member proof does not bind event, repository, team, proposal digest, and exact key'

printf '%s\n' 'key proof structurally valid and actor-bound'
