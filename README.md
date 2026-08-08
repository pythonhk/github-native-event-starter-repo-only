# GitHub-native event starter

This is the small, clone-based starter for a PythonHK event. It uses the
released `eventctl/v2` CLI and ordinary protected GitHub branches; it has no
GitHub App, PEM, application token, database, or server.

```text
main     event policy, trusted workflows, and merged participant requests
registry organizer-reviewed identities, active teams, and accepted attempts
```

A participant request is public and never changes authoritative state by
itself. The organizer is trusted to review a normal `admin/*` pull request to
`registry` after cryptographic verification succeeds.

## Create an event

1. Create a new repository from this template. Do not make the template's
   repository ID part of the event identity.
2. Create and protect a `registry` branch from the same reviewed commit.
   Require an organizer review, linear history, no force pushes or deletion,
   and the `registry / canonical-state` check. Protect `main` the same way and
   require `event / act-e2e`.
3. Replace `event/terms.md` and update `event/binding.json` together: choose
   the event ID, numeric GitHub repository ID, validity window, request TTLs,
   and team/attempt limits. Set `terms_sha256` to the SHA-256 of the exact
   terms file.
4. Run `eventctl doctor --event event/binding.json` and copy its complete
   `result.event` object into `registry/state.json.event`. Leave the registry
   in `draft`, disabled, with `bootstrap_required` until the event is ready.
5. After the reviewed `eventctl/v2` release exists, replace the `UNRELEASED`
   value in `tools/eventctl.lock.json` with its Linux release asset and both
   SHA-256 values. The trusted workflows download and verify that exact binary.
6. Review the bootstrap PR, create the protected branches, then set the
   registry phase to `registration_open` and enable it through an organizer PR.

`registry/state.json` is the only authoritative state document. Its event
reference, phase, active identities, teams, and attempts are checked by
`eventctl doctor`; it intentionally has no derived identity or membership
views to keep in sync.

## Participant flow

Each participant runs this once, outside their event checkout:

```text
eventctl key-gen --out ~/.eventctl/identity --passphrase-file passphrase.txt
```

The command makes separate Ed25519 signing and age hybrid recipient keys. One
passphrase protects both private files; the keys are not interchangeable.

### Register

```text
eventctl identity register \
  --event event/binding.json \
  --actor-id <numeric-github-id> \
  --sig-private-key ~/.eventctl/identity/signing.private.age \
  --recipient-public-key ~/.eventctl/identity/recipient.public.json \
  --passphrase-file passphrase.txt \
  --output requests/users/<numeric-github-id>.json
```

From a fork, open a pull request changing exactly that file. The trusted
workflow verifies its signature, event reference, and that the filename/claim
equals the authenticated GitHub actor. The organizer then runs the same
verification using the immutable pull-request creation time and writes the
verified identity record to a reviewed `registry` PR.

### Form a team

After the organizer has activated the identities and set `formation_open`, the
proposer reads the public registry branch and creates a proposal:

```text
eventctl team propose \
  --event event/binding.json --registry registry/state.json \
  --actor-id <proposer-id> --member <proposer-id> --member <teammate-id> \
  --sig-private-key ~/.eventctl/identity/signing.private.age \
  --passphrase-file passphrase.txt \
  --output requests/teams/<team-uuid>/proposal.json
```

The proposer opens a PR with exactly `proposal.json`; it is only a pending
request. Every listed member—including the proposer—then submits one separate
PR from their own fork containing:

```text
requests/teams/<team-uuid>/proofs/<their-numeric-github-id>.json
```

created by `eventctl team consent`. The proof workflow binds its filename and
document actor to the GitHub PR author. It does not activate a team. Pending
proposals reserve neither a member nor a quota.

The organizer's no-write verification plan receives immutable GitHub creation
times, for example:

```json
{
  "proposal": "2026-08-10T10:00:00Z",
  "consents": {
    "123": "2026-08-10T10:05:00Z",
    "456": "2026-08-10T10:07:00Z"
  }
}
```

It runs `eventctl team verify` against the current protected registry. Only a
reviewed follow-up state PR adds the returned team record and increments the
registry revision. A competing or stale plan must be regenerated against the
new registry head.

### Submit

When the organizer moves the registry to `submissions_open`, a member signs
the exact opaque bundle they want to submit:

```text
eventctl submission prepare \
  --event event/binding.json --input bundle \
  --team-id <team-uuid> --attempt-id <attempt-uuid> --actor-id <github-id> \
  --sig-private-key ~/.eventctl/identity/signing.private.age \
  --passphrase-file passphrase.txt \
  --output requests/submissions/<attempt-uuid>/request.json
```

The matching `bundle` lives next to the request. The intake workflow verifies
the signed payload, authenticated PR actor, active membership, unused attempt
ID, and both quotas against `registry`. An organizer records the accepted
attempt in a reviewed registry PR. The replay key is `(team_id, attempt_id)`:
the same content may be submitted again using a new attempt ID, but an attempt
ID may not be transferred or changed.

## Encrypted result artifacts

The scorer can encrypt logs to every active team recipient and upload the
ciphertext as a GitHub Actions artifact:

```text
eventctl sigcrypt --context stream-binding.json \
  --sig-private-key organizer-signing.private.age \
  --enc-public-key member-one/recipient.public.json \
  --enc-public-key member-two/recipient.public.json \
  --input judge.log --output judge.log.eventctl
```

Each recipient runs `eventctl decverify` with the organizer signing public key
and their own recipient private key. The event does not need a shared team
private key or an internal key server.

## Testing

There is one test entrypoint:

```text
mise run test
```

Pytest coordinates `act`, Docker, a deterministic GitHub API fixture, and the
real `eventctl` executable against the checked-in workflow YAML. It never runs
participant fork code. Before `eventctl/v2` is pinned in the lock file, local
development supplies `EVENTCTL_E2E_NATIVE_BIN` for the host executable that
creates requests and `EVENTCTL_E2E_BIN` for the matching Linux executable that
`act` runs. A published event never uses either test-only override.
