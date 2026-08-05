#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"

fail() {
  printf 'security-test failure: %s\n' "$*" >&2
  exit 1
}
pass() {
  printf 'ok: %s\n' "$*"
}
expect_fail() {
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $*"
  fi
}
expect_contains() {
  local needle=$1
  local file=$2
  grep -F -- "$needle" "$file" >/dev/null || fail "missing $needle in $file"
}

event_require_command jq
event_require_command bash
bash -n "$ROOT"/scripts/lib/common.sh "$ROOT"/scripts/actions/*.sh "$ROOT"/scripts/admin/*.sh "$ROOT"/scripts/participant/*.sh "$ROOT"/tools/install-eventctl.sh
"$ROOT/tools/verify-eventctl-lock.sh" >/dev/null
for schema in "$ROOT"/protocol/schemas/v2/*.json; do
  jq -e . "$schema" >/dev/null
done
pass 'shell syntax, lock manifest, and JSON schema files'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pythonhk-event-security.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

canonical() {
  jq -cS . "$1" > "$2"
}

canonical "$ROOT/tests/fixtures/team.json" "$tmp/team.json"
eventctl_proposal_file="$tmp/eventctl-proposal.json"
jq -e -cS '.eventctl_proposal' "$tmp/team.json" > "$eventctl_proposal_file"
proposal_digest=$(event_json_digest "$tmp/team.json")
eventctl_digest=$(event_json_digest "$eventctl_proposal_file")

canonical "$ROOT/tests/fixtures/signatures.json" "$tmp/signatures-template.json"
jq -cS --arg digest "$proposal_digest" --arg eventctl_digest "$eventctl_digest" \
  '.proposal_sha256=$digest | .signatures |= map(.consent.proposal_digest=$eventctl_digest)' \
  "$tmp/signatures-template.json" > "$tmp/signatures-pending.json"
pending_output="$tmp/pending.out"
bash "$ROOT/scripts/actions/team-proposal.sh" --proposal "$tmp/team.json" --signatures "$tmp/signatures-pending.json" > "$pending_output"
expect_contains 'PENDING_KEY_PROOFS' "$pending_output"
pass 'incomplete team signature set remains pending'

jq -cS --arg digest "$proposal_digest" --arg eventctl_digest "$eventctl_digest" \
  '.proposal_sha256=$digest | .signatures |= (map(.consent.proposal_digest=$eventctl_digest) + [{github_id:"103",key_id:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",consent:{kind:"team_consent",event_id:"demo-event-2026",actor_id:"103",base_repository:{id:"123456789"},team_id:"22222222-2222-4222-8222-222222222222",key_id:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",proposal_digest:$eventctl_digest,signature:{key_id:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}}])' \
  "$tmp/signatures-template.json" > "$tmp/signatures-complete.json"
ready_output="$tmp/ready.out"
bash "$ROOT/scripts/actions/team-proposal.sh" --proposal "$tmp/team.json" --signatures "$tmp/signatures-complete.json" > "$ready_output"
expect_contains 'READY_TO_ACTIVATE' "$ready_output"
pass 'complete team signature set is activation-ready'

mkdir "$tmp/proofs"
for id in 101 102 103; do
  jq -cS --arg digest "$eventctl_digest" '.consent.proposal_digest=$digest' "$ROOT/tests/fixtures/proofs/$id.json" > "$tmp/proofs/$id.json"
done
bash "$ROOT/scripts/actions/team-proof.sh" --proposal "$tmp/team.json" --proof "$tmp/proofs/101.json" --actual-author 101 >/dev/null
expect_fail bash "$ROOT/scripts/actions/team-proof.sh" --proposal "$tmp/team.json" --proof "$tmp/proofs/101.json" --actual-author 102
jq -cS '.registration.participant_key.public_key="COPIED-PUBLIC-KEY"' "$tmp/proofs/101.json" > "$tmp/proofs/101-wrong-key.json"
expect_fail bash "$ROOT/scripts/actions/team-proof.sh" --proposal "$tmp/team.json" --proof "$tmp/proofs/101-wrong-key.json" --actual-author 101
pass 'copied member proof is rejected by authenticated actor binding'

mkdir "$tmp/consents"
for id in 101 102 103; do
  jq -cS '.consent' "$tmp/proofs/$id.json" > "$tmp/consents/$id.json"
done
bash "$ROOT/scripts/participant/bundle-team-signatures.sh" --proposal "$tmp/team.json" --consent-dir "$tmp/consents" --out "$tmp/bundled-signatures.json" >/dev/null
canonical "$tmp/bundled-signatures.json" "$tmp/signatures-complete.json"
bash "$ROOT/scripts/actions/team-proposal.sh" --proposal "$tmp/team.json" --signatures "$tmp/signatures-complete.json" >/dev/null
pass 'participant helpers produce the deterministic signature envelope'

jq -cS '.registration + {key_epoch:"1", participant_key:{key_id:.registration.key_id,public_key:"PUB101"}, signature:{key_id:.registration.key_id}, base_repository:{id:"123456789"}}' "$ROOT/tests/fixtures/proofs/101.json" > "$tmp/registration.json"
bash "$ROOT/scripts/actions/registration.sh" --request "$tmp/registration.json" --actual-author 101 >/dev/null
expect_fail bash "$ROOT/scripts/actions/registration.sh" --request "$tmp/registration.json" --actual-author 999
pass 'registration request is actor-bound'

jq -n '{repository:{id:123456789,owner:{login:"pythonhk"},name:"event"},pull_request:{number:17,id:1700000000000000000,user:{id:101},base:{ref:"main"},head:{ref:"submission",sha:"0123456789012345678901234567890123456789",repo:{id:987654321,owner:{login:"participant"}}}}}' > "$tmp/github-event.json"
bash "$ROOT/scripts/admin/prepare-pr-metadata.sh" --github-event "$tmp/github-event.json" --out "$tmp/pr-metadata.json" >/dev/null
jq -e '.kind == "github_pr_metadata" and .actor_id == "101" and .pull_request.base_repository_id == "123456789" and .pull_request.head_owner == "participant"' "$tmp/pr-metadata.json" >/dev/null
pass 'GitHub pull-request metadata is projected into the eventctl transport shape'

jq -cS '.event_id="demo-event-2026" | .phase="registration_open" | .enabled=true | .revision=0 | .users={} | .teams={} | .memberships={}' "$ROOT/registry/state.json" > "$tmp/registration-state.json"
canonical "$ROOT/registry/identity-registry.json" "$tmp/identity-registry.json"
bash "$ROOT/scripts/admin/register-user.sh" --state "$tmp/registration-state.json" --identity-registry "$tmp/identity-registry.json" --request "$tmp/registration.json" --actual-author 101 --commit 0123456789012345678901234567890123456789 --out-state "$tmp/registered-state.json" --out-identity-registry "$tmp/registered-identities.json" --plan-only >/dev/null
jq -e '.users["101"].key_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$tmp/registered-state.json" >/dev/null
jq -e '.identities[0].actor_id == "101"' "$tmp/registered-identities.json" >/dev/null
bash "$ROOT/scripts/admin/register-user.sh" --state "$tmp/registered-state.json" --identity-registry "$tmp/registered-identities.json" --request "$tmp/registration.json" --actual-author 101 --commit 0123456789012345678901234567890123456789 --out-state "$tmp/registered-replay-state.json" --out-identity-registry "$tmp/registered-replay-identities.json" --plan-only >/dev/null
cmp -s "$tmp/registered-state.json" "$tmp/registered-replay-state.json" || fail 'exact registration replay changed state'
pass 'organizer registration plan updates both public registries'

canonical "$ROOT/tests/fixtures/registry-active.json" "$tmp/submission-state.json"
printf 'encrypted test bundle\n' > "$tmp/bundle.eventctl"
bundle_digest=$(event_sha256_file "$tmp/bundle.eventctl")
jq -cS --arg digest "$bundle_digest" '.bundle_sha256=$digest | .eventctl_request.bundle.sha256=$digest' "$ROOT/tests/fixtures/submission.json" > "$tmp/submission.json"
submission_args=(--request "$tmp/submission.json" --registry "$tmp/submission-state.json" --bundle "$tmp/bundle.eventctl" --actual-author 101 --actual-pr 17 --actual-pr-id 1700000000000000000 --actual-fork-repository-id 987654321 --actual-head-owner participant --actual-head-branch main --actual-head-sha 0123456789012345678901234567890123456789)
bash "$ROOT/scripts/actions/submission.sh" "${submission_args[@]}" >/dev/null
bad_actor_args=(--request "$tmp/submission.json" --registry "$tmp/submission-state.json" --bundle "$tmp/bundle.eventctl" --actual-author 999 --actual-pr 17 --actual-pr-id 1700000000000000000 --actual-fork-repository-id 987654321 --actual-head-owner participant --actual-head-branch main --actual-head-sha 0123456789012345678901234567890123456789)
expect_fail bash "$ROOT/scripts/actions/submission.sh" "${bad_actor_args[@]}"
# Explicitly alter immutable head metadata rather than relying on array substitution.
bad_pr_args=(--request "$tmp/submission.json" --registry "$tmp/submission-state.json" --bundle "$tmp/bundle.eventctl" --actual-author 101 --actual-pr 18 --actual-pr-id 1700000000000000000 --actual-fork-repository-id 987654321 --actual-head-owner participant --actual-head-branch main --actual-head-sha 0123456789012345678901234567890123456789)
expect_fail bash "$ROOT/scripts/actions/submission.sh" "${bad_pr_args[@]}"
jq -cS '.eventctl_request.pull_request.number=999' "$tmp/submission.json" > "$tmp/submission-inner-pr-mismatch.json"
inner_pr_args=(--request "$tmp/submission-inner-pr-mismatch.json" --registry "$tmp/submission-state.json" --bundle "$tmp/bundle.eventctl" --actual-author 101 --actual-pr 17 --actual-pr-id 1700000000000000000 --actual-fork-repository-id 987654321 --actual-head-owner participant --actual-head-branch main --actual-head-sha 0123456789012345678901234567890123456789)
expect_fail bash "$ROOT/scripts/actions/submission.sh" "${inner_pr_args[@]}"
pass 'submission actor and immutable PR bindings reject replay substitution'

bash "$ROOT/scripts/admin/apply-submission.sh" --state "$tmp/submission-state.json" --request "$tmp/submission.json" --actual-author 101 --pr 17 --bundle "$tmp/bundle.eventctl" --out "$tmp/submission-applied.json" --plan-only >/dev/null
bash "$ROOT/scripts/admin/apply-submission.sh" --state "$tmp/submission-applied.json" --request "$tmp/submission.json" --actual-author 101 --pr 17 --bundle "$tmp/bundle.eventctl" --out "$tmp/submission-replay.json" --plan-only >/dev/null
cmp -s "$tmp/submission-applied.json" "$tmp/submission-replay.json" || fail 'exact submission replay changed state'
printf 'altered replay bundle\n' > "$tmp/altered-bundle.eventctl"
replay_args=(--request "$tmp/submission.json" --registry "$tmp/submission-applied.json" --bundle "$tmp/altered-bundle.eventctl" --actual-author 101 --actual-pr 17 --actual-pr-id 1700000000000000000 --actual-fork-repository-id 987654321 --actual-head-owner participant --actual-head-branch main --actual-head-sha 0123456789012345678901234567890123456789)
expect_fail bash "$ROOT/scripts/actions/submission.sh" "${replay_args[@]}"
pass 'exact submission replay is idempotent'

jq -cS '.attempt_id="44444444-4444-4444-8444-444444444444" | .eventctl_request.attempt_id="44444444-4444-4444-8444-444444444444"' "$tmp/submission.json" > "$tmp/submission-fresh.json"
bash "$ROOT/scripts/admin/apply-submission.sh" --state "$tmp/submission-applied.json" --request "$tmp/submission-fresh.json" --actual-author 101 --pr 17 --bundle "$tmp/bundle.eventctl" --out "$tmp/submission-fresh-state.json" --plan-only >/dev/null
jq -e '.attempts | length == 2' "$tmp/submission-fresh-state.json" >/dev/null
pass 'same bundle with a fresh attempt ID is admitted separately'

printf '{"score":42,"grader":"isolated-test"}\n' > "$tmp/score.payload.json"
score_payload_digest=$(event_sha256_file "$tmp/score.payload.json")
score_attempt_digest=$(jq -er '.attempts["33333333-3333-4333-8333-333333333333"].request_digest' "$tmp/submission-applied.json")
jq -n -cS --arg digest "$score_payload_digest" --arg attempt_digest "$score_attempt_digest" '{schema:"pythonhk.scoring-result/v2",event_id:"demo-event-2026",attempt_id:"33333333-3333-4333-8333-333333333333",team_id:"22222222-2222-4222-8222-222222222222",status:"accepted",payload_sha256:$digest,scorer_id:"isolated-test",scorer_version:"1.0.0",source_attempt_digest:$attempt_digest,issued_at:"2026-08-06T00:00:00Z"}' > "$tmp/score.result.json"
jq -cS '.scoring.enabled=true | .scoring.scorer_id="isolated-test" | .scoring.scorer_version="1.0.0"' "$tmp/submission-applied.json" > "$tmp/scoring-state.json"
bash "$ROOT/scripts/scoring/validate-result.sh" --state "$tmp/scoring-state.json" --result "$tmp/score.result.json" --payload "$tmp/score.payload.json" >/dev/null
bash "$ROOT/scripts/admin/apply-score.sh" --state "$tmp/scoring-state.json" --result "$tmp/score.result.json" --payload "$tmp/score.payload.json" --commit 0123456789012345678901234567890123456789 --out "$tmp/scored-state.json" >/dev/null
jq -e '.results["33333333-3333-4333-8333-333333333333"].status == "accepted" and .attempts["33333333-3333-4333-8333-333333333333"].status == "completed"' "$tmp/scored-state.json" >/dev/null
expect_fail bash "$ROOT/scripts/admin/apply-score.sh" --state "$tmp/scored-state.json" --result "$tmp/score.result.json" --payload "$tmp/score.payload.json" --commit 0123456789012345678901234567890123456789 --out "$tmp/score-duplicate.json"
pass 'isolated scoring result is payload-bound and single-application'

bash "$ROOT/scripts/admin/rebuild-views.sh" --state "$tmp/submission-fresh-state.json" --users-out "$tmp/users-index.json" --teams-out "$tmp/teams-index.json" --memberships-out "$tmp/memberships-index.json" --submissions-out "$tmp/submissions-index.json" >/dev/null
jq -e '.users["101"].github_id == "101"' "$tmp/users-index.json" >/dev/null
jq -e '.attempts | length == 2' "$tmp/submissions-index.json" >/dev/null
pass 'derived public registry views are rebuilt from one authoritative state'

jq -cS . "$ROOT/registry/state.json" > "$tmp/lifecycle-state.json"
bash "$ROOT/scripts/admin/set-lifecycle.sh" --state "$tmp/lifecycle-state.json" --phase registration_open --enabled true --reason '' --commit 0123456789012345678901234567890123456789 --out "$tmp/lifecycle-open.json" >/dev/null
bash "$ROOT/scripts/admin/set-lifecycle.sh" --state "$tmp/lifecycle-open.json" --phase frozen --enabled false --reason 'organizer shutdown' --commit 0123456789012345678901234567890123456789 --out "$tmp/lifecycle-frozen.json" >/dev/null
jq -e '.phase == "frozen" and .enabled == false and .disabled_reason == "organizer shutdown"' "$tmp/lifecycle-frozen.json" >/dev/null
expect_fail bash "$ROOT/scripts/admin/set-lifecycle.sh" --state "$tmp/lifecycle-frozen.json" --phase formation_open --enabled true --reason '' --commit 0123456789012345678901234567890123456789 --out "$tmp/lifecycle-backward.json"
pass 'lifecycle controls enforce monotonic transitions and event shutdown'

jq -cS '.event_id="demo-event-2026" | .phase="formation_open" | .enabled=true | .revision=0 | .users={} | .teams={} | .memberships={}' "$ROOT/registry/state.json" > "$tmp/formation-state.json"
bash "$ROOT/scripts/admin/activate-team.sh" --state "$tmp/formation-state.json" --proposal "$tmp/team.json" --signatures "$tmp/signatures-complete.json" --proof-dir "$tmp/proofs" --commit 0123456789012345678901234567890123456789 --out "$tmp/activated-state.json" --plan-only >/dev/null
jq -e '.memberships["101"] == "22222222-2222-4222-8222-222222222222" and .memberships["103"] == "22222222-2222-4222-8222-222222222222" and .revision == 1' "$tmp/activated-state.json" >/dev/null
pass 'atomic structural team activation writes all memberships and one revision'

expect_fail bash "$ROOT/scripts/admin/activate-team.sh" --state "$tmp/activated-state.json" --proposal "$tmp/team.json" --signatures "$tmp/signatures-complete.json" --proof-dir "$tmp/proofs" --commit 0123456789012345678901234567890123456789 --out "$tmp/rejected-state.json" --plan-only
pass 'second activation loses the current-state race'

if rg -n 'pull_request_target' "$ROOT/.github/workflows" | grep -v 'team-proposal.yml\|team-proof.yml\|submission.yml\|registration.yml' >/dev/null; then
  fail 'unexpected pull_request_target workflow'
fi
if rg -n 'checkout.*head|github\.event\.pull_request\.head\.ref' "$ROOT/.github/workflows" >/dev/null; then
  fail 'workflow appears to execute or checkout fork code'
fi
pass 'workflow trust-boundary assertions'
printf '%s\n' 'all repository-only security tests passed'
