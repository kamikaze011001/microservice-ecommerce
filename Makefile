# Microservice E-Commerce — single entry point.
# Targets are thin wrappers over scripts/*. No business logic lives here.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help:
	@echo "First-run:"
	@echo "  make bootstrap        — full first-run setup (infra → vault → kafka → maven → seed)"
	@echo ""
	@echo "Daily loop:"
	@echo "  make up               — start everything (auto-unseals vault)"
	@echo "  make down             — stop services + infra (preserves data)"
	@echo "  make restart          — down + up"
	@echo "  make nuke             — stop + wipe volumes (asks for confirmation)"
	@echo "  make status           — show service + infra status"
	@echo ""
	@echo "Per-service:"
	@echo "  make svc-start svc=NAME"
	@echo "  make svc-stop svc=NAME"
	@echo "  make svc-restart svc=NAME"
	@echo "  make logs svc=NAME"
	@echo ""
	@echo "Building:"
	@echo "  make build            — mvn install all modules"
	@echo ""
	@echo "Building blocks:"
	@echo "  make infra-up / infra-down / vault-init / vault-unseal"
	@echo "  make kafka-topics / mongo-connector"
	@echo ""
	@echo "Kubernetes (local minikube cluster):"
	@echo "  make k8s-bootstrap    — one-shot: cluster + infra + images + seed + apps"
	@echo "  make k8s-stop         — pause cluster (keep data; fast resume, no rebuild)"
	@echo "  make k8s-start        — resume a stopped cluster (re-seeds Vault, bounces apps)"
	@echo "  make k8s-down         — tear down apps + cluster"
	@echo "  make k8s-nuke         — full wipe (same as down for minikube)"
	@echo "  make k8s-status       — pods across nodes/infra/bootstrap/apps"
	@echo "  make k8s-tunnel       — expose ingress :80/:443 in the background (needs 'sudo -v' first)"
	@echo "  make k8s-registry-forward — expose the image registry on localhost:5001"
	@echo "  make k8s-mysql-status — MySQL 1-primary/2-replica replication health"
	@echo "  make k8s-apps         — re-apply just the service overlay"
	@echo "  make k8s-rebuild svc=NAME — rebuild one image + rollout restart"
	@echo "  make k8s-build-cache-prune  — reclaim the per-service Maven build caches"
	@echo "  make k8s-payment-stress      — fire k6 payment-saga load Job (opt-in)"
	@echo "  make k8s-payment-stress-logs — tail k6 payment-stress output"
	@echo "  make k8s-storefront-smoke    — production funnel, 50VU/3m smoke gate"
	@echo "  make k8s-storefront-soak     — production funnel, 30m soak (leak/drift)"
	@echo "  make k8s-storefront-stress   — production funnel, open-model stress ramp"
	@echo "  make k8s-storefront-logs     — tail k6 storefront output"
	@echo "  make k9s [ENV=local|eks]     — open k9s monitor on the chosen cluster"
	@echo "  make k8s-use [ENV=local|eks] — switch kubectl context (k8s-ctx prints current)"
	@echo ""
	@echo "AWS (ephemeral EKS):"
	@echo "  make aws-bootstrap    — one-time: TF state bucket + lock table + budget alarm"
	@echo "  make aws-up           — apply aws/main (VPC+EKS+ALB) + wire kubectl"
	@echo "  make aws-push [svc=…] — build arm64 images, push to ECR (default: gateway)"
	@echo "  make aws-infra-up     — deploy infra subset (Kafka/Mongo/observability) on EBS"
	@echo "  make aws-down         — delete ingress, wait, then terraform destroy"
	@echo "  make aws-leak-check   — list still-billing resources after teardown"

# ============================================================================
# First-run / daily loop
# ============================================================================

# NOTE: `bootstrap` itself is now defined below, in the "Unified verbs"
# section, as a dispatcher (Phase 6). This target holds the original compose
# recipe and prerequisites, moved here verbatim under the exception documented
# there — do not add a `bootstrap:` target in this file.
.PHONY: bootstrap-compose
# NOTE: svc-start runs BEFORE the post-apps seed stage because docker/
# ecommerce.sql is a data-only dump. Tables are created by Hibernate ddl-auto
# on first service boot, then the seed inserts rows. Reordering this breaks
# fresh bootstrap (ERROR 1146 — see k8s/CLAUDE.md and deploy/scripts/seed.sh's
# post-apps precondition, which exists precisely to catch this).
#
# Phase 8 Task 2: repointed off the pre-Phase-4/5 `vault-import` /
# `seed-data` prerequisites (which read docker/vault-configs/ and
# scripts/seed/ — trees Phase 8 will delete) onto the canonical
# `secrets-seed` (Phase 4) and `seed` (Phase 5) paths. secrets-seed relies on
# its own ENV default (compose) since prerequisites can't carry variable
# assignments; the two `seed` stages are invoked explicitly in the recipe
# body (not as prerequisites) because the same target name can't appear twice
# in one prerequisite list with different STAGE values — pre-apps (mongo +
# product images) must run before svc-start, post-apps (ecommerce.sql +
# derived inventory rows + the inventory-service reconcile) must run after.
# Verified live 2026-08-14: `make infra-up && make bootstrap ENV=compose`.
bootstrap-compose: infra-up vault-init vault-unseal secrets-seed kafka-topics mongo-connector build
	@$(MAKE) --no-print-directory seed ENV=compose STAGE=pre-apps
	@$(MAKE) --no-print-directory svc-start
	@$(MAKE) --no-print-directory seed ENV=compose STAGE=post-apps
	@echo "✓ Bootstrap complete — stack is up"

.PHONY: up
up: infra-up vault-unseal mongo-seed-ensure mongo-connector-ensure svc-start
	@echo "✓ Stack is up"

.PHONY: down
down: svc-stop infra-down
	@echo "✓ Stack is down"

.PHONY: restart
restart: down up

.PHONY: nuke
nuke:
	@read -p "This wipes ALL volumes (MySQL, Mongo, Kafka, Vault). Continue? [y/N] " ans; \
	  [ "$$ans" = "y" ] || { echo "Cancelled."; exit 1; }
	@$(MAKE) svc-stop
	@bash scripts/infra/down.sh --volumes
	@rm -f vault-keys.json
	@echo "✓ All data wiped"

# NOTE: `status` itself is now defined below, in the "Unified verbs" section,
# as a dispatcher (Phase 6). This target holds the original compose recipe,
# moved here verbatim under the exception documented there — do not add a
# `status:` target in this file.
.PHONY: status-compose
status-compose:
	@bash scripts/services/status.sh

# ============================================================================
# Infra
# ============================================================================

