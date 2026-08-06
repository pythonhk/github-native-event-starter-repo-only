#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'register-user.sh --state FILE --identity-registry FILE --request FILE --actual-author ID --commit SHA --out-state FILE --out-identity-registry FILE [--eventctl PATH --config FILE --authority FILE --state-meta FILE --source-time RFC3339] [--plan-only]'
}

state=''
identity_registry=''
request=''
actual_author=''
commit_sha=''
out_state=''
out_identity_registry=''
eventctl=''
config=''
authority=''
state_meta=''
source_time=''
plan_only=false
while (($# > 0)); do
  case "$1" in
    --state) (($# >= 2)) || usage; state=$2; shift 2 ;;
    --identity-registry) (($# >= 2)) || usage; identity_registry=$2; shift 2 ;;
    --request) (($# >= 2)) || usage; request=$2; shift 2 ;;
    --actual-author) (($# >= 2)) || usage; actual_author=$2; shift 2 ;;
    --commit) (($# >= 2)) || usage; commit_sha=$2; shift 2 ;;
    --out-state) (($# >= 2)) || usage; out_state=$2; shift 2 ;;
    --out-identity-registry) (($# >= 2)) || usage; out_identity_registry=$2; shift 2 ;;
    --eventctl) (($# >= 2)) || usage; eventctl=$2; shift 2 ;;
    --config) (($# >= 2)) || usage; config=$2; shift 2 ;;
    --authority) (($# >= 2)) || usage; authority=$2; shift 2 ;;
    --state-meta) (($# >= 2)) || usage; state_meta=$2; shift 2 ;;
    --source-time) (($# >= 2)) || usage; source_time=$2; shift 2 ;;
    --plan-only) plan_only=true; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$state" && -n "$identity_registry" && -n "$request" && -n "$actual_author" && -n "$commit_sha" && -n "$out_state" && -n "$out_identity_registry" ]] || usage
[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || event_die 'registration commit must be a 40-character lowercase SHA'
if [[ "$plan_only" == false ]]; then
  [[ -n "$eventctl" && -n "$config" && -n "$authority" && -n "$state_meta" && -n "$source_time" ]] || \
    event_usage 'normal registration requires eventctl trust context; use --plan-only only for a local structural plan'
fi

event_require_command jq
event_require_file 'registry state' "$state"
event_require_file 'eventctl identity registry' "$identity_registry"
event_require_file 'registration request' "$request"
event_assert_canonical_json "$state"
event_assert_canonical_json "$identity_registry"
event_assert_canonical_json "$request"

bash "$SCRIPT_DIR/../actions/registration.sh" --request "$request" --actual-author "$actual_author" >/dev/null
phase=$(jq -er '.phase' "$state")
enabled=$(jq -er '.enabled' "$state")
[[ "$phase" == 'registration_open' || "$phase" == 'formation_open' ]] || event_die "registration is not open in phase $phase"
[[ "$enabled" == 'true' ]] || event_die 'event is disabled'

actor_id=$(jq -er '.actor_id' "$request")
key_id=$(jq -er '.key_id' "$request")
key_epoch=$(jq -er '.key_epoch' "$request")
event_id=$(jq -er '.event_id' "$request")
[[ "$actor_id" == "$actual_author" ]] || event_die 'registration actor does not equal authenticated author'
[[ "$event_id" == "$(jq -er '.event_id' "$state")" ]] || event_die 'registration belongs to a different event'

if [[ "$plan_only" == false ]]; then
  event_require_file 'eventctl binary' "$eventctl"
  [[ -x "$eventctl" ]] || event_die "eventctl binary is not executable: $eventctl"
  event_require_file 'signed event config' "$config"
  event_require_file 'protected organizer authority' "$authority"
  event_require_file 'protected state metadata' "$state_meta"
  verified=$(mktemp "${TMPDIR:-/tmp}/verified-registration.XXXXXX")
  trap 'rm -f -- "$verified"' EXIT
	"$eventctl" identity verify \
    --config "$config" --authority "$authority" --state-meta "$state_meta" \
		--request "$request" --expect-actor-id "$actual_author" --source-time "$source_time" --out "$verified" >/dev/null
fi

revision=$(jq -er '.revision' "$state")
new_revision=$((revision + 1))
registration_digest=$(event_json_digest "$request")
public_key=$(jq -er '.participant_key.public_key' "$request")
existing_user=$(jq -c --arg id "$actor_id" '(.users[$id] // null)' "$state")
if [[ "$existing_user" != 'null' ]]; then
	jq -e --arg id "$actor_id" --arg key "$key_id" --arg digest "$registration_digest" \
		'.users[$id].key_id == $key and .users[$id].proof_digest == $digest' "$state" >/dev/null || \
		event_die 'actor already has a different active registration'
	jq -e --arg id "$actor_id" 'any(.identities[]; .actor_id == $id)' "$identity_registry" >/dev/null || event_die 'state and identity registry disagree for exact registration replay'
	jq -e -cS . "$state" > "$out_state"
	jq -e -cS . "$identity_registry" > "$out_identity_registry"
	printf '%s\n' "exact registration replay returned actor $actor_id without a new registry revision"
	exit 0
fi
jq -e --arg id "$actor_id" 'all(.identities[]; .actor_id != $id)' "$identity_registry" >/dev/null || event_die 'actor already exists in the trusted identity registry'
tmp_state=$(mktemp "${TMPDIR:-/tmp}/event-registration-state.XXXXXX")
tmp_registry=$(mktemp "${TMPDIR:-/tmp}/event-registration-identities.XXXXXX")
trap 'rm -f -- "$tmp_state" "$tmp_registry"' EXIT
jq -c --argjson revision "$new_revision" --arg id "$actor_id" --arg key "$key_id" --arg public "$public_key" --arg proof "$registration_digest" --arg commit "$commit_sha" \
  '.revision = $revision | .users[$id] = {github_id:$id, key_id:$key, public_key:$public, proof_digest:$proof, registration_commit:$commit}' "$state" > "$tmp_state"
jq -c --arg id "$actor_id" --arg epoch "$key_epoch" --arg key "$key_id" --arg public "$public_key" \
  '.identities += [{actor_id:$id, key_epoch:$epoch, identity:{algorithm:"Ed25519", key_id:$key, public_key:$public}}] | .identities |= sort_by((.actor_id|tonumber),(.key_epoch|tonumber))' "$identity_registry" > "$tmp_registry"
jq -e -cS . "$tmp_state" > "$out_state" || event_die 'failed to produce canonical registry state'
jq -e -cS . "$tmp_registry" > "$out_identity_registry" || event_die 'failed to produce canonical identity registry'
rm -f -- "$tmp_state" "$tmp_registry"
if [[ "$plan_only" == true ]]; then
  printf '%s\n' "planned structural registration for actor $actor_id at registry revision $new_revision (cryptographic verification not run)"
else
  printf '%s\n' "registered actor $actor_id at registry revision $new_revision"
fi
