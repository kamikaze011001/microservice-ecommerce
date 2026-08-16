---
name: make-n-shows-commands-not-the-files-they-read
description: after deleting a tree, sweep with a repo-wide path-qualified git grep — `make -n` prints `@script.sh arg` and never reveals which files that script opens
metadata: { type: convention, date: 2026-08-15 }
---

Phase 8 deleted `k8s/` and swept for dangling references using Makefile recipe lines and
`make -n` expansions. Three live references survived and broke real commands:

| script | broke |
|---|---|
| `deploy/scripts/platform.sh` read `k8s/infra/values/ingress-nginx.yaml` | **`make bootstrap ENV=k8s` at its first step** |
| `deploy/scripts/cluster.sh` applied `k8s/infra/jobs/03-vault-seed` | `make k8s-start` |
| `scripts/aws/infra-up.sh` read 9 deleted files | `make aws-infra-up`, `up-all.sh` step 3 |

All three sit **one level deeper than `make -n` can see**: it prints
`@deploy/scripts/platform.sh local-k8s` and stops. It answers *what commands will run*, and
it was being used to answer *what files will be read*. Every survivor hid in that gap. All
run under `set -euo pipefail`, so each aborts its whole chain.

**How to apply:** after deleting a tree, run a plain repo-wide `git grep` for it — not
scoped to the Makefile, not `make -n`. Check especially:

- shell scripts the recipes call (three of three lived here)
- **default values** — a default is what runs when nobody passes anything, so nothing in the
  call graph names it (`secrets-validate.sh` had a live default pointing at
  `k8s/.env.example`, nearly missed)
- glob and `find` reads, not just literal paths
- CI configs, hooks, tooling configs

**Grep path-qualified, never by basename.** The canonical replacements share filenames with
what was deleted (`deploy/seed/product.json` vs `docker/product.json`), so a basename grep
matches the NEW path and manufactures false positives — it returned 19 files and none were
real. Related: [[first-install-cannot-verify-a-deploy-path]].
