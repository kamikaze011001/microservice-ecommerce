# Project Memory Index — microservice-ecommerce

*One line per memory. Auto-loaded at session start. Keep it compact and grouped.*

## Decisions (decision + rationale, durable)
- [0001 — in-repo memory alongside untouched CLAUDE.md](decisions/0001-in-repo-memory-alongside-untouched-claude-md.md) — kept CLAUDE.md as SSOT, added the `.claude/memory/` lifecycle
- [0002 — root CLAUDE.md delegates to nested module files](decisions/0002-root-claude-md-delegates-to-nested-module-files.md) — root keeps non-derivable + cross-cutting only; module specifics live in `<module>/CLAUDE.md`
- [0003 — deploy refactor: Helm umbrella + three envs](decisions/0003-deploy-refactor-helm-umbrella-three-envs.md) — consolidate under `deploy/`; Helm for minikube/EKS, compose retained, canonical secrets/seed/images shared
- [0004 — canonical secrets: resolve/transport split](decisions/0004-canonical-secrets-resolve-transport-split.md) — one file per service + per-env contexts; pure resolver separate from the seeder, so every env verifies offline without credentials
- [0005 — AWS infra stays outside the umbrella chart](decisions/0005-aws-infra-stays-outside-the-umbrella-chart.md) — `deploy/aws-infra/` keeps raw manifests; using the chart's infra subchart would put it under the release `aws-deploy.sh` disables infra on, and the next apps deploy would delete it
- [0006 — staleness is membership, not equality](decisions/0006-staleness-is-membership-not-equality.md) — the check asks whether the registered address is one this host OWNS; equality against a default-route guess coupled it to Spring's InetUtils choice, which agreed only by luck

