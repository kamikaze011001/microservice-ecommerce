# HANDOFF — microservice-ecommerce — 2026-08-07

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first, so write it for a 10-second catch-up.

## Current goal
Deploy refactor, working through the 9 phases of
`docs/superpowers/specs/2026-08-01-deploy-refactor-design.md`.
**Phase 3 (Helm apps subchart) is merged. Phase 4 (canonical secrets) is in review as PR #54.**
Next unstarted work is Phase 5 (seed consolidation).

Branch: **`feat/deploy-canonical-secrets`** — pushed, 15 commits ahead of `main` (`e4a9c4d`),
37 files, +4662, working tree clean. Kept alive for PR iteration.

## Done
- **PR #53 — Helm apps subchart (Phase 3): MERGED.** `render-test` 268/0.
- **PR #54 — canonical secrets (Phase 4): OPEN.**
  https://github.com/kamikaze011001/microservice-ecommerce/pull/54
  - `deploy/secrets/` — 11 canonical service YAMLs + `contexts/{compose,k8s,aws}.yaml` +
    one `jwk.private.json`.
  - `deploy/scripts/lib/secrets_resolve.py` (pure resolver), `secrets-validate.sh` (6 checks, no
    credentials), `secrets-seed.sh` (resolves all, then writes).
  - `make secrets-seed|secrets-render|secrets-validate ENV=…`.
  - Suites green: resolver 23/0, validate 36/0, equivalence **33 passed / 0 failed / 0 pending**
    (all three envs), Helm render 268/0 untouched.
  - **Live compose proof:** seeded a running dev Vault; Vault KV v2 versioning let us diff what
    the *old* `make vault-import` actually wrote (v1) against the *new* seeder (v2) on the same
    backend — zero value differences, zero keys added, exactly four `_comment*` keys removed.
- **Nothing was deleted.** All three old seed paths still work. Deletion is Phase 8.
- One authorised exception to the frozen `docker/` tree: `docker/.env.example` gained two MAIL
  placeholders (purely additive; no runtime path reads it).

## In progress — Next
1. **PR #54 review feedback**, if any.
2. **`make infra-down`** — compose infra is still running from Phase 4's live verification.
3. **Deferred, needs the user's cluster:** the k8s leg of Phase 4 verification —
   `make secrets-seed ENV=k8s KUBE_CONTEXT=<name>` against a live minikube. No minikube profile
   existed at verification time, and the seeder now *refuses* an unnamed context by design.
4. **Still unverified from Phase 1:** `make k8s-tunnel` (needs sudo, must stay alive) and the
   4 ingress checkboxes behind it, plus `make k8s-down`.
5. Then **Phase 5** (seed consolidation), 6 (unified `make <verb> ENV=…`), 7 (AWS cut-over),
   8 (delete `k8s/` + `aws/`), 9 (CI/CD) — all unwritten.

## Settled decisions
- Canonical secrets = **resolve/transport split**, always-overwrite, `envs: [...]` for
  structurally-conditional keys, credential split preserved and made explicit. See
  `decisions/0004-canonical-secrets-resolve-transport-split.md`.
- Old paths stay until Phase 8; rollback is "don't call the new target".
- **A pre-push hook owns pushing and it is the human's job in this repo** — the agent shell cannot
  `git push`, and that hook must never be bypassed (it is the gitleaks secret scan).

## Not proven, deliberately (stated in the PR body too)
- `make up` after a compose seed was not run — the seeded bytes differ only by four properties
  nothing reads, so startup cannot differ, but that is an inference.
- The k8s transport has never run against a live cluster.
- The aws transport has **never written to AWS Secrets Manager** — verified only against fixture
  terraform outputs with a shimmed `aws` CLI. Live AWS seeding is Phase 7.

## Context to Load
- `docs/superpowers/specs/2026-08-06-canonical-secrets-design.md`
- `docs/superpowers/plans/2026-08-06-canonical-secrets.md`
- `deploy/README.md` (has a "Verification status" section)
- `.claude/memory/decisions/0004-canonical-secrets-resolve-transport-split.md`
- `.claude/memory/conventions/k8s-targets-inherit-ambient-kubectl-context.md`
- `deploy/scripts/lib/secrets_resolve.py`

## Blocked
- Nothing hard-blocked.
- Deferred, must be fixed before this points at a **non-dev** Vault: the Vault auth token is still
  passed on `curl` argv (readable via `ps aux`). Acceptable only for dev root tokens on loopback.
- `paypal.base-url` is sandbox in all three envs — needs parameterising at AWS go-live.
- Phase 8 will delete the goldens' source; freeze them deliberately or the equivalence suite
  becomes a snapshot test of itself.