.PHONY: infra-up infra-down infra-status
infra-up:
	@bash scripts/infra/up.sh
infra-down:
	@bash scripts/infra/down.sh
infra-status:
	@bash scripts/infra/status.sh

# ============================================================================
# Vault
# ============================================================================

.PHONY: vault-init vault-unseal vault-login
vault-init:
	@bash scripts/vault/init.sh
vault-unseal:
	@bash scripts/vault/unseal.sh
vault-login:
	@bash scripts/vault/login.sh

# ============================================================================
# Canonical Secrets (deploy/secrets/)
# ============================================================================

.PHONY: secrets-seed secrets-validate secrets-render
# Canonical secrets (deploy/secrets/). ENV=compose|k8s|aws, default compose.
# ALWAYS OVERWRITES the backend — the canonical file is authoritative.
# CONTEXT=NAME is required (by secrets-seed.sh itself) for a real ENV=k8s run
# — never inherited from an ambient kubectl context. See k8s-bootstrap-helm.
secrets-seed:
	@bash deploy/scripts/secrets-seed.sh $(strip --env $(or $(ENV),compose) $(if $(CONTEXT),--context $(CONTEXT)))

# Resolve only. Writes deploy/.run/secrets-<env>.json; touches no backend.
secrets-render:
	@bash deploy/scripts/secrets-seed.sh $(strip --env $(or $(ENV),compose) --dry-run $(if $(CONTEXT),--context $(CONTEXT)))

# Consistency checks. No backend, no credentials — safe to run anywhere.
secrets-validate:
	@bash deploy/scripts/secrets-validate.sh

# ============================================================================
# Canonical Seed (deploy/seed/)
# ============================================================================

.PHONY: seed seed-render
# Canonical seed data (deploy/seed/). ENV=compose|k8s|aws, STAGE=pre-apps|post-apps,
# default compose/pre-apps. pre-apps: mongo (api_role/product/productQuantityHistory)
# + product images — run before the apps. post-apps: ecommerce.sql (account/
# account_role/role/user) + derived inventory rows + the inventory-service reconcile
# — run after the apps (needs the Hibernate-created schema). See deploy/README.md.
seed:
	@bash deploy/scripts/seed.sh $(strip --env $(or $(ENV),compose) --stage $(or $(STAGE),pre-apps) $(if $(CONTEXT),--context $(CONTEXT)))

# Resolve only. Touches no backend.
seed-render:
	@bash deploy/scripts/seed.sh $(strip --env $(or $(ENV),compose) --stage $(or $(STAGE),pre-apps) --dry-run $(if $(CONTEXT),--context $(CONTEXT)))

# ============================================================================
# Canonical Seed — test suites (deploy/seed/tests/)
# ============================================================================

.PHONY: seed-test-render seed-test-equivalence seed-live-verify
# Renderer unit tests + the compose/product.json byte-for-byte invariant.
# No backend, no credentials, no cluster.
seed-test-render:
	@bash deploy/seed/tests/render-test.sh

# Layer A — offline equivalence across all three envs (compose/k8s/aws)
# against captured goldens of the three old per-env scripts. No backend, no
# credentials, no cluster; the only verification `aws` gets. NOTE: named by
# full path deliberately — deploy/secrets/tests/equivalence-test.sh (Canonical
# Secrets' own suite) shares the same basename and is unrelated.
seed-test-equivalence:
	@bash deploy/seed/tests/equivalence-test.sh

# Layer B — live state diff (old way vs new way, by content hash). ENV=compose|k8s,
# default compose. Re-seeds the target backend and takes several minutes; only
# run against a stack you're fine re-seeding. See deploy/README.md.
seed-live-verify:
	@bash deploy/seed/tests/live-verify.sh --env $(or $(ENV),compose)

# ============================================================================
# Kafka
# ============================================================================

.PHONY: kafka-topics mongo-connector mongo-connector-ensure
kafka-topics:
	@bash scripts/kafka/topics.sh
mongo-connector:
	@bash scripts/kafka/mongo-connector.sh
mongo-connector-ensure:
	@bash scripts/kafka/ensure-connector.sh

# ============================================================================
# Maven
# ============================================================================

.PHONY: build
build:
	@bash scripts/maven/install-modules.sh

# ============================================================================
# Seed
# ============================================================================

.PHONY: mongo-seed-ensure

# Idempotent, safe to call on every `make up`. Used to be scoped to api_role
# only (scripts/seed/mongo-roles.sh) because the OLD mongo-products.sh
# unconditionally DROPPED its collection before importing — see git history.
# That rationale no longer applies: deploy/scripts/seed.sh gates the Mongo
# DROP behind --replace (not passed here), and without it mongoimport runs
# --mode upsert (matches on _id, never drops) — see seed.sh's header. So this
# now runs the full pre-apps stage (api_role + product + productQuantityHistory
# + the 30 product images) non-destructively on every start.
# Measured cost added to a warm `make up`: ~9.0-9.7s over 3 runs against the
# live compose stack (2026-08-15) — under the 10s budget in
# task-6-brief.md's decision rule, so wired directly rather than adding a
# narrower --only flag. See task-6-report.md.
mongo-seed-ensure:
	@bash deploy/scripts/seed.sh --env compose --stage pre-apps

# ============================================================================
# Service lifecycle
# ============================================================================

.PHONY: svc-start svc-stop svc-restart logs
svc-start:
	@bash scripts/services/start.sh $(if $(svc),$(svc),all)

svc-stop:
	@bash scripts/services/stop.sh $(if $(svc),$(svc),all)

svc-restart:
	@bash scripts/services/stop.sh $(if $(svc),$(svc),all)
	@bash scripts/services/start.sh $(if $(svc),$(svc),all)

logs:
	@if [ -z "$(svc)" ]; then echo "Usage: make logs svc=NAME"; exit 1; fi
	@bash scripts/services/logs.sh $(svc)

# ============================================================================
# Kubernetes (local minikube cluster)
# See docs/superpowers/specs/2026-08-01-deploy-refactor-design.md
# ============================================================================

K8S_CLUSTER := microecom

.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-nuke k8s-stop k8s-start k8s-tunnel k8s-tunnel-stop

k8s-cluster-up:
	@deploy/scripts/cluster.sh up

k8s-cluster-down:
	@deploy/scripts/cluster.sh down

# The registry addon lives inside minikube, so down and nuke both remove it.
k8s-nuke: k8s-apps-down
	@deploy/scripts/cluster.sh down
	@echo "==> cluster destroyed (full clean slate)"

k8s-cluster-status:
	@deploy/scripts/cluster.sh status

