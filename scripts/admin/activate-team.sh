#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'activate-team.sh --state FILE --proposal FILE --signatures FILE --proof-dir DIR --commit SHA --out FILE [--proof-source-times FILE --source-time RFC3339 --eventctl PATH --config FILE --authority FILE --state-meta FILE --identity-registry FILE] [--plan-only]'
}

state=''
proposal=''
signatures=''
proof_dir=''
commit_sha=''
output=''
eventctl=''
config=''
authority=''
state_meta=''
identity_registry=''
source_time=''
proof_source_times=''
plan_only=false
while (($# > 0)); do
  case "$1" in
    --state)
      (($# >= 2)) || usage
      state=$2
      shift 2
      ;;
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
    --proof-dir)
      (($# >= 2)) || usage
      proof_dir=$2
      shift 2
      ;;
    --commit)
      (($# >= 2)) || usage
      commit_sha=$2
      shift 2
      ;;
    --out)
      (($# >= 2)) || usage
      output=$2
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
    --source-time)
      (($# >= 2)) || usage
      source_time=$2
      shift 2
      ;;
    --proof-source-times)
      (($# >= 2)) || usage
      proof_source_times=$2
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

[[ -n "$state" && -n "$proposal" && -n "$signatures" && -n "$proof_dir" && -n "$commit_sha" && -n "$output" ]] || usage
[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || event_die 'activation commit must be a 40-character lowercase SHA'
if [[ "$plan_only" == false ]]; then
  [[ -n "$eventctl" && -n "$config" && -n "$authority" && -n "$state_meta" && -n "$identity_registry" && -n "$source_time" && -n "$proof_source_times" ]] || \
    event_usage 'normal activation requires eventctl trust context and proof source times; use --plan-only only for a local structural plan'
fi

event_require_command jq
event_require_file 'registry state' "$state"
event_require_file 'team proposal' "$proposal"
event_require_file 'team signature envelope' "$signatures"
event_require_directory 'proof directory' "$proof_dir"
event_assert_canonical_json "$state"
event_assert_canonical_json "$proposal"
event_assert_canonical_json "$signatures"

jq -e '
  .schema == "pythonhk.registry-state/v2"
  and (.event_id | type == "string")
  and (.phase | type == "string")
  and (.enabled | type == "boolean")
  and (.revision | type == "number" and floor == . and . >= 0)
  and (.users | type == "object")
  and (.teams | type == "object")
  and (.memberships | type == "object")
  and (.attempts | type == "object")
' "$state" >/dev/null || event_die 'registry state failed strict structural validation'

bash "$SCRIPT_DIR/../actions/team-proposal.sh" --proposal "$proposal" --signatures "$signatures" >/dev/null

phase=$(jq -er '.phase' "$state")
enabled=$(jq -er '.enabled' "$state")
[[ "$phase" == 'formation_open' ]] || event_die "team activation requires formation_open, got $phase"
[[ "$enabled" == 'true' ]] || event_die 'event is disabled'

event_id=$(jq -er '.event_id' "$proposal")
state_event_id=$(jq -er '.event_id' "$state")
[[ "$event_id" == "$state_event_id" ]] || event_die 'proposal and registry belong to different events'
team_id=$(jq -er '.team_id' "$proposal")
jq -e --arg team "$team_id" '(.teams[$team] // null) == null' "$state" >/dev/null || event_die 'team ID is already active'

member_count=$(jq -er '.members | length' "$proposal")
signature_count=$(jq -er '.signatures | length' "$signatures")
[[ "$member_count" -eq "$signature_count" ]] || event_die 'activation requires one signature entry for every member'

proof_digests='{}'
for member_id in $(jq -er '.members[].github_id' "$proposal"); do
  proof_file="$proof_dir/${member_id}.json"
  event_require_file "key proof for $member_id" "$proof_file"
  bash "$SCRIPT_DIR/../actions/team-proof.sh" --proposal "$proposal" --proof "$proof_file" --actual-author "$member_id" >/dev/null
  proof_digest=$(event_json_digest "$proof_file")
  proof_digests=$(jq -c --arg id "$member_id" --arg digest "$proof_digest" '. + {($id):$digest}' <<< "$proof_digests")
done

member_ids=$(jq -er -c '.members | map(.github_id)' "$proposal")
signature_ids=$(jq -er -c '.signatures | map(.github_id)' "$signatures")
[[ "$member_ids" == "$signature_ids" ]] || event_die 'signature entries are not exactly the sorted proposal members'

for member_id in $(jq -er '.members[].github_id' "$proposal"); do
  jq -e --arg id "$member_id" '(.memberships[$id] // null) == null' "$state" >/dev/null || \
    event_die "member $member_id is already active in another team"
done

if [[ "$plan_only" == false ]]; then
  event_require_file 'eventctl binary' "$eventctl"
  [[ -x "$eventctl" ]] || event_die "eventctl binary is not executable: $eventctl"
  event_require_file 'signed event config' "$config"
  event_require_file 'protected organizer authority' "$authority"
  event_require_file 'protected state metadata' "$state_meta"
  event_require_file 'eventctl identity registry' "$identity_registry"
  event_require_file 'proof source-time metadata' "$proof_source_times"
  event_assert_canonical_json "$proof_source_times"
  jq -e --argjson ids "$member_ids" '
    . as $root
    | type == "object"
    and all($ids[]; . as $id | $root[$id] | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
  ' "$proof_source_times" >/dev/null || event_die 'proof source-time metadata must map every member ID to an RFC3339 time'

  proposal_doc=$(mktemp "${TMPDIR:-/tmp}/eventctl-proposal.XXXXXX")
  verified_proposal=$(mktemp "${TMPDIR:-/tmp}/verified-proposal.XXXXXX")
  trap 'rm -f -- "$proposal_doc" "$verified_proposal"' EXIT
  jq -e -cS '.eventctl_proposal' "$proposal" > "$proposal_doc" || event_die 'cannot extract embedded eventctl proposal'
  "$eventctl" team verify \
    --config "$config" --authority "$authority" --state-meta "$state_meta" --registry "$identity_registry" \
    --request "$proposal_doc" --source-time "$source_time" --out "$verified_proposal" >/dev/null

  for member_id in $(jq -er '.members[].github_id' "$proposal"); do
    proof_file="$proof_dir/${member_id}.json"
    registration_doc=$(mktemp "${TMPDIR:-/tmp}/eventctl-registration.XXXXXX")
    consent_doc=$(mktemp "${TMPDIR:-/tmp}/eventctl-consent.XXXXXX")
    verified_registration=$(mktemp "${TMPDIR:-/tmp}/verified-registration.XXXXXX")
    verified_consent=$(mktemp "${TMPDIR:-/tmp}/verified-consent.XXXXXX")
    jq -e -cS '.registration' "$proof_file" > "$registration_doc"
    jq -e -cS '.consent' "$proof_file" > "$consent_doc"
    member_source_time=$(jq -er --arg id "$member_id" '.[$id]' "$proof_source_times")
    "$eventctl" identity verify \
      --config "$config" --authority "$authority" --state-meta "$state_meta" \
      --request "$registration_doc" --expect-actor-id "$member_id" --source-time "$member_source_time" \
      --out "$verified_registration" >/dev/null
    "$eventctl" team verify \
      --config "$config" --authority "$authority" --state-meta "$state_meta" --registry "$identity_registry" \
      --request "$consent_doc" --proposal "$verified_proposal" --source-time "$member_source_time" \
      --out "$verified_consent" >/dev/null
    jq -e --arg id "$member_id" --slurpfile proof_consent "$consent_doc" \
      'any(.signatures[]; .github_id == $id and .consent == $proof_consent[0])' "$signatures" >/dev/null || \
      event_die "signature envelope consent does not match proof $member_id"
    rm -f -- "$registration_doc" "$consent_doc" "$verified_registration" "$verified_consent"
  done
fi

revision=$(jq -er '.revision' "$state")
new_revision=$((revision + 1))
manifest_digest=$(event_json_digest "$proposal")
eventctl_proposal_file=$(mktemp "${TMPDIR:-/tmp}/eventctl-proposal-state.XXXXXX")
trap 'rm -f -- "$eventctl_proposal_file"' EXIT
jq -e -cS '.eventctl_proposal' "$proposal" > "$eventctl_proposal_file"
proposal_digest=$(event_json_digest "$eventctl_proposal_file")
tmp_output=$(mktemp "${TMPDIR:-/tmp}/event-activated-state.XXXXXX")

jq --arg team "$team_id" --arg commit "$commit_sha" --arg proposal_digest "$proposal_digest" --arg manifest_digest "$manifest_digest" --argjson revision "$new_revision" --argjson proof_digests "$proof_digests" \
  --slurpfile proposal_doc "$proposal" \
  ' .revision = $revision
  | .teams[$team] = {
      team_id: $team,
      member_ids: ($proposal_doc[0].members | map(.github_id)),
      proposal_digest: $proposal_digest,
      manifest_digest: $manifest_digest,
      activation_commit: $commit,
      proof_digests: $proof_digests
    }
  | reduce $proposal_doc[0].members[] as $member (.;
      .users[$member.github_id] = {
        github_id: $member.github_id,
        key_id: $member.key_id,
        public_key: $member.public_key,
        proof_digest: $proof_digests[$member.github_id]
      }
      | .memberships[$member.github_id] = $team
    )' "$state" > "$tmp_output"

jq -e -cS . "$tmp_output" > "$output" || {
  rm -f -- "$tmp_output"
  event_die 'failed to produce canonical activated registry state'
}
rm -f -- "$tmp_output"
if [[ "$plan_only" == true ]]; then
  printf '%s\n' "planned structural activation for $team_id at registry revision $new_revision (cryptographic verification not run)"
else
  printf '%s\n' "activated team $team_id at registry revision $new_revision"
fi
