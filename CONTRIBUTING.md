# Contributing

Changes to workflows, schemas, request parsing, registry reducers, or branch
controls require a security review. Keep participant-controlled data separate
from trusted workflow code. Add a hostile-input test for every new parser rule
and run:

```bash
bash tests/run-security.sh
```

Do not add a custom GitHub App, a long-lived token, or a dependency that executes
participant code without updating the threat model and protocol version.