# Pause the cluster without destroying it. PVC data and images survive.
k8s-stop:
	@deploy/scripts/cluster.sh stop

# Resume a stopped cluster, re-seed the in-memory Vault, and restart apps.
k8s-start:
	@deploy/scripts/cluster.sh start

# Bind :80/:443 so the ingress hosts work in a browser. Runs in the BACKGROUND
# with a PID file -- no terminal to keep open. k8s-cluster-up starts it too.
# Binding privileged ports needs root, so cache the credential first:
#   sudo -v && make k8s-tunnel
k8s-tunnel:
	@deploy/scripts/cluster.sh tunnel

k8s-tunnel-stop:
	@deploy/scripts/cluster.sh tunnel-stop

.PHONY: k8s-build k8s-build-reuse k8s-rebuild k8s-build-cache-prune k8s-registry-forward k8s-registry-stop

# Build and push through the registry forward started by k8s-cluster-up.
k8s-build:
	@deploy/images/build.sh

# Bootstrap build path: skip images already in the registry (fast down->bootstrap).
# `make k8s-bootstrap FORCE_BUILD=1` rebuilds everything from scratch instead.
k8s-build-reuse:
	@if [ -n "$(FORCE_BUILD)" ]; then deploy/images/build.sh; else REUSE_EXISTING=1 deploy/images/build.sh; fi

k8s-rebuild:
	@if [ -z "$(svc)" ]; then echo "Usage: make k8s-rebuild svc=NAME"; exit 1; fi
	@SVC=$(svc) SKIP_CORES=1 deploy/images/build.sh
	@kubectl -n apps rollout restart deployment/$(svc)

k8s-registry-forward:
	@deploy/scripts/cluster.sh registry-forward

k8s-registry-stop:
	@deploy/scripts/cluster.sh registry-stop

# Each service keeps its own BuildKit cache mount for /root/.m2 (see
# Dockerfile.jvm) -- roughly 150 MB apiece, ~1.2 GB across the eight services.
# Reclaim them when disk gets tight; the next build re-downloads and re-warms,
# so this costs time, never correctness. Also the fix if a core/* artifact in a
# cache ever looks stale.
k8s-build-cache-prune:
	@docker builder prune --filter type=exec.cachemount -f
	@docker builder du | tail -3

.PHONY: k8s-infra k8s-platform k8s-infra-helm k8s-seed k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest k8s-seed-images k8s-app-secrets

k8s-infra:
	@k8s/infra/install.sh

## k8s-platform: install cluster-wide platform charts + vendor Helm deps
k8s-platform:
	@./deploy/scripts/platform.sh $(or $(ENV),local-k8s)

## k8s-infra-helm: bring up infra via the Helm umbrella chart (Phase 2 path)
##   Runs ALONGSIDE `make k8s-infra` — the kubectl path is still the default.
##   --timeout 30m is the OUTER backstop, not the primary bound: the chart's
##   mysql-replication post-install hook Job carries its own derived
##   activeDeadlineSeconds -- (mysqlReplica.replicas + 1) * waitTimeout + 60,
##   960s at the defaults (replicas=2, waitTimeout=300) -- which fires FIRST and
##   produces the readable "ERROR: <host> unreachable after 300s" diagnostic.
##   30m must cover BOTH phases sequentially, not just the larger one: `--wait`
##   blocks on every OTHER resource going Ready (cold Confluent image pull
##   ~330s/5.5m) BEFORE the post-install hook Job is even created, and only
##   THEN can the hook burn its own activeDeadlineSeconds. Worst case
##   960s + 330s ~= 1290s (~21.5m); 20m (1200s) left no headroom and could
##   abandon the wait before the hook ever prints its diagnostic -- the exact
##   inversion this timeout exists to prevent. 30m = 960s hook deadline + ~330s
##   cold-pull + headroom. render-test.sh asserts this timeout stays >=
##   activeDeadlineSeconds + 330 so the two can't silently drift apart.
k8s-infra-helm: k8s-platform
	@helm upgrade --install microecom deploy/charts/microecom \
	  --namespace infra --create-namespace \
	  -f deploy/charts/microecom/envs/$(or $(ENV),local-k8s).yaml \
	  --wait --timeout 30m

# k8s-seed: applies the Kafka Connect registration Job (relocated to
# deploy/k8s-jobs/04-kafka-connect-register — Task 5). The other three Jobs
# this loop used to run — 02-mongo-seed, 03-vault-seed, 05-minio-bootstrap —
# are now covered by the canonical `secrets-seed ENV=k8s CONTEXT=...` /
# `seed ENV=k8s STAGE=pre-apps CONTEXT=...` calls in k8s-bootstrap-helm
# (Task 6; see its own comment). This target is kept standalone — the legacy
# kubectl-path `k8s-bootstrap` still uses it for kafka-connect-register.
k8s-seed:
	@echo "==> applying 04-kafka-connect-register (job/kafka-connect-register)"
	@kubectl -n bootstrap delete job kafka-connect-register --ignore-not-found >/dev/null
	@kubectl apply -k deploy/k8s-jobs/04-kafka-connect-register
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/kafka-connect-register
	@echo "k8s-seed complete"

# k8s-seed-mysql / k8s-seed-inventory: both superseded by the canonical
# `seed ENV=k8s STAGE=post-apps` (ecommerce.sql + derived inventory_product /
# product_quantity_history rows + the inventory-service reconcile, in one
# idempotent pass — see deploy/scripts/seed.sh). Kept as thin standalone entry
# points for the legacy kubectl-path `k8s-bootstrap` (which still runs both,
# back-to-back, in its prerequisite list) and any direct callers (docs/,
# deploy/k6-stress/*). Both must still run AFTER k8s-apps/k8s-apps-helm:
# docker/ecommerce.sql — now deploy/seed/ecommerce.sql — is data-only, and the
# schema is created by Hibernate ddl-auto when the JPA services boot; seed.sh's
# own post-apps precondition refuses to write a row before every target table
# exists. Calling both k8s-seed-mysql and k8s-seed-inventory now runs the same
# post-apps stage twice (row-count gates make the second call a no-op, but the
# inventory-service reconcile restart also fires twice) — harmless, just
# redundant. See task-6-report.md.
k8s-seed-mysql:
	@bash deploy/scripts/seed.sh --env k8s --stage post-apps --context $(K8S_CLUSTER)

k8s-seed-inventory:
	@bash deploy/scripts/seed.sh --env k8s --stage post-apps --context $(K8S_CLUSTER)

