---
name: an-oracle-can-validate-a-command-nobody-runs
description: aws-deploy.sh had --set infra.enabled=false inline in its render branch only, so make aws-diff-test validated a helm invocation the live apply never issued
metadata: { type: convention, date: 2026-08-28 }
---

`deploy/scripts/aws-deploy.sh` has two branches. `--mode render` runs
`helm template` directly. The real apply `exec`s `make k8s-apps-helm ENV=aws`, and
that recipe (`Makefile:619-624`) composes its own `helm upgrade --install` from
`$(HELM_EXTRA)`.

`--set infra.enabled=false` was written **inline in the render branch only**. So:

- `make aws-diff-test` — the gate five phases relied on — rendered apps-only and
  matched its oracle. Green, every time.
- The live apply left the `infra` subchart enabled, and since AWS installs infra as
  *separate* Helm releases ([[0005-aws-infra-stays-outside-the-umbrella-chart]]), the
  umbrella tried to create objects another release already owned:

```
Error: ServiceAccount "grafana" in namespace "monitoring" exists and cannot be
imported into the current release: ... must equal "microecom": current value is
"grafana"
```

Had it succeeded it would have been worse — the `microecom` release would own the
infra objects, arming exactly the deletion trap `0005` exists to prevent.

**Why this is a distinct failure class.** The other defects this branch found were
local-development assumptions leaking onto a remote path
([[a-shared-builder-assumes-its-local-registry]]) — findable by reading a script.
This one is not in any single file: **the verification and the thing verified were
never the same artifact.** Both branches read as correct. The bug lives in the
relationship between them and a Makefile recipe one of them execs.

Rendering is structurally incapable of catching a render-vs-apply split, because
rendering is the half that works.

**How to apply:** when one script serves both a "show me what this would do" mode
and a "do it" mode, every flag that must apply to both belongs in **one array both
paths consume**, never inline in either. If you find a flag inline in one branch,
that is the bug, not a style issue. And treat any oracle whose subject reaches
production through a *different* code path as unverified until something asserts the
two invocations match.

Corollary from the same fix: use `--set`, never `--set-string`, for a boolean.
`--set-string infra.enabled=false` yields the STRING `"false"`, and Helm evaluates a
dependency `condition:` as truthy for any non-empty string — so the subchart renders
anyway and the flag looks present while doing nothing.
