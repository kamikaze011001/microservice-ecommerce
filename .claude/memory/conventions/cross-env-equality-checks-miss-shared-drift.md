---
name: cross-env-equality-checks-miss-shared-drift
description: A check asserting "all envs agree" is a relative invariant — it stays green when every env moves together, which is exactly what a shared source file does
metadata: { type: convention, date: 2026-08-07 }
---

`secrets-validate.sh` check 4 asserts `application.jwk` is **identical across compose/k8s/aws**.
That is satisfied equally well by all three being *correct* and by all three being *wrong the same
way*. Since the value comes from one shared file (`deploy/secrets/jwk.private.json` via a
`<file:>` ref), a trailing newline appended by any editor changes all three at once and check 4
never notices — while the gateway caches JWKS by `kid`, so one differing byte invalidates every
token in the system.

Fixed at the source rather than in the check: `<file:>` refs now `rstrip("\n")` in
`deploy/scripts/lib/secrets_resolve.py`. Proven a no-op by appending a newline to the JWK,
re-running the equivalence suite (still 33/0/0), then restoring the exact bytes.

A second instance of the same shape in the same file: check 3 originally asked whether an env var
was documented in *the union of* `docker/.env.example` and `k8s/.env.example` — "documented
somewhere" instead of "documented where the environment will actually look". It was hiding a real
gap (`docker/.env.example` documented no MAIL vars at all, so copying the example made mail fail
silently). The check is now per-env, and it proved itself by failing on the real gap first.

**How to apply:** when writing a consistency check, ask what a *shared* input changing would do to
it. If the answer is "nothing", the invariant is relative and needs an absolute anchor — a pinned
hash, a parse/round-trip assertion, or normalisation at the source. Relative invariants are still
worth having; they just must not be the only guard on a value whose corruption is silent.
Related: [[0004-canonical-secrets-resolve-transport-split]].