# k8s-seed-perftest: seed the k6 load-test fixtures (perftest_admin + 100
# perftest_user_N + role assignments) into authorization-server MySQL. Runs
# SEPARATELY, AFTER k8s-apps — the account/user/role tables are created by
# Hibernate ddl-auto at authorization-server startup. Both the script and the
# SQL are in-tree, so this uses plain `kubectl apply -k`. Idempotent (seed.sh
# skips if perftest_admin exists; the SQL is INSERT IGNORE). Re-runnable: the
# Job is deleted first (Jobs are immutable).
k8s-seed-perftest:
	@echo "==> applying 06-perftest-seed (job/perftest-seed)"
	@kubectl -n bootstrap delete job perftest-seed --ignore-not-found >/dev/null
	@kubectl apply -k deploy/k8s-jobs/06-perftest-seed
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/perftest-seed
	@echo "k8s-seed-perftest complete"

# k8s-seed-images: superseded by the canonical `seed ENV=k8s STAGE=pre-apps`
# (uploads the same 30 product images to MinIO alongside the mongo import —
# see deploy/scripts/seed.sh's "objects" leg). Kept as a thin standalone entry
# point for the legacy kubectl-path `k8s-bootstrap` and any direct callers.
# Runs the WHOLE pre-apps stage, not images alone — seed.sh has no
# images-only scope; idempotent either way (mongoimport upsert + mc cp
# overwrite). See task-6-report.md.
k8s-seed-images:
	@bash deploy/scripts/seed.sh --env k8s --stage pre-apps --context $(K8S_CLUSTER)

.PHONY: k8s-apps k8s-apps-down k8s-apps-helm k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs k8s-storefront-smoke k8s-storefront-soak k8s-storefront-stress k8s-storefront-run k8s-storefront-logs k9s

# Apply all 8 service Deployments via the local overlay.
# k8s-app-secrets: build the `app-secrets` Secret in the apps namespace from
# deploy/.env (user-owned mail + PayPal creds). authorization-server and
# payment-service envFrom it. Kept out of git (deploy/.env is gitignored) and
# out of Vault. If deploy/.env is missing we create an empty Secret so the
# optional secretRef resolves (mail/PayPal just stay unset). Idempotent (apply).
#
# Phase 8 Task 6 (follow-up): relocated from k8s/.env — a tree a later phase
# deletes. k8s/.env was gitignored, so `git rm -r k8s/` would not have removed
# it from disk, but it would have been left stranded in an otherwise-empty
# directory with nothing pointing at it any more, and this target's own
# else-branch would then silently create an EMPTY app-secrets Secret (the
# human's mail + PayPal config quietly stops working, with only a warn-level
# log to notice it by). See task-6-report.md's Follow-up section.
#
# Ensures the namespaces exist FIRST, idempotently, rather than assuming some
# other target already created them. This makes the target self-sufficient
# regardless of which bring-up path (kubectl `k8s-infra` or Helm
# `k8s-infra-helm`) created them, or whether either has run yet —
# which is what lets `k8s-apps-helm` below declare this as a real prerequisite.
# `kubectl apply` on a namespace that already carries another owner's labels
# (e.g. Helm's) is safe: with no prior last-applied-configuration annotation,
# the merge only ADDS fields, it never deletes the existing owner's labels.
#
# The ownership stamp is load-bearing, not decoration. The umbrella chart also
# renders these namespaces (deploy/charts/microecom/templates/namespaces.yaml,
# deliberately NOT gated on apps.enabled), and Helm REFUSES to adopt a
# pre-existing object that lacks these three keys — it aborts the whole install
# with "cannot be imported into the current release: invalid ownership
# metadata". Without the stamp, creating the namespace here would break
# `make k8s-apps-helm` on any cluster where the microecom release does not
# exist yet. Verified both directions against a live cluster: plain
# kubectl-created namespace => install aborts; same namespace with these keys
# => install and a subsequent upgrade both succeed.
#
# Stamp ALL THREE namespaces the chart renders, not just `apps`. namespaces.yaml
# ranges over global.namespaces and skips only `infra` (the release namespace),
# so it emits apps + bootstrap + monitoring — and Helm checks ownership on every
# one of them. Stamping `apps` alone moved the abort rather than removing it:
# on a cluster brought up with `make k8s-bootstrap` (which creates `bootstrap`
# via the seed Jobs and `monitoring` via k8s-platform, both unstamped),
# `make k8s-apps-helm` still failed with the same "invalid ownership metadata"
# error, naming `bootstrap` instead. Measured on a live 4-node minikube
# (2026-08-07) — the 268 render tests cannot catch it, because the conflict is
# between the chart and pre-existing cluster state, not inside the rendered YAML.
#
# NECESSARY BUT NOT SUFFICIENT (historically). This unblocked the namespaces
# only. Before Phase 8 Task 1, `make k8s-apps-helm` still aborted afterwards,
# because it did NOT set infra.enabled=false — the umbrella rendered the whole
# infra subchart, which vendors grafana (charts/infra/charts/grafana), while
# `k8s-platform` had already installed grafana as its OWN standalone Helm
# release. Helm then refused to adopt ServiceAccount/grafana out of release
# "grafana" into release "microecom". Same applies to the other standalone
# platform releases.
#
# FIXED (Phase 8 Task 1): the recipe below now passes --set infra.enabled=false
# itself, mirroring deploy/scripts/aws-deploy.sh, so the umbrella never renders
# the infra subchart here and the collision cannot occur. Reproduced live
# 2026-08-14 on this exact cluster: `k8s-apps-down` + `k8s-apps-helm` (pre-fix)
# aborted with "ServiceAccount \"grafana\" in namespace \"monitoring\" ...
# current value is \"grafana\"" — confirming the diagnosis above verbatim.
# With the fix, `k8s-apps-down` + `k8s-apps-helm` deploys cleanly (10/10 pods,
# catalog serving 30 products through the gateway).
#
# It is still NOT a drop-in after `make k8s-bootstrap` (kubectl path) without
# first running `k8s-apps-down` — the two app paths remain mutually exclusive
# on one cluster (see the target comment below). `make k8s-apps` restored the
# kustomize path cleanly on 2026-08-07 (10/10 pods, catalog 200) when this was
# last needed as a rollback.
#
# On the pure kubectl path (`k8s-apps`) no Helm release exists and the keys are
# inert — Helm deletes what its release manifest lists, never what merely
# carries a label, so this does not change `helm uninstall` blast radius.
k8s-app-secrets:
	@for ns in apps bootstrap monitoring; do \
	  kubectl create namespace $$ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	  kubectl label namespace $$ns app.kubernetes.io/managed-by=Helm --overwrite >/dev/null; \
	  kubectl annotate namespace $$ns \
	    meta.helm.sh/release-name=microecom \
	    meta.helm.sh/release-namespace=infra --overwrite >/dev/null; \
	done
	@if [ -f deploy/.env ]; then \
	  kubectl create secret generic app-secrets --namespace apps \
	    --from-env-file=deploy/.env --dry-run=client -o yaml | kubectl apply -f - ; \
	else \
	  echo "warn: deploy/.env missing — creating empty app-secrets Secret. Copy deploy/.env.example to deploy/.env and re-run k8s-app-secrets for working mail/PayPal."; \
	  kubectl create secret generic app-secrets --namespace apps \
	    --dry-run=client -o yaml | kubectl apply -f - ; \
	fi

