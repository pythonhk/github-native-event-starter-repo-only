#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'prepare-team-proof.sh --registration-id UUID --registration FILE --consent FILE --out FILE'
}

registration_id=''
registration=''
consent=''
output=''
while (($# > 0)); do
	case "$1" in
		--registration-id)
			(($# >= 2)) || usage
			registration_id=$2
			shift 2
			;;
		--registration)
			(($# >= 2)) || usage
			registration=$2
			shift 2
			;;
		--consent)
			(($# >= 2)) || usage
			consent=$2
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

[[ -n "$registration_id" && -n "$registration" && -n "$consent" && -n "$output" ]] || usage
event_uuid4 "$registration_id" || event_die 'registration ID must be UUIDv4'
event_require_command jq
event_require_file 'eventctl registration request' "$registration"
event_require_file 'eventctl team consent request' "$consent"
event_assert_canonical_json "$registration"
event_assert_canonical_json "$consent"

jq -e '
  .kind == "registration_request"
  and (.actor_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
  and (.participant_key.key_id == .key_id)
  and (.signature.key_id == .key_id)
  and (.base_repository.id | tostring | test("^[1-9][0-9]{0,19}$"))
' "$registration" >/dev/null || event_die 'registration request is not a valid eventctl proof-of-possession document'

jq -e '
  .kind == "team_consent"
  and (.actor_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.team_id | type == "string")
  and (.proposal_digest | type == "string" and test("^[0-9a-f]{64}$"))
  and (.signature.key_id == .key_id)
  and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
' "$consent" >/dev/null || event_die 'team consent is not a valid eventctl binding document'

registration_actor=$(jq -er '.actor_id' "$registration")
consent_actor=$(jq -er '.actor_id' "$consent")
[[ "$registration_actor" == "$consent_actor" ]] || event_die 'registration and team consent actors differ'
registration_key=$(jq -er '.key_id' "$registration")
consent_key=$(jq -er '.key_id' "$consent")
[[ "$registration_key" == "$consent_key" ]] || event_die 'registration and team consent keys differ'

jq -n -cS --arg schema 'pythonhk.key-proof/v2' --arg registration_id "$registration_id" \
	--slurpfile registration "$registration" --slurpfile consent "$consent" \
	'{schema:$schema, registration_id:$registration_id, registration:$registration[0], consent:$consent[0]}' > "$output"
event_assert_canonical_json "$output"
printf '%s\n' "prepared actor-bound team proof for $registration_actor"
