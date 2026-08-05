# Team formation

Team formation is a public, two-stage request. Anyone can read the proposal and
proof files; only the organizer's reviewed merge can activate membership.

## Stage 1: proposal

The proposer must be one of the listed members. Generate a canonical proposal
with the event's participant tooling and place it in:

```text
requests/teams/<registration-id>/team.json
```

The proposal must contain a fresh registration ID, a UUID team ID, the exact
event/repository binding, an expiry, and a numerically sorted list of unique
members. Each member entry contains the numeric GitHub ID and the public key
that member will prove. `team.json` also embeds the exact `eventctl team
propose` document; the organizer re-verifies that embedded document with the
protected event configuration and identity registry.

Each member's `eventctl team consent` signs the embedded eventctl proposal.
The proposer places the deterministic sorted signature container (containing
the complete consent documents) at:

```text
requests/teams/<registration-id>/signatures.json
```

The current starter uses an explicit Ed25519 multi-signature container. It is
not a BLS aggregate and must not be described as one.

Open a PR to upstream `main`. The check can report:

```text
PENDING_KEY_PROOFS
missing: 3 numeric member IDs
```

It must not reserve a member, team name, quota, or leaderboard entry.

## Stage 2: one proof PR per member

Each member opens a PR from their own fork containing exactly one file:

```text
requests/teams/<registration-id>/proofs/<github-id>.json
```

The proof is a `pythonhk.key-proof/v2` wrapper containing that member's complete
`eventctl identity register` document and complete `eventctl team consent`
document. The trusted workflow compares the file's claimed ID with
`github.event.pull_request.user.id`, and the organizer later runs both eventctl
verifiers at the immutable PR source times.

Copying another member's proof fails at this comparison. Changing the claimed
ID invalidates the binding signature. Changing the proposal or public key
invalidates the proof's digest binding.

When all proofs pass, the proposal check becomes `READY_TO_ACTIVATE`. It still
is not active until the organizer creates and merges an activation PR into
`registry`.

## Failure and expiry

Pending proposals may be rejected or expire. They do not block another proposal
containing the same member. The first fully verified activation that succeeds
against the current registry wins.