k8s-apps: k8s-app-secrets
	@kubectl apply -k k8s/apps/overlays/local
	@kubectl -n apps rollout status deployment --timeout=10m

k8s-apps-down:
	@kubectl delete -k k8s/apps/overlays/local --ignore-not-found

# Helm path for the apps, alongside `make k8s-apps` (kubectl/kustomize).
# Both bring-up paths stay in the tree this phase; rolling back is reverting this
# target. They are NOT composable on one cluster — the Helm chart selects on
# app.kubernetes.io/name while the base manifests use a bare `app:` key, and
# spec.selector is immutable on a Deployment. Pick one path per cluster.
#
# --timeout stays 30m. The drift guard in tests/render-test.sh only parses the
# k8s-infra-helm recipe (activeDeadlineSeconds + 330s); this target's --timeout
# is unguarded and could drift with no test failing.
#
# ENV=aws additionally REQUIRES the S3 IRSA role ARN, ECR registry and image
# tag, or the render fails by design (see charts/apps/templates/
# irsa-serviceaccounts.yaml and _helpers.tpl's `required` guards). Typing
# `HELM_EXTRA='--set apps.irsa.s3RoleArn=$$(terraform output -raw
# s3_irsa_role_arn)'` (plus separately supplying the registry/tag) by hand is
# what deploy/scripts/aws-deploy.sh (Phase 7) resolves and wires in — see
# `make deploy ENV=aws` / VERB_deploy_aws below. This target keeps taking
# HELM_EXTRA directly too, for anyone who wants to call it without going
# through that helper.
#
# k8s-app-secrets prerequisite: the apps chart mounts app-secrets with
# envFrom.secretRef.optional: true, so a missing Secret doesn't crash pods — it
# silently drops mail and PayPal config. `k8s-apps` (the kubectl path) already
# declares this; it was missing here. Order-independent now that
# k8s-app-secrets creates its own namespace (see its recipe above) instead of
# assuming k8s-infra-helm's templates/namespaces.yaml ran first.
k8s-apps-helm: k8s-app-secrets
	@helm upgrade --install microecom deploy/charts/microecom \
	  --namespace infra --create-namespace \
	  -f deploy/charts/microecom/envs/$(or $(ENV),local-k8s).yaml \
	  --set apps.enabled=true --set infra.enabled=false $(HELM_EXTRA) \
	  --wait --timeout 30m
	@kubectl -n apps rollout status deployment --timeout=10m

# Quick health dashboard for the cluster.
k8s-status:
	@echo "== nodes =="; kubectl get nodes
	@echo "== infra =="; kubectl -n infra get pods
	@echo "== bootstrap jobs =="; kubectl -n bootstrap get jobs
	@echo "== apps =="; kubectl -n apps get pods

# MySQL replication health at a glance: the 3 pods, the read Service endpoints,
# the primary's writable state, and each replica's IO/SQL thread + lag. Read-only
# (no changes). Healthy = both replicas show Replica_IO_Running/Replica_SQL_Running
# Yes and Seconds_Behind_Source 0.
k8s-mysql-status:
	@echo "== MySQL pods =="; kubectl -n infra get pods -l app.kubernetes.io/name=mysql -o wide
	@echo ""; echo "== read Service endpoints (mysql-replica → should list 2 IPs) =="
	@kubectl -n infra get endpoints mysql-replica
	@echo ""; echo "== primary (mysql-0) =="
	@kubectl -n infra exec mysql-0 -- mysql -uroot -proot -N -e \
	  "SELECT CONCAT('server_id=', @@server_id, ' read_only=', @@read_only, ' gtid_executed=', @@gtid_executed);" 2>/dev/null \
	  || echo "  (unable to query mysql-0)"
	@for rep in mysql-replica-0 mysql-replica-1; do \
	  echo ""; echo "== $$rep =="; \
	  kubectl -n infra exec "$$rep" -- mysql -uroot -proot -e "SHOW REPLICA STATUS\G" 2>/dev/null \
	    | grep -E "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Source_Host:|Last_IO_Error:|Last_SQL_Error:" \
	    || echo "  (no replica status — pod missing or replication not configured)"; \
	done

# Fire the k6 PAYMENT-saga stress Job (drives mock-paypal-service through the
# full login -> order -> payment -> approve flow). Opt-in. Re-runnable — deletes
# the previous Job first (Jobs are immutable). Applies ONLY payment-job.yaml;
# the script configMap is created imperatively (stable name `k6-payment-script`).
k8s-payment-stress:
	@kubectl -n apps delete job k6-payment-stress --ignore-not-found
	@kubectl -n apps create configmap k6-payment-script \
	  --from-file=deploy/k6-stress/payment-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f deploy/k6-stress/payment-job.yaml
	@echo "k6 payment stress running. Watch with: make k8s-payment-stress-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-payment-stress-logs:
	@kubectl -n apps logs -f -l app=k6-payment-stress --tail=-1

# Fire the production-shaped STOREFRONT funnel load Job (browse -> detail ->
# login -> cart -> order -> pay). Three profiles select the k6 scenario via
# PROFILE. The script configMap is created imperatively (stable name
# k6-storefront-script) and PROFILE_PLACEHOLDER in the Job is rewritten per
# target. Re-runnable — deletes the previous Job first (Jobs are immutable).
#   make k8s-storefront-smoke   # 50 VU / 3m fast gate
#   make k8s-storefront-soak    # 30m steady (leak/drift) — read trend on #19665
#   make k8s-storefront-stress  # open-model arrival-rate ramp to the ceiling
# Stress knobs (override on the make line for ceiling-hunt runs):
#   make k8s-storefront-stress PEAK_RATE=200 MAX_VUS=300
PEAK_RATE ?= 120
MAX_VUS ?= 150
STRESS_DUR ?= 15m
k8s-storefront-smoke:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=smoke
k8s-storefront-soak:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=soak
k8s-storefront-stress:
	@$(MAKE) --no-print-directory k8s-storefront-run PROFILE=stress

