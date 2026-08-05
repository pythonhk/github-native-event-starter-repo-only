# Security policy

## Scope

This starter assumes a transparent, mutually distrustful event: participants
can read public request history and registry state, but no participant is
implicitly trusted to change authoritative state.

The organizer, GitHub's authenticated pull-request metadata, the protected
base-branch workflows, and the protected `registry` branch are trusted
components. The protocol does not claim security against a malicious organizer,
compromised GitHub account, compromised participant key, modified trusted
workflow, or GitHub-wide compromise.

## Required properties

- A participant key proof is accepted only when its numeric actor ID equals the
  authenticated PR author ID.
- A team becomes active only after every listed member has authenticated a proof
  bound to the exact team proposal.
- Pending proposals reserve no state and cannot lock other participants.
- A submission is attributed to the team resolved from authoritative membership,
  never solely from a self-declared `team_id`.
- A submission wrapper and its embedded eventctl envelope must agree with the
  immutable upstream PR number/ID, fork repository, head branch/SHA, and
  bundle digest.
- `(team_id, attempt_id)` is the idempotency key. Same content with a new attempt
  ID is an intentional new attempt; replaying the same attempt is harmless.
- `registry` is the only authoritative state branch. It is protected against
  deletion, force-push, and non-linear history.
- Fork contents, filenames, commit messages, PR text, usernames, and workflow
  artifacts are hostile data. No privileged workflow executes them.
- Structural intake checks are eligibility signals only. The organizer's
  normal activation path must re-verify the embedded eventctl registration,
  proposal, and consent signatures against protected trust files and immutable
  PR source times; a local `--plan-only` result is not an activation.

## Pull-request trust boundary

Participant workflows may use `pull_request_target` only to run trusted
base-branch code. They fetch and bound exact JSON blobs through the GitHub API;
they do not checkout the PR head, source shell files, install dependencies from
the PR, or expose secrets. An organizer-only workflow may prepare an activation
plan, but the organizer must review and merge the resulting `registry` PR.

## Reporting

Do not disclose private keys, organizer credentials, or confidential submissions
in public issues or pull requests. Contact the event organizer through the
published security route with the event ID, affected request, and a minimal
synthetic reproduction.
