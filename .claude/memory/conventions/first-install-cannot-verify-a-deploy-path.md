---
name: first-install-cannot-verify-a-deploy-path
description: a deploy path is not verified until it has been run twice and cold — three release-breaking bugs survived five phases because every check was a first-run check
metadata: { type: convention, date: 2026-08-15 }
---

Phase 8's from-scratch `make bootstrap ENV=k8s` — the first ever run of that chain — failed
three times, each on a genuine bug:

| bug | needs |
|---|---|
| [[deployment-progress-deadline-preempts-helm-timeout]] | a **cold** pull, never a warm one |
| [[helm-subchart-toggle-deletes-on-a-shared-release]] | a **prior release** already owning infra |
| [[hpa-managed-deployments-must-not-declare-replicas]] | an **upgrade after** an HPA has acted |

**Each needs a second event to exist.** Task 1 had deployed the apps chart once, seen 10/10
pods and a catalog serving 30 products, and called the path verified. That judgment was
correct *for what it tested* — a first install. None of these three are reachable from one.

Five phases of green suites plus one successful live deploy still shipped three
release-breaking defects, because every check in the sequence was a first-run check. The
second run is where a deploy system's real behaviour lives: ownership, adoption, drift,
reconciliation. None of it exists on run one.

**How to apply:** before calling a deploy path verified, run it **twice, and cold** — tear
down, rebuild, then upgrade over the result. Offline rendering cannot substitute:
`helm template` renders both configurations perfectly and `render-test` passed 268/0
throughout, because the destruction lives entirely in the *difference between two releases
over time*, which only exists in cluster state.

Corollary for checking after a destructive change: confirming a **running** system still
serves proves nothing about whether it can be **rebuilt**. The pods were started before the
change and hold no opinion about files removed since. See
[[make-n-shows-commands-not-the-files-they-read]] — a broken bootstrap sat undetected behind
exactly that mistake.