# Internal: PROFILE must be set by one of the targets above.
k8s-storefront-run:
	@kubectl -n apps delete job k6-storefront --ignore-not-found
	@kubectl -n apps create configmap k6-storefront-script \
	  --from-file=deploy/k6-stress/storefront-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@sed -e 's/PROFILE_PLACEHOLDER/$(PROFILE)/' \
	     -e 's/PEAK_RATE_PLACEHOLDER/$(PEAK_RATE)/' \
	     -e 's/MAX_VUS_PLACEHOLDER/$(MAX_VUS)/' \
	     -e 's/DURATION_PLACEHOLDER/$(STRESS_DUR)/' \
	     deploy/k6-stress/storefront-job.yaml | kubectl apply -f -
	@echo "k6 storefront [$(PROFILE)] running. Watch with: make k8s-storefront-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-storefront-logs:
	@kubectl -n apps logs -f -l app=k6-storefront --tail=-1

# Launch k9s (terminal UI) on a chosen environment, using the repo's committed
# config (skin + namespace hotkeys). Switch contexts live inside k9s with :ctx.
#   make k9s            # ENV=local (default) → minikube cluster
#   make k9s ENV=eks    # EKS (one-time: aws eks update-kubeconfig --alias microecom-eks)
# NOTE: pass ENV on the make line; a shell-exported ENV (e.g. ENV=staging) is
# also picked up and will be rejected as unknown — set it explicitly here.
k9s:
	@command -v k9s >/dev/null 2>&1 || { echo "k9s not installed — run: brew install k9s (other platforms: https://k9scli.io)"; exit 1; }
	@case "$(ENV)" in \
	  ""|local) ctx=microecom ;; \
	  eks)      ctx=microecom-eks ;; \
	  *) echo "Unknown ENV '$(ENV)' — use ENV=local or ENV=eks"; exit 1 ;; \
	 esac; \
	 echo "k9s → context $$ctx (ENV=$${ENV:-local}), namespace apps"; \
	 K9S_CONFIG_DIR="$(CURDIR)/deploy/k9s" k9s --context "$$ctx" -n apps

.PHONY: k8s-bootstrap k8s-bootstrap-helm k8s-down

# One-shot: cluster -> infra -> images -> seed -> apps. Idempotent —
# safe to re-run after editing manifests or pulling new code. Mirrors
# the docker-compose `make bootstrap` flow but for the minikube cluster.
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build-reuse k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
	@echo "==> k8s bootstrap complete"
	@$(MAKE) k8s-status
	@echo ""
	@echo "================================================================"
	@echo "  Final steps:"
	@echo ""
	@echo "  1. Add these lines to /etc/hosts (one-time):"
	@echo "       127.0.0.1 microecom.local"
	@echo "       127.0.0.1 api.microecom.local"
	@echo "       127.0.0.1 media.microecom.local"
	@echo "       127.0.0.1 grafana.microecom.local"
	@echo "       127.0.0.1 vm.microecom.local"
	@echo ""
	@echo "  2. Make sure the ingress tunnel is up (k8s-cluster-up starts it when"
	@echo "     sudo is already cached; otherwise start it by hand):"
	@echo "       sudo -v && make k8s-tunnel"
	@echo ""
	@echo "  3. Verify:"
	@echo "       curl -i http://api.microecom.local/product-service/v1/products"
	@echo "       open http://microecom.local"
	@echo "================================================================"

# Helm-based one-shot, alongside `k8s-bootstrap` (kubectl/kustomize) — same
# overall shape (cluster -> infra -> images -> seed -> apps -> seed), with the
# two Helm swaps: k8s-infra-helm instead of k8s-infra, k8s-apps-helm instead
# of k8s-apps. NOT composable with `k8s-bootstrap` on one live cluster (see
# k8s-apps-helm's comment above); pick one path per cluster.
#
# Phase 8 Task 1: this is the target VERB_bootstrap_k8s now resolves to (see
# the dispatch table near the bottom of this file). Verified live 2026-08-14
# only for its k8s-infra-helm + k8s-apps-helm halves (already-running cluster,
# no full from-scratch rebuild performed — that takes ~35m and was out of
# scope for that task).
#
# Phase 8 Task 6: seeding repointed onto the canonical scripts
# (deploy/scripts/secrets-seed.sh / deploy/scripts/seed.sh) instead of the old
# k8s-seed (02-mongo-seed/03-vault-seed/05-minio-bootstrap) / k8s-seed-images /
# k8s-seed-mysql / k8s-seed-inventory targets, which read k8s/infra/jobs/,
# docker/*.json and docker/ecommerce.sql — trees a later phase deletes. Order
# preserved exactly (secrets before apps; pre-apps seed — mongo + images —
# before apps; post-apps seed — ecommerce.sql + derived inventory rows + the
# inventory-service reconcile — after apps, because ecommerce.sql is
# data-only and Hibernate ddl-auto creates the schema at service boot; see
# seed.sh's own post-apps precondition). The seed calls are in the RECIPE
# BODY, not the prerequisite list — same reason as bootstrap-compose's own
# two `seed` calls (STAGE=pre-apps and STAGE=post-apps can't both be
# prerequisites of one target). Both secrets-seed and seed REQUIRE an
# explicit kubectl context for --env k8s (never an ambient one) — wired here
# to $(K8S_CLUSTER) (=microecom, the live local cluster's context).
# kafka-connect-register (k8s-seed, restructured) and perftest-seed
# (k8s-seed-perftest, already canonical since Task 5) are unchanged in shape,
# just re-sequenced into the recipe body alongside the rest.
k8s-bootstrap-helm: k8s-cluster-up k8s-infra-helm k8s-build-reuse
	@$(MAKE) --no-print-directory secrets-seed ENV=k8s CONTEXT=$(K8S_CLUSTER)
	@$(MAKE) --no-print-directory seed ENV=k8s STAGE=pre-apps CONTEXT=$(K8S_CLUSTER)
	@$(MAKE) --no-print-directory k8s-seed
	@$(MAKE) --no-print-directory k8s-apps-helm
	@$(MAKE) --no-print-directory seed ENV=k8s STAGE=post-apps CONTEXT=$(K8S_CLUSTER)
	@$(MAKE) --no-print-directory k8s-seed-perftest
	@echo "==> k8s bootstrap (helm) complete"
	@$(MAKE) k8s-status
	@echo ""
	@echo "================================================================"
	@echo "  Final steps:"
	@echo ""
	@echo "  1. Add these lines to /etc/hosts (one-time):"
	@echo "       127.0.0.1 microecom.local"
	@echo "       127.0.0.1 api.microecom.local"
	@echo "       127.0.0.1 media.microecom.local"
	@echo "       127.0.0.1 grafana.microecom.local"
	@echo "       127.0.0.1 vm.microecom.local"
	@echo ""
	@echo "  2. Make sure the ingress tunnel is up (k8s-cluster-up starts it when"
	@echo "     sudo is already cached; otherwise start it by hand):"
	@echo "       sudo -v && make k8s-tunnel"
	@echo ""
	@echo "  3. Verify:"
	@echo "       curl -i http://api.microecom.local/product-service/v1/products"
	@echo "       open http://microecom.local"
	@echo "================================================================"

