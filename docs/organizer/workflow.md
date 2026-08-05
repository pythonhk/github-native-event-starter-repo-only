# Organizer workflow

## Branches

The event has one public request branch and one authoritative state branch:

```text
main
  trusted workflow code, schemas, event documentation, and merged request files

registry
  normalized public state; organizer-only protected branch
```

Do not create separate authoritative `team-registration` and `submission`
branches. Both operations resolve the same users, memberships, lifecycle, and
quota state. A single `registry` branch is the consistency boundary.

Temporary organizer branches use `admin/` and become authoritative only after a
reviewed merge into `registry`.

The shared `eventctl` v1 configuration contains a compatibility logical
writer/state label because the CLI release is reused by older event profiles.
Keep that label bound in the protected trust files, but do not create an
event-specific App for this starter: the actual writer is the
organizer-reviewed `registry` commit.

## Bootstrap

1. Create a new repository from the template; do not fork the starter as the
   event identity.
2. Protect `main` and `registry` with CODEOWNERS, pull-request review, no force
   pushes, no deletion, and linear history.
3. Create `registry` from the reviewed genesis commit. The initial files are:

   ```text
   registry/state.json
   registry/identity-registry.json
   registry/users/index.json
   registry/teams/index.json
   registry/memberships/index.json
   registry/submissions/index.json
   ```

4. Render the event metadata and exact terms on `main` in one organizer PR.
   `event/event.example.yaml` is the repository lifecycle template, not a
   substitute for the signed v1 configuration consumed by `eventctl`. Publish
   the exact eventctl config, protected genesis/authority, state metadata, and
   identity registry paths used by the organizer runbook; keep private keys out
   of Git. Keep the event disabled until this PR is reviewed and merged.
5. Optionally use one organizer PEM/signing key to publish genesis or prepare
   the first administrative PR. Never put it in Git and never expose it to
   `pull_request_target` jobs.

## Participant PRs

Participants push to their own fork branch and open PRs to upstream `main`.
The trusted workflows only inspect bounded request paths:

```text
requests/teams/<registration-id>/team.json
requests/teams/<registration-id>/signatures.json
requests/teams/<registration-id>/proofs/<github-id>.json
requests/users/<github-id>.json
requests/submissions/<attempt-id>/request.json
requests/submissions/<attempt-id>/bundle.eventctl
```

The PR itself is an untrusted proposal. A passing check means only that the
proposal is eligible for organizer review; it does not activate a team, reserve
quota, or record a score.

## Team activation

The organizer creates `admin/activate-team-<registration-id>` from the current
`registry` head. The activation plan must:

- reread the exact merged proposal and every proof;
- verify all signatures and actor bindings;
- run the pinned `eventctl team verify` and `eventctl identity verify` commands
  with protected configuration, authority, registry, and immutable source
  times (a structural `--plan-only` output is never an activation);
- recheck lifecycle, expiry, team-size, key, and membership constraints;
- refuse a participant who is already active in another team;
- write users, team, and membership records in one commit; and
- retain source PR numbers, immutable head SHAs, and request digests.

After every state transition, run `scripts/admin/rebuild-views.sh` in the same
admin PR so the four public index files remain deterministic materialized views
of `registry/state.json`; they are never an independent authority.

The organizer reviews and merges the activation PR into `registry`. If two
activations race, only the first valid merge against the current registry head
wins; the other plan must be regenerated.

## Submission admission

The submission workflow verifies the signed request against the merged
`registry` snapshot and the authenticated PR metadata. It must bind:

```text
event, repository, actor, active team, attempt ID,
upstream PR number/database ID, fork repository, head branch/SHA,
configuration digest, bundle digest, and validity window
```

The organizer creates an admin state PR for a valid reservation. The replay key
is `(team_id, attempt_id)`, not the content digest. The same content with a new
attempt ID is allowed for the same authorized actor; copying an old signed
request into another actor's PR is rejected.

`scripts/admin/apply-submission.sh` normally requires the pinned `eventctl`
binary, protected trust files, immutable PR metadata, and the bundle. It runs
`eventctl submission verify-request` before writing state. Exact replays return
the already recorded attempt without incrementing the registry revision;
conflicting reuses of an attempt ID fail closed.

The `eventctl` metadata file is a small canonical projection of the immutable
GitHub pull-request event, not the raw GitHub event payload. Prepare it before
the admin plan and retain it with the review evidence:

```text
scripts/admin/prepare-pr-metadata.sh \
  --github-event /secure/evidence/github-event.json \
  --out /secure/evidence/pr-metadata.json
```

## Lifecycle

Lifecycle changes are organizer PRs to `registry`:

```text
draft -> registration_open -> formation_open -> submissions_open
      -> frozen -> closed -> archived
```

All mutating checks reread `registry/state.json` at the current branch head.
Disabling an event stops new proposal, proof, submission, and scoring plans.
Scoring follows the separate [scoring hook](scoring.md) and never executes
participant-controlled source in a GitHub Actions job.
