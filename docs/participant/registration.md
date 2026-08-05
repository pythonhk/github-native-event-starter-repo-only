# Participant registration

Create an Ed25519 identity with the pinned `eventctl` release, using the
organizer's published event configuration and trust files:

```text
eventctl identity register ... --actor-id <your numeric GitHub ID> --out registration.json
```

Push exactly this file from your own fork branch and open a PR to upstream
`main`:

```text
requests/users/<your numeric GitHub ID>.json
```

The read-only check compares the request actor with the authenticated PR
author. A passing check is only an eligibility signal. The organizer re-runs
`eventctl identity verify` at the PR's immutable source time and merges one
admin state PR into `registry`, updating both `registry/state.json` and the
eventctl-compatible `registry/identity-registry.json`.

Do not commit the private key. A key ID is bound to one actor and one active
epoch; changing the actor, event, repository, or public key invalidates the
signed request.