# Tear it ALL down — apps, infra, and the minikube cluster itself.
# Use k8s-apps-down for a softer reset (keeps infra/data).
k8s-down: k8s-apps-down k8s-cluster-down
	@echo "==> k8s cluster destroyed"

# ============================================================================
# AWS (ephemeral EKS) — see docs/superpowers/specs/2026-06-10-aws-deployment-design.md
# ============================================================================
.PHONY: aws-bootstrap aws-up aws-push aws-infra-up aws-down aws-leak-check aws-all aws-deploy-apps

# One-time, persistent stack: TF remote-state bucket + DynamoDB lock + budget
# alarm. Idempotent. Requires aws/bootstrap/terraform.tfvars (budget_email).
aws-bootstrap:
	@scripts/aws/bootstrap.sh

# Bring up the ephemeral environment (aws/main: VPC + EKS + ALB controller) and
# point kubectl at the cluster. ~15-20 min on a cold apply.
aws-up:
	@scripts/aws/up.sh

# Tear down safely: delete the Ingress so the controller removes the ALB, wait,
# then terraform destroy. Always run before ending a session.
aws-down:
	@scripts/aws/down.sh

# Build arm64 images and push to ECR. Default target is gateway (+ cores base);
# `svc=all` pushes the whole catalog, `svc=<name>` a single service.
aws-push:
	@scripts/aws/push-images.sh $(svc)

# Deploy the Phase 2 self-hosted infra subset (Kafka/SR/Connect/Mongo/VM/Grafana)
# onto the EKS cluster. PVCs bind to gp3 → real EBS volumes. Run after `make aws-up`.
aws-infra-up:
	@scripts/aws/infra-up.sh

# Confirm nothing is still billing after a teardown (ALBs, NAT, EIPs, EBS, EKS).
aws-leak-check:
	@scripts/aws/leak-check.sh

# Full from-scratch bring-up: cluster+RDS → images → infra → seed-mongo →
# secrets → apps(+gate) → seed-rds → seed-inventory. The cloud twin of
# `make k8s-bootstrap`. Every step bills AWS — run it yourself. Default reuses
# ECR images (they survive aws-down); PUSH=all rebuilds after a code change.
aws-all:
	@scripts/aws/up-all.sh

# Resolve the three AWS deploy-time inputs (S3 IRSA role ARN, ECR registry,
# image tag) and deploy the apps via Helm — replacing the manual
#   make k8s-apps-helm ENV=aws HELM_EXTRA='--set apps.irsa.s3RoleArn=...'
# incantation an operator previously had to type (plus separately supply the
# registry/tag, which envs/aws.yaml deliberately leaves empty). A NEW helper
# under deploy/ (Phase 7), deliberately not folded into scripts/aws/up-all.sh
# (frozen) — see docs/superpowers/specs/2026-08-12-aws-cutover-design.md D3.
# Mapped from `make deploy ENV=aws` via VERB_deploy_aws below. Applies to a
# live cluster with --wait (via k8s-apps-helm) — COSTS MONEY.
aws-deploy-apps:
	@deploy/scripts/aws-deploy.sh

# ============================================================================
# Helm chart — AWS differential test suite (deploy/charts/microecom/tests/)
# ============================================================================
# Phase 7 (docs/superpowers/specs/2026-08-12-aws-cutover-design.md) closed the
# gap that these two scripts had no entry point — same retrofit pattern Phase
# 6 already applied to seed-test-equivalence / verb-test-equivalence. See
# deploy/README.md's "AWS cut-over" section for what each layer proves.

.PHONY: aws-oracle-capture aws-diff-test
# Rebuilds tests/aws-oracle/oracle.yaml from `kubectl kustomize
# k8s/apps/overlays/aws` (pure local build, no cluster contact) PLUS
# s3-irsa-serviceaccounts.yaml with PLACEHOLDER_S3_ROLE_ARN substituted from
# the offline fixture — the same out-of-band step up-all.sh:127-137 performs
# live (D1). Re-run this after any change under k8s/apps/overlays/aws; the
# oracle is captured output, not hand-written, and aws-diff-test always
# compares against whatever oracle.yaml currently holds on disk.
aws-oracle-capture:
	@bash deploy/charts/microecom/tests/aws-oracle/capture.sh

# Layer A — offline differential render: does the chart's aws-with-apps
# render reproduce the composed oracle (kustomize half + IRSA half), object
# by object? Guards both sides non-empty and per-kind counts before diffing.
# No cluster, no credentials, no spend.
aws-diff-test:
	@bash deploy/charts/microecom/tests/aws-diff-test.sh

.PHONY: k8s-use k8s-ctx

k8s-ctx:
	@kubectl config current-context

k8s-use:
	@case "$(ENV)" in \
	""|local) ctx=microecom ;; \
	eks)      ctx=microecom-eks ;; \
	*) echo "Unknown ENV '$(ENV)' — use ENV=local or ENV=eks"; exit 1 ;; \
	esac; \
	kubectl config use-context "$$ctx" && echo "==> now on $$ctx"

# ============================================================================
# Unified verbs (Phase 6)
# ============================================================================
# `make <verb> ENV=<env>` delegates to the existing target below. Additive:
# every old target still works and is unchanged. See
# docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md
#
# `status` collision (human-approved exception, see the design doc's "A note
# on the collisions"): `status` already existed as the compose target name.
# Its original recipe was moved verbatim to `status-compose` above; `status`
# itself is now the dispatcher defined below, so the compose mapping points
# at `status-compose`, not `status` (which would recurse into this dispatcher).
#
# NOTE: no global `ENV ?= compose` here. This file already has several
# targets (k9s, k8s-use, k8s-platform, k8s-infra-helm, k8s-apps-helm) that
# read bare $(ENV) with their OWN default (local / local-k8s) via
# $(or $(ENV),...). A global default would silently override every one of
# them for any bare invocation. Instead the compose default is scoped to
# just the dispatch macro below, via the same $(or $(ENV),...) idiom.

