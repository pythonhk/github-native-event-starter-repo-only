#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'bundle-team-signatures.sh --proposal FILE --consent-dir DIR --out FILE'
}

proposal=''
consent_dir=''
output=''
while (($# > 0)); do
	case "$1" in
		--proposal)
			(($# >= 2)) || usage
			proposal=$2
			shift 2
			;;
		--consent-dir)
			(($# >= 2)) || usage
			consent_dir=$2
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

[[ -n "$proposal" && -n "$consent_dir" && -n "$output" ]] || usage
event_require_command jq
event_require_file 'team proposal' "$proposal"
event_require_directory 'consent directory' "$consent_dir"
event_assert_canonical_json "$proposal"

proposal_digest=$(event_json_digest "$proposal")
registration_id=$(jq -er '.registration_id' "$proposal")
eventctl_proposal=$(mktemp "${TMPDIR:-/tmp}/eventctl-proposal.XXXXXX")
trap 'rm -f -- "$eventctl_proposal"' EXIT
jq -e -cS '.eventctl_proposal' "$proposal" > "$eventctl_proposal" || event_die 'proposal has no embedded eventctl proposal'
eventctl_proposal_digest=$(event_json_digest "$eventctl_proposal")
member_count=$(jq -er '.members | length' "$proposal")
entries='[]'
for member_id in $(jq -er '.members[].github_id' "$proposal"); do
	consent_file="$consent_dir/${member_id}.json"
	event_require_file "consent for $member_id" "$consent_file"
	event_assert_canonical_json "$consent_file"
	jq -e --arg id "$member_id" --arg digest "$eventctl_proposal_digest" \
		'.kind == "team_consent" and .actor_id == $id and .proposal_digest == $digest' \
		"$consent_file" >/dev/null || event_die "consent $member_id does not bind the exact proposal"
	key_id=$(jq -er '.key_id' "$consent_file")
	proposal_key=$(jq -er --arg id "$member_id" '.members[] | select(.github_id == $id) | .key_id' "$proposal")
	[[ "$proposal_key" == "$key_id" ]] || event_die "consent $member_id key does not match the proposal member key"
	entries=$(jq -c --arg id "$member_id" --arg key "$key_id" --slurpfile consent "$consent_file" \
		'. + [{github_id:$id, key_id:$key, consent:$consent[0]}]' <<< "$entries")
done

jq -n -cS --arg schema 'pythonhk.team-signatures/v2' --arg registration "$registration_id" \
	--arg digest "$proposal_digest" --arg algorithm 'Ed25519-multisignature-v1' \
	--argjson signatures "$entries" \
	'{schema:$schema, registration_id:$registration, proposal_sha256:$digest, algorithm:$algorithm, signatures:$signatures}' > "$output"
event_assert_canonical_json "$output"
printf '%s\n' "bundled $member_count explicit member signatures"
