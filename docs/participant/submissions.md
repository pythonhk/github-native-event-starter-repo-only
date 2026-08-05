# Submissions

Prepare the encrypted bundle locally and commit only the public bundle and
signed request metadata. Never commit plaintext, private signing keys, or judge
secrets.

Push to a branch in the participant fork and open a PR to upstream `main`:

```text
requests/submissions/<attempt-id>/request.json
requests/submissions/<attempt-id>/bundle.eventctl
```

`request.json` is a repository wrapper around the complete signed `eventctl
submission prepare` document. It mirrors the attempt, actor, fork repository,
PR number/ID, head branch/SHA, and bundle digest so the trusted check can
compare every field with the immutable GitHub PR API response.

The read-only intake check binds the authenticated PR actor, active team from
`registry`, attempt ID, immutable PR/head identity, and bundle/request digests.
The organizer then runs `eventctl submission verify-request` against the
protected identity/configuration files and the bundle. No participant code is
executed and the bundle is never decrypted by intake.

An organizer reviews a valid check and merges an admin state PR into `registry`.
The idempotency key is `(team_id, attempt_id)`. A retry of the same attempt
returns the existing result; a new attempt ID intentionally permits the same
content to be submitted again by the same authorized participant.
