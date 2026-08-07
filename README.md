# GitHub-native event starter — organizer-trusted PR model

This is the repository-only successor to the App-centric v1 starter. It is a
public, reusable GitHub template for bounded events where the organizer is the
trusted state-transition authority.

The default operating model has two branch roles:

```text
main
├── trusted workflows, schemas, and event documentation
├── merged participant request history
└── no participant-controlled workflow changes

registry
└── protected normalized public state
    users, teams, memberships, attempts, quotas, results, and scoring policy
```

Participants push to a branch in their own fork and open pull requests to the
upstream event repository's `main` branch. Team proposals, member proofs, and
submissions are all request files; they do not write authoritative state.
An organizer reviews accepted requests and merges one atomic activation or
state-update PR into `registry`.

There is no custom event-specific GitHub App in the normal runtime path. GitHub
Actions performs read-only validation with `pull_request_target`, using only
trusted base-branch code and exact API-fetched blobs. It never checks out or
executes fork code and never receives organizer secrets.

The pinned `eventctl` v1 trust documents still contain a logical writer/state
label for protocol compatibility. In this starter those fields are
organizer-control labels only; the outer repository's authoritative state is
the reviewed `registry` branch, and no GitHub App installation, App token, or
App private key is required.

## Team formation

Participants first register an Ed25519 identity through an exact
`requests/users/<github-id>.json` PR. See
[docs/participant/registration.md](docs/participant/registration.md).
Install the shared, checksum-pinned Go CLI once with
[docs/participant/eventctl.md](docs/participant/eventctl.md); the event
repository contains no per-event application runtime.

Team formation is deliberately staged so a public, copyable proposal cannot
reserve another participant or consume quota:

```text
team proposal PR
  -> PENDING_KEY_PROOFS
  -> one key-proof/binding PR from each listed member
  -> READY_TO_ACTIVATE
  -> organizer activation PR to registry
  -> ACTIVE, REJECTED, or EXPIRED
```

The proposal directory contains a canonical `team.json` and a deterministic
member-signature envelope. Each member proof binds the event, repository,
registration ID, numeric GitHub actor ID, and public key. The workflow compares
the claimed actor with the authenticated PR author; copying a proof from another
participant therefore fails.

Pending proposals do not reserve GitHub IDs, public keys, team names,
membership, quota, or leaderboard identity. The first fully verified proposal
that passes the organizer's current-state check and is merged wins.

The current pinned `eventctl` release uses Ed25519 identities and explicit
multi-signature documents. The envelope is intentionally named and documented
as an explicit multi-signature container, not as a mathematical BLS aggregate.
True BLS aggregation can be introduced as a separately reviewed protocol
version without changing the repository workflow.

## Submission model

Submissions are also untrusted PR proposals:

```text
fork branch
  -> encrypted bundle + signed request
  -> read-only intake check
  -> organizer review/merge
  -> one registry transition for (team_id, attempt_id)
```

The same content may be submitted again with a fresh attempt ID by the same
authorized participant. Replaying an existing signed attempt is idempotent;
presenting it from another actor, fork, PR, branch, or head SHA is rejected.

Scoring is a separate organizer-controlled hook. It reads only a reserved
attempt and a public result payload, never executes participant code, and can
write a result only through an admin PR that marks the attempt completed. The
event can be disabled or moved to `frozen`/`closed` through the lifecycle
controls without changing request history.

## One-time organizer setup

The organizer creates the event repository from this template, creates the
protected `registry` branch, and publishes the signed genesis/configuration.
`event/event.example.yaml` is only the repository's lifecycle metadata example;
the signed v1 `eventctl` configuration and protected trust files are organizer
inputs and must be generated and verified separately before activation.
An optional organizer PEM or signing key is supplied only during this
bootstrap/administration ceremony and is never exposed to fork-triggered jobs.
If activation PRs are merged manually, the bootstrap credential can be retired
after genesis.

The repository contains no participant private keys, organizer private keys,
GitHub tokens, or confidential plaintext. Every public branch and fork is
assumed observable.

Normal organizer activation is cryptographic: `scripts/admin/activate-team.sh`
requires the pinned `eventctl` binary, protected trust files, and a source-time
map for the proof PRs. Its explicit `--plan-only` mode is a structural review
mode and says that cryptographic verification was not run.

The shell files under `scripts/` are trusted runtime adapters, not the test
harness. GitHub Actions invokes them from the checked-in base revision, and the
act-backed pytest suite exercises them through the checked-in workflow YAML.
Keeping the validation and state transitions outside YAML avoids duplicating
security logic inside workflow files and lets an organizer reproduce a check
before merging.

All pytest cases are Docker-backed `act` black-box tests. Run them locally with:

```bash
mise run test
```

The task requires Docker, the `act` binary, and its cached checkout action. The
underlying command is:

```bash
uv run --python 3.12 --with pytest==8.3.5 --no-project pytest -q tests/e2e
```
The hosted CI workflow runs this same act-backed suite as its only required
status check. It does not maintain a parallel unit-test, static-shape, or
shell-contract test path.

Here pytest is the outer coordinator. Each case arranges an isolated pull
request event, API responses, and (for submissions) producer output; `act`
then runs the checked-in workflow YAML in a Docker runner. Pytest asserts the
workflow exit/log contract and the Git working-tree contract afterward. The
current participant workflows are intentionally read-only, so their positive
cases assert that no registry or request history was mutated. A future
organizer state-transition workflow can reuse the same fixture boundary and
assert the expected registry commit and canonical state instead.

## Layout

```text
.github/workflows/        trusted read-only checks and organizer dispatches
event/                    event configuration and terms
protocol/schemas/v2/      strict request and registry schemas
requests/                 merged public request history on main
registry/                 normalized authoritative state on registry
scripts/participant/      request preparation helpers
scripts/actions/          untrusted-data validators
scripts/admin/            organizer-only plan/apply/view-rebuild helpers
tests/                    pytest-coordinated workflow black-box tests
```

Read [docs/organizer/workflow.md](docs/organizer/workflow.md) before creating a
derived event. Read [docs/participant/team-formation.md](docs/participant/team-formation.md)
before preparing a team proposal.