## Conventions (conventions + gotchas, durable)
- [two-memory-systems-coexist](conventions/two-memory-systems-coexist.md) — global personal auto-memory vs in-repo team-shared `.claude/memory/`; which to use when
- [nested-claude-md-loads-only-in-scope](conventions/nested-claude-md-loads-only-in-scope.md) — nested files load only under their directory, so a cross-cutting rule stays in root even when a nested file repeats it
- [a11y-guards-jsdom-pin-is-insurance](conventions/a11y-guards-jsdom-pin-is-insurance.md) — a11y-step guards pin jsdom as defense-in-depth, NOT because happy-dom breaks axe (that premise was false)
- [migrating-styled-buttons-to-biconbutton](conventions/migrating-styled-buttons-to-biconbutton.md) — styled raw button → BIconButton keeps its look via a retained page class (parent scoped CSS wins the specificity tie)
- [eks-gp3-storageclass-must-precede-pvcs](conventions/eks-gp3-storageclass-must-precede-pvcs.md) — fresh EKS defaults to gp2; gp3 SC must be applied before any PVC or the aws-all Step-3 infra bring-up stalls
- [rds-replica-inherits-source-parameter-groups](conventions/rds-replica-inherits-source-parameter-groups.md) — terraform-aws-modules/rds replica needs create_db_*_group=false or apply fails on missing engine metadata
- [minikube-registry-host-5001-pod-5000](conventions/minikube-registry-host-5001-pod-5000.md) — host pushes :5001, pods pull :5000, same registry; do NOT "fix" either to match the other
- [minikube-hostpath-ignores-fsgroup](conventions/minikube-hostpath-ignores-fsgroup.md) — root-owned PVs break non-root containers; Kafka + MongoDB need chown initContainers (kind didn't)
- [kafka-internal-topics-need-explicit-compaction](conventions/kafka-internal-topics-need-explicit-compaction.md) — auto-created `_schemas`/`connect-*` get cleanup.policy=delete and Schema Registry/Connect then refuse to start
- [kafka-exporter-applies-after-kafka-ready](conventions/kafka-exporter-applies-after-kafka-ready.md) — it hard-exits with no broker; apply after Kafka's rollout + restart it so a wedged reconcile recovers
- [minikube-node-resources-only-apply-at-creation](conventions/minikube-node-resources-only-apply-at-creation.md) — `--cpus/--memory` ignored on resume; cluster.sh re-applies via `docker update` (and is over-subscribed here)
- [minikube-tunnel-external-ip-is-sticky](conventions/minikube-tunnel-external-ip-is-sticky.md) — 3 ways to misjudge tunnel health: sticky `EXTERNAL-IP`, `lsof` blind to the root-owned listener, and `sudo -v` cached per-tty
- [buildkit-cache-mount-shadows-baked-m2](conventions/buildkit-cache-mount-shadows-baked-m2.md) — a cache mount hides the image's baked `/root/.m2`; seed it from a read-only bind with `cp -r` (never `-n`)
- [vault-config-comment-keys-are-really-seeded](conventions/vault-config-comment-keys-are-really-seeded.md) — `_comment*` in `docker/vault-configs/*.json` are live Vault properties, not comments; explains the 94-vs-90 key count
- [cross-env-equality-checks-miss-shared-drift](conventions/cross-env-equality-checks-miss-shared-drift.md) — "all envs agree" stays green when a shared source file moves all of them at once; pair it with an absolute anchor
- [k8s-targets-inherit-ambient-kubectl-context](conventions/k8s-targets-inherit-ambient-kubectl-context.md) — no k8s target pins `--context`; only `secrets-seed` refuses an unnamed one, everything else acts on whatever kubectl points at
- [helm-and-kubectl-deploy-paths-are-exclusive](conventions/helm-and-kubectl-deploy-paths-are-exclusive.md) — `k8s-apps-helm` can't follow `k8s-bootstrap`: namespace stamps + a vendored grafana vs the standalone release; "runs alongside" means the code paths, not one cluster
- [cold-cluster-image-pulls-outgrow-rollout-timeouts](conventions/cold-cluster-image-pulls-outgrow-rollout-timeouts.md) — kafka-connect went Ready at 10m30s against a 10m wait and killed the whole 9-target chain; diagnose with pod timestamps, not "it's healthy now"
- [deployment-progress-deadline-preempts-helm-timeout](conventions/deployment-progress-deadline-preempts-helm-timeout.md) — a Deployment's own 600s `progressDeadlineSeconds` fails the release before helm's `--wait --timeout 30m`; raising the helm timeout can NEVER fix a slow cold pull
- [helm-subchart-toggle-deletes-on-a-shared-release](conventions/helm-subchart-toggle-deletes-on-a-shared-release.md) — two targets on one release name: `--set infra.enabled=false` DELETED mysql/mongo/kafka/vault; neither target had changed, ownership did
- [hpa-managed-deployments-must-not-declare-replicas](conventions/hpa-managed-deployments-must-not-declare-replicas.md) — once an HPA scales, kube-controller-manager owns `.spec.replicas` and helm's apply loses the fight, failing the WHOLE release
- [first-install-cannot-verify-a-deploy-path](conventions/first-install-cannot-verify-a-deploy-path.md) — run it twice, and cold: three release-breaking bugs each needed a SECOND event (cold pull / prior release / post-HPA upgrade) and survived five phases of green suites
- [make-n-shows-commands-not-the-files-they-read](conventions/make-n-shows-commands-not-the-files-they-read.md) — after deleting a tree, sweep with a repo-wide PATH-QUALIFIED `git grep`; `make -n` stops at `@script.sh` and three dangling reads hid one level deeper
- [an-unguarded-read-passes-when-its-input-vanishes](conventions/an-unguarded-read-passes-when-its-input-vanishes.md) — a suite reported 33 passed with its input file deleted; the neighbour reading the same file failed loudly because it checked non-empty. Deletion is a diagnostic
- [a-test-may-exercise-code-production-never-calls](conventions/a-test-may-exercise-code-production-never-calls.md) — the mutation test "proving the suite can fail" perturbed a function ONLY the suite called; a green result is evidence only if you know what red looks like
- [a-grep-gate-tests-for-strings-not-for-currency](conventions/a-grep-gate-tests-for-strings-not-for-currency.md) — `grep → 0` passed while a diagram still taught five deleted Jobs; architecture lives in node ids and labels, not vocabulary
- [compose-materialises-a-missing-mount-as-a-directory](conventions/compose-materialises-a-missing-mount-as-a-directory.md) — deleted seed files kept "reappearing" as empty dirs; sweep BOTH the qualified path and the `./relative` form used from inside a directory
- [the-pidfile-holds-the-launcher-not-the-port-holder](conventions/the-pidfile-holds-the-launcher-not-the-port-holder.md) — `logs/pids/*.pid` is the `mvn` wrapper, not the JVM on the port; kill by port, and don't delete `kill_orphan_on_port` as redundant
- [refactor-first-is-an-ordering-constraint](conventions/refactor-first-is-an-ordering-constraint.md) — the unification CREATES the single site the semantic change lands in; the reverse order was impossible, not just untidy
- [a-gaps-registry-decays-through-success](conventions/a-gaps-registry-decays-through-success.md) — a "known gaps" list goes stale exactly when the work goes well, and no task brief ever names that file

## Current
- [HANDOFF](HANDOFF.md) — latest WIP state (overwritten each session)
- [sessions/](sessions/) — progress log per day
