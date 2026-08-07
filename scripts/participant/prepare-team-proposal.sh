#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'prepare-team-proposal.sh --eventctl-proposal FILE --members FILE --out FILE'
}

eventctl_proposal=''
members=''
output=''
while (($# > 0)); do
	case "$1" in
		--eventctl-proposal)
			(($# >= 2)) || usage
			eventctl_proposal=$2
			shift 2
			;;
		--members)
			(($# >= 2)) || usage
			members=$2
			shift 2
			;;
		--out)
			(($# >= 2)) || usage
			output=$2
			shift 2
			;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$eventctl_proposal" && -n "$members" && -n "$output" ]] || usage
event_require_command jq
event_require_file 'eventctl team proposal' "$eventctl_proposal"
event_require_file 'team member manifest' "$members"
event_assert_canonical_json "$eventctl_proposal"
event_assert_canonical_json "$members"

jq -e '
  .kind == "team_proposal"
  and (.event_id | type == "string")
  and (.operation_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.team_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.proposer_actor_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.member_actor_ids | type == "array" and length >= 1 and length <= 64 and all(test("^[1-9][0-9]{0,19}$")) and . == (sort_by(tonumber)))
  and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
  and (.issued_at | type == "string")
  and (.expires_at | type == "string")
' "$eventctl_proposal" >/dev/null || event_die 'eventctl proposal is not structurally valid'

jq -e '
  type == "array" and length >= 1 and length <= 64
  and all(.[];
    type == "object"
    and (keys_unsorted | sort) == ["github_id", "key_id", "public_key", "role"]
    and (.github_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
    and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.public_key | type == "string" and length >= 1 and length <= 256)
    and (.role == "captain" or .role == "member")
  )
  and ([.[].github_id] | length == (unique | length) and . == (sort_by(tonumber)))
  and ([.[].role] | map(select(. == "captain")) | length == 1)
' "$members" >/dev/null || event_die 'team member manifest is not strict sorted member data'

jq -e --arg proposer "$(jq -er '.proposer_actor_id' "$eventctl_proposal")" --slurpfile member_doc "$members" '
  .member_actor_ids == ($member_doc[0] | map(.github_id))
  and .proposer_actor_id == ($member_doc[0] | map(select(.role == "captain") | .github_id) | .[0])
  and .proposer_actor_id == $proposer
  and .key_id == ($member_doc[0] | map(select(.github_id == $proposer) | .key_id) | .[0])
' "$eventctl_proposal" >/dev/null || event_die 'eventctl proposal and member manifest disagree'

jq -n -cS --slurpfile proposal "$eventctl_proposal" --slurpfile member_doc "$members" \
	'{schema:"pythonhk.team-proposal/v2",
	 event_id:$proposal[0].event_id,
	 repository_id:($proposal[0].base_repository.id | tostring),
	 registration_id:$proposal[0].operation_id,
	 team_id:$proposal[0].team_id,
	 proposer_github_id:$proposal[0].proposer_actor_id,
	 members:$member_doc[0],
	 eventctl_proposal:$proposal[0],
	 issued_at:$proposal[0].issued_at,
	 expires_at:$proposal[0].expires_at}' > "$output"
event_assert_canonical_json "$output"
printf '%s\n' "prepared repository team manifest for $(jq -er '.team_id' "$eventctl_proposal")"
