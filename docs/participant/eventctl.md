# Installing the participant CLI

The event publishes one pinned Go CLI release for all events. Participants do
not build event-specific code and do not need Python or Node.js. The repository
lock file records the release asset and binary SHA-256 values.

From a checkout of the event repository:

```text
./tools/install-eventctl.sh --version 1.0.0
./tools/eventctl --help
```

The installer selects the host platform, downloads only the locked GitHub
release asset, verifies both the archive and extracted binary, and installs it
under `tools/.cache/`. Keep the private identity key outside Git; only signed
public request documents and encrypted bundles belong in fork branches.

Organizers update `tools/eventctl.lock.json` only as a separately reviewed
protocol release. A participant must never substitute an unpinned local binary
for the release used by organizer verification.
