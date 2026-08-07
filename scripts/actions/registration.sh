#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
	event_usage 'registration.sh --request FILE --actual-author ID'
}

request=''
actual_author=''
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
		-h|--help) usage ;;
		*) usage ;;
	esac
done

[[ -n "$request" && -n "$actual_author" ]] || usage
event_require_command jq
event_require_file 'registration request' "$request"
event_assert_canonical_json "$request"
event_decimal_id "$actual_author" || event_die 'actual PR author ID is invalid'

jq -e --arg key "$(jq -er '.key_id' "$request")" '
  .kind == "registration_request"
  and (.actor_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.key_id | type == "string" and test("^[0-9a-f]{64}$"))
  and (.key_epoch | type == "string" and test("^[1-9][0-9]{0,9}$"))
  and (.event_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{2,63}$"))
  and (.base_repository.id | tostring | test("^[1-9][0-9]{0,19}$"))
  and (.participant_key | type == "object" and .key_id == $key and (.public_key | type == "string" and length >= 1 and length <= 256))
  and (.signature | type == "object" and .key_id == $key)
' "$request" >/dev/null || event_die 'registration request failed strict structural validation'

claimed_id=$(jq -er '.actor_id' "$request")
[[ "$claimed_id" == "$actual_author" ]] || event_die "registration actor mismatch: claimed $claimed_id, authenticated PR author $actual_author"
printf '%s\n' 'registration request structurally valid and actor-bound'
