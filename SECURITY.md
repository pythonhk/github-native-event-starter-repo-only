# Security policy

This template assumes every fork and every file under `requests/` is public,
untrusted input. Report a vulnerability privately through the repository's
GitHub Security tab with a synthetic reproduction and affected commit.

- Keep `main` and `registry` protected; only organizer-reviewed registry PRs
  make an identity, team, or attempt active.
- Use `pull_request_target` only with trusted base-branch code. Do not check
  out, execute, source, or install code from a participant fork.
- Treat GitHub's authenticated numeric actor ID and pull-request creation time
  as trusted delivery facts. Do not substitute a participant-controlled commit
  timestamp.
- Pin the released `eventctl` binary by archive and binary SHA-256. Never use
  a mutable release URL or an unreviewed local binary for organizer decisions.
- Do not commit private keys, passphrases, decrypted logs, plaintext judge
  output, or GitHub tokens.
- There is no normal GitHub App, PEM, secret, or remote service in this model.
  An organizer's branch protection and reviewed registry transition are the
  authority boundary.
