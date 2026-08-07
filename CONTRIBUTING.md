# Contributing

Changes to workflows, schemas, request parsing, registry reducers, or branch
controls require a security review. Keep participant-controlled data separate
from trusted workflow code. Add a workflow-level regression case for every new
parser rule and run the act-backed repository tests with:

```bash
mise run test
```

Pytest owns arrange and assert; `act` is the runner that executes the
checked-in workflow YAML. Keep participant-triggered workflows read-only.
Tests for organizer state writers must assert the resulting registry commit
and canonical state explicitly.

Do not add a custom GitHub App, a long-lived token, or a dependency that executes
participant code without updating the threat model and protocol version.
