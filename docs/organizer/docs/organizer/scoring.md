# Scoring hook

Scoring is intentionally outside participant intake. An organizer-controlled
runner may inspect a reserved encrypted bundle in the approved isolated judge,
then publish only a bounded public payload and a `pythonhk.scoring-result/v2`
envelope under `registry/scoring/`.

The result must bind:

- the exact event, team, and attempt;
- the stored submission request digest;
- the payload's SHA-256 digest; and
- the scorer identity and version.

Run the read-only hook with the protected `registry` checkout:

```text
scripts/scoring/validate-result.sh \
  --state registry/state.json \
  --result registry/scoring/<attempt-id>.result.json \
  --payload registry/scoring/<attempt-id>.payload.json
```

After review, `scripts/admin/apply-score.sh` updates `registry/state.json` in
one admin PR, marks the attempt `completed`, and increments the registry
revision. It refuses duplicate results, unreserved attempts, mismatched team
IDs, and payload changes. Scoring remains disabled unless the state explicitly
sets `scoring.enabled` and `isolation: organizer-controlled`.