VERB_deploy_compose    := svc-start
VERB_deploy_k8s        := k8s-apps-helm
VERB_deploy_aws        := aws-deploy-apps
VERB_status_compose    := status-compose
VERB_status_k8s        := k8s-status
VERB_teardown_compose  := down
VERB_teardown_k8s      := k8s-down
VERB_teardown_aws      := aws-down
VERB_rebuild_compose   := svc-restart
VERB_rebuild_k8s       := k8s-rebuild

# `bootstrap` collision (human-approved exception, same pattern as `status`
# above): `bootstrap` already existed as the compose target name. Its original
# recipe + prerequisites were moved verbatim to `bootstrap-compose` above;
# `bootstrap` itself is now the dispatcher defined below, so the compose
# mapping points at `bootstrap-compose`, not `bootstrap` (which would recurse
# into this dispatcher).
VERB_bootstrap_compose := bootstrap-compose
VERB_bootstrap_k8s     := k8s-bootstrap-helm
VERB_bootstrap_aws     := aws-all

# image-build: deliberately NO VERB_image-build_compose. Compose builds no
# container images (services run as JVM processes from Maven artifacts), so
# the dispatch macro must reject ENV=compose by construction, not no-op with
# exit 0 — see the macro's _WHY interpolation below.
VERB_image-build_k8s   := k8s-build
VERB_image-build_aws   := aws-push
# NOTE: backticks here are escaped (\`...\`) deliberately. This text is
# interpolated into a double-quoted `echo "..."` inside the dispatch macro's
# shell recipe below — a bare, unescaped `make build` in backticks would be
# parsed by the shell as command substitution and actually RUN `make build`
# (a real multi-minute Maven install) while composing the error message,
# instead of just naming it. Confirmed live: the unescaped form hangs
# `make image-build ENV=compose` for as long as `scripts/maven/install-modules.sh`
# takes, with zero output, because command substitution runs before echo's
# own argument is complete.
VERB_image-build_compose_WHY := compose builds no container images (services run as JVM processes from Maven artifacts — see \`make build\`)

# GNU make imports the process ENVIRONMENT as variables, not only
# command-line assignments — `export ENV=aws` in a shell (or a stray
# .envrc/direnv/CI env) makes plain `make bootstrap` silently behave like
# `make bootstrap ENV=aws`, which resolves to `aws-all`: a real, unprompted,
# billed EKS apply with no confirmation prompt anywhere downstream. Before
# this branch `bootstrap`/`status` were ENV-blind, so this is a regression
# specifically introduced by giving them dispatch verbs. VERB_ENV restores
# that ENV-blindness for the dispatch macro ONLY: it resolves to a value
# only when ENV was set on the `make` command line itself (`origin` returns
# "command line"), never from an exported/inherited environment variable.
# This must NOT be used by the five pre-existing bare-$(ENV) targets (k9s,
# k8s-use, k8s-platform, k8s-infra-helm, k8s-apps-helm) — they read $(ENV)
# directly and must keep honouring an exported ENV exactly as they did
# before this branch.
VERB_ENV := $(if $(filter command line,$(origin ENV)),$(ENV),)

# An unmapped (verb, env) pair fails HERE, by construction — no per-verb
# special case. A verb that silently succeeds where it has nothing to do is
# indistinguishable from one that worked.
#
# `ENV=` on the recursive $(MAKE) call (Phase 8 Task 1): the verb-env
# vocabulary this dispatch resolves on (compose/k8s/aws, selected via
# VERB_ENV above) is a DIFFERENT namespace from the bare $(ENV) some resolved
# targets read for themselves (k8s-apps-helm / k8s-bootstrap-helm default to
# "local-k8s", not "k8s"). GNU Make automatically forwards a command-line
# variable override to recursive $(MAKE) invocations, so without this,
# `make deploy ENV=k8s` resolves t="k8s-apps-helm" but then leaks the literal
# string "k8s" into that target's own $(or $(ENV),local-k8s) — which is
# non-empty, so the default never fires, and it looks for the nonexistent
# deploy/charts/microecom/envs/k8s.yaml instead of envs/local-k8s.yaml.
# Measured live 2026-08-14 via verb-equivalence-test.sh Part 1 going from
# 21/21 to 19/21 the moment VERB_deploy_k8s / VERB_bootstrap_k8s were
# repointed at these two ENV-aware targets — every one of the 12 previously
# resolved targets was ENV-blind (see verb-equivalence-test.sh's own
# comment), so this exact leak was latent, never triggered, until now.
# `ENV=` (empty) resets the sub-make's command-line override back to unset,
# so `$(or $(ENV),local-k8s)` correctly falls through to the target's own
# default — restoring old behaviour (VERB_deploy_k8s used to point at the
# ENV-blind k8s-apps, where this never mattered) rather than the target's own
# `ENV=aws` direct-invocation path silently changing. Safe for every current
# VERB_* mapping: aws-deploy-apps / aws-all / aws-push / aws-down are all
# ENV-blind scripts that never read $(ENV) themselves.
dispatch = t="$(VERB_$(1)_$(or $(VERB_ENV),compose))"; \
  if [ -z "$$t" ]; then \
    echo "make $(1): not applicable for ENV=$(or $(VERB_ENV),compose)$(if $(VERB_$(1)_$(or $(VERB_ENV),compose)_WHY), — $(VERB_$(1)_$(or $(VERB_ENV),compose)_WHY))" >&2; \
    exit 1; \
  fi; \
  $(MAKE) --no-print-directory $$t ENV=

.PHONY: deploy status teardown rebuild bootstrap image-build
deploy:
	@$(call dispatch,deploy)
status:
	@$(call dispatch,status)
teardown:
	@$(call dispatch,teardown)
rebuild:
	@$(call dispatch,rebuild)
bootstrap:
	@$(call dispatch,bootstrap)
image-build:
	@$(call dispatch,image-build)

# ============================================================================
# Unified verbs — test suites (deploy/scripts/tests/)
# ============================================================================

.PHONY: verb-test-equivalence verb-live-test
# Layer A — offline expansion equivalence for every (verb, env) pair against
# captured baselines of the old targets, plus the declared image-build
# ENV=compose failure and the five pre-existing bare-$(ENV) defaults. No
# backend, no credentials, no cluster; runs from any cwd. See
# deploy/README.md's Verification status section under "Unified verbs".
verb-test-equivalence:
	@bash deploy/scripts/tests/verb-equivalence-test.sh

# Layer B — live compose run: deploy -> seed -> status -> rebuild against a
# running compose stack, asserting each exits 0 and the stack still serves
# afterwards. Deliberately excludes teardown ENV=compose (would stop the
# stack this and other work depends on) — its dispatch mapping is covered by
# verb-test-equivalence instead. See deploy/README.md.
verb-live-test:
	@bash deploy/scripts/tests/verb-live-test.sh
