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
	@echo "  make infra-up / infra-down / vault-init / vault-unseal / vault-import"
	@echo "  make kafka-topics / mongo-connector / seed-data"
	@echo ""
	@echo "Kubernetes (local kind cluster):"
	@echo "  make k8s-bootstrap    — one-shot: cluster + infra + images + seed + apps"
	@echo "  make k8s-stop         — pause cluster (keep data; fast resume, no rebuild)"
	@echo "  make k8s-start        — resume a stopped cluster (re-seeds Vault, bounces apps)"
	@echo "  make k8s-down         — tear down apps + cluster (keeps registry/images)"
	@echo "  make k8s-nuke         — full wipe incl. registry (cold rebuild next time)"
	@echo "  make k8s-status       — pods across nodes/infra/bootstrap/apps"
	@echo "  make k8s-mysql-status — MySQL 1-primary/2-replica replication health"
	@echo "  make k8s-apps         — re-apply just the service overlay"
	@echo "  make k8s-rebuild svc=NAME — rebuild one image + rollout restart"
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

.PHONY: bootstrap
# NOTE: svc-start runs BEFORE seed-data because docker/ecommerce.sql is a
# data-only dump. Tables are created by Hibernate ddl-auto on first service
# boot, then the seed inserts rows. Reordering these breaks fresh bootstrap.
bootstrap: infra-up vault-init vault-unseal vault-import kafka-topics mongo-connector build svc-start seed-data
	@echo "✓ Bootstrap complete — stack is up"

.PHONY: up
up: infra-up vault-unseal mongo-connector-ensure svc-start
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

.PHONY: status
status:
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

.PHONY: vault-init vault-unseal vault-import vault-login
vault-init:
	@bash scripts/vault/init.sh
vault-unseal:
	@bash scripts/vault/unseal.sh
vault-import:
	@bash scripts/vault/import-secrets.sh
vault-login:
	@bash scripts/vault/login.sh

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

.PHONY: seed-data seed-mysql seed-mongo
seed-data:
	@bash scripts/seed/all.sh
seed-mysql:
	@bash scripts/seed/mysql.sh
seed-mongo:
	@bash scripts/seed/mongo-roles.sh
	@bash scripts/seed/mongo-products.sh

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
# Kubernetes (local kind cluster)
# See docs/superpowers/specs/2026-05-09-k8s-local-design.md
# ============================================================================

K8S_CLUSTER := microecom

.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status k8s-nuke k8s-stop k8s-start

k8s-cluster-up:
	@if ! kind get clusters | grep -q "^$(K8S_CLUSTER)$$"; then \
	  kind create cluster --config k8s/kind/cluster.yaml; \
	fi
	@k8s/kind/registry.sh
	@k8s/kind/preload-images.sh
	@kubectl cluster-info --context kind-$(K8S_CLUSTER)

k8s-cluster-down:
	-kind delete cluster --name $(K8S_CLUSTER)
	@echo "==> cluster deleted; kind-registry kept (built images preserved). Use 'make k8s-nuke' to remove it too."

# Full clean slate: delete the cluster AND the local registry (drops all built
# images, forcing a cold rebuild + re-pull on the next bootstrap). Use this only
# when you truly want nothing reused; the normal `make k8s-down` keeps images.
k8s-nuke: k8s-apps-down
	-kind delete cluster --name $(K8S_CLUSTER)
	-docker rm -f kind-registry
	@echo "==> cluster + registry destroyed (full clean slate)"

k8s-cluster-status:
	@kind get clusters
	@kubectl get nodes -o wide 2>/dev/null || echo "(cluster not running)"

# Pause the cluster without destroying it. kind nodes are Docker containers, so
# `docker stop` freezes them; all PVC data (MySQL/Mongo/Kafka/Redis/MinIO) and the
# built images survive. Resume with `make k8s-start` — far faster than a full
# bootstrap (no kind create, no image rebuild, no DB reseed).
k8s-stop:
	@nodes=$$(kind get nodes --name $(K8S_CLUSTER) 2>/dev/null); \
	  if [ -z "$$nodes" ]; then echo "cluster '$(K8S_CLUSTER)' not found — nothing to stop"; exit 0; fi; \
	  echo "==> stopping kind cluster '$(K8S_CLUSTER)' (data + images preserved)"; \
	  docker stop $$nodes kind-registry >/dev/null
	@echo "stopped. Resume with: make k8s-start"

# Resume a stopped cluster. Restarts the node + registry containers, waits for the
# API and infra, then RE-SEEDS Vault (dev mode is in-memory, so its secrets are
# lost on pod restart) and bounces the apps (which crash-loop on an empty Vault).
# Everything else (DB data, Kafka topics, MinIO bucket, images) persists.
k8s-start:
	@nodes=$$(kind get nodes --name $(K8S_CLUSTER) 2>/dev/null); \
	  if [ -z "$$nodes" ]; then echo "cluster '$(K8S_CLUSTER)' not found — run 'make k8s-bootstrap' first"; exit 1; fi; \
	  echo "==> starting kind cluster '$(K8S_CLUSTER)'"; \
	  docker start $$nodes kind-registry >/dev/null
	@echo "waiting for API server..."
	@until kubectl --context kind-$(K8S_CLUSTER) get nodes >/dev/null 2>&1; do sleep 3; done
	@echo "waiting for Vault + MySQL + Mongo to be ready..."
	@kubectl -n infra wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=5m
	@kubectl -n infra rollout status statefulset/mysql         --timeout=5m
	@kubectl -n infra rollout status statefulset/mysql-replica --timeout=5m
	@kubectl -n infra rollout status statefulset/mongodb       --timeout=5m
	@echo "re-seeding Vault (dev mode is in-memory)"
	@kubectl -n bootstrap delete job vault-seed --ignore-not-found >/dev/null
	@kubectl apply -k k8s/infra/jobs/03-vault-seed
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/vault-seed
	@echo "restarting apps so they re-read Vault"
	@kubectl -n apps rollout restart deployment
	@kubectl -n apps rollout status deployment --timeout=10m
	@echo "cluster resumed. Check: make k8s-status && make k8s-mysql-status"

.PHONY: k8s-build k8s-build-reuse k8s-rebuild

k8s-build:
	@k8s/images/build.sh

# Bootstrap build path: skip images already in the registry (fast down->bootstrap).
# `make k8s-bootstrap FORCE_BUILD=1` rebuilds everything from scratch instead.
k8s-build-reuse:
	@if [ -n "$(FORCE_BUILD)" ]; then k8s/images/build.sh; else REUSE_EXISTING=1 k8s/images/build.sh; fi

k8s-rebuild:
	@if [ -z "$(svc)" ]; then echo "Usage: make k8s-rebuild svc=NAME"; exit 1; fi
	@SVC=$(svc) SKIP_CORES=1 k8s/images/build.sh
	@kubectl -n apps rollout restart deployment/$(svc)

.PHONY: k8s-infra k8s-seed k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest k8s-seed-images k8s-app-secrets

k8s-infra:
	@k8s/infra/install.sh

# k8s-seed: run the PRE-APPS bootstrap Jobs in fixed dependency order. Each Job
# is idempotent (see seed.sh in each dir) so re-running is safe.
# Order matters: vault must be seeded before any app that imports its Spring
# config from vault; mongo (api_role) must be seeded before the gateway /
# authorization-server load their auth rules; minio before any storefront image
# upload. Kafka Connect registration runs last because Connect itself
# (Deployment) is started by k8s-infra.
#
# NOTE: mysql is deliberately NOT here — see k8s-seed-mysql below. It must run
# AFTER k8s-apps because docker/ecommerce.sql is data-only (no CREATE TABLE) and
# the schema is created by Hibernate ddl-auto when the JPA services boot.
#
# These four Jobs are applied with `kubectl apply -k` EXCEPT mongo, whose data
# configmap is built from out-of-tree docker/*.json that kubectl's embedded
# kustomize refuses to load — so it's created imperatively + applied with plain
# `kubectl apply -f`. See the kustomize SCAR in k8s/CLAUDE.md.
k8s-seed:
	@for d in 02-mongo-seed 03-vault-seed 05-minio-bootstrap 04-kafka-connect-register; do \
	  job=$$(echo $$d | sed 's/^[0-9]*-//'); \
	  echo "==> applying $$d (job/$$job)"; \
	  kubectl -n bootstrap delete job $$job --ignore-not-found >/dev/null; \
	  case "$$d" in \
	    02-mongo-seed) \
	      kubectl -n bootstrap create configmap mongo-seed-scripts \
	        --from-file=k8s/infra/jobs/02-mongo-seed/seed.sh --dry-run=client -o yaml | kubectl apply -f - ; \
	      kubectl -n bootstrap create configmap mongo-seed-data \
	        --from-file=docker/api_role.json --from-file=docker/product.json \
	        --from-file=docker/product-quantity-history.json --dry-run=client -o yaml | kubectl apply -f - ; \
	      kubectl apply -f k8s/infra/jobs/02-mongo-seed/job.yaml ;; \
	    *) kubectl apply -k k8s/infra/jobs/$$d ;; \
	  esac; \
	  kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/$$job; \
	done
	@echo "k8s-seed complete"

# k8s-seed-mysql: runs SEPARATELY, AFTER k8s-apps. docker/ecommerce.sql is a
# data-only dump (0 CREATE TABLE); the schema is created by Hibernate ddl-auto
# during each JPA service's startup. By the time `k8s-apps` reports rollout
# complete, every service is Ready — which (ddl-auto runs before the web server
# accepts traffic) means all tables already exist. Seeding earlier fails with
# "Table 'ecommerce_dev.account' doesn't exist". Both configmaps are created
# imperatively (out-of-tree docker/ecommerce.sql) and the Job applied with plain
# `kubectl apply -f`. See k8s/CLAUDE.md.
k8s-seed-mysql:
	@echo "==> applying 01-mysql-seed (job/mysql-seed)"
	@kubectl -n bootstrap delete job mysql-seed --ignore-not-found >/dev/null
	@kubectl -n bootstrap create configmap mysql-seed-scripts \
	  --from-file=k8s/infra/jobs/01-mysql-seed/seed.sh --dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n bootstrap create configmap mysql-seed-sql \
	  --from-file=docker/ecommerce.sql --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f k8s/infra/jobs/01-mysql-seed/job.yaml
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/mysql-seed
	@echo "k8s-seed-mysql complete"

# k8s-seed-inventory: populate inventory-service's MySQL tables
# (inventory_product + product_quantity_history) from the same JSON the Mongo
# catalog uses. Must run AFTER k8s-apps — inventory-service creates those tables
# via Hibernate ddl-auto at startup, and they're never written during a clean
# bootstrap (the Kafka ProductUpdate listener only fires on a real product save,
# which the Mongo seed bypasses). Without this every cart item shows
# "0 available". Host-side + idempotent, mirroring k8s-seed-images.
k8s-seed-inventory:
	@scripts/seed/k8s-inventory.sh

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
	@kubectl apply -k k8s/infra/jobs/06-perftest-seed
	@kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/perftest-seed
	@echo "k8s-seed-perftest complete"

# k8s-seed-images: upload the real product images (docker/seed-images/*) into
# MinIO at products/<id>/<slug>.jpg. Runs AFTER k8s-seed (needs the
# ecommerce-media bucket). Host-side because the images live in the repo, not a
# configMap. Idempotent (mc cp overwrites).
k8s-seed-images:
	@scripts/seed/k8s-product-images.sh

.PHONY: k8s-apps k8s-apps-down k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs k8s-storefront-smoke k8s-storefront-soak k8s-storefront-stress k8s-storefront-run k8s-storefront-logs k9s

# Apply all 8 service Deployments via the local overlay.
# k8s-app-secrets: build the `app-secrets` Secret in the apps namespace from
# k8s/.env (user-owned mail + PayPal creds). authorization-server and
# payment-service envFrom it. Kept out of git (k8s/.env is gitignored) and out
# of Vault. If k8s/.env is missing we create an empty Secret so the optional
# secretRef resolves (mail/PayPal just stay unset). Idempotent (apply).
k8s-app-secrets:
	@if [ -f k8s/.env ]; then \
	  kubectl create secret generic app-secrets --namespace apps \
	    --from-env-file=k8s/.env --dry-run=client -o yaml | kubectl apply -f - ; \
	else \
	  echo "warn: k8s/.env missing — creating empty app-secrets Secret. Copy k8s/.env.example to k8s/.env and re-run k8s-app-secrets for working mail/PayPal."; \
	  kubectl create secret generic app-secrets --namespace apps \
	    --dry-run=client -o yaml | kubectl apply -f - ; \
	fi

k8s-apps: k8s-app-secrets
	@kubectl apply -k k8s/apps/overlays/local
	@kubectl -n apps rollout status deployment --timeout=10m

k8s-apps-down:
	@kubectl delete -k k8s/apps/overlays/local --ignore-not-found

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
	  --from-file=k8s/apps/base/k6-stress/payment-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f k8s/apps/base/k6-stress/payment-job.yaml
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
	  --from-file=k8s/apps/base/k6-stress/storefront-flow.js --dry-run=client -o yaml | kubectl apply -f -
	@sed -e 's/PROFILE_PLACEHOLDER/$(PROFILE)/' \
	     -e 's/PEAK_RATE_PLACEHOLDER/$(PEAK_RATE)/' \
	     -e 's/MAX_VUS_PLACEHOLDER/$(MAX_VUS)/' \
	     -e 's/DURATION_PLACEHOLDER/$(STRESS_DUR)/' \
	     k8s/apps/base/k6-stress/storefront-job.yaml | kubectl apply -f -
	@echo "k6 storefront [$(PROFILE)] running. Watch with: make k8s-storefront-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-storefront-logs:
	@kubectl -n apps logs -f -l app=k6-storefront --tail=-1

# Launch k9s (terminal UI) on a chosen environment, using the repo's committed
# config (skin + namespace hotkeys). Switch contexts live inside k9s with :ctx.
#   make k9s            # ENV=local (default) → kind cluster
#   make k9s ENV=eks    # EKS (one-time: aws eks update-kubeconfig --alias microecom-eks)
# NOTE: pass ENV on the make line; a shell-exported ENV (e.g. ENV=staging) is
# also picked up and will be rejected as unknown — set it explicitly here.
k9s:
	@command -v k9s >/dev/null 2>&1 || { echo "k9s not installed — run: brew install k9s (other platforms: https://k9scli.io)"; exit 1; }
	@case "$(ENV)" in \
	  ""|local) ctx=kind-microecom ;; \
	  eks)      ctx=microecom-eks ;; \
	  *) echo "Unknown ENV '$(ENV)' — use ENV=local or ENV=eks"; exit 1 ;; \
	 esac; \
	 echo "k9s → context $$ctx (ENV=$${ENV:-local}), namespace apps"; \
	 K9S_CONFIG_DIR="$(CURDIR)/k8s/k9s" k9s --context "$$ctx" -n apps

.PHONY: k8s-bootstrap k8s-down

# One-shot: cluster -> infra -> images -> seed -> apps. Idempotent —
# safe to re-run after editing manifests or pulling new code. Mirrors
# the docker-compose `make bootstrap` flow but for the kind cluster.
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build-reuse k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory k8s-seed-perftest
	@echo "==> k8s bootstrap complete"
	@$(MAKE) k8s-status
	@echo ""
	@echo "================================================================"
	@echo "  Final step: add these lines to /etc/hosts (one-time):"
	@echo ""
	@echo "    127.0.0.1 microecom.local"
	@echo "    127.0.0.1 api.microecom.local"
	@echo ""
	@echo "  Then verify:"
	@echo "    curl -i http://api.microecom.local/authorization-server/actuator/health/liveness"
	@echo "    open http://microecom.local"
	@echo "================================================================"

# Tear it ALL down — apps, infra, and the kind cluster itself.
# Use k8s-apps-down for a softer reset (keeps infra/data).
k8s-down: k8s-apps-down k8s-cluster-down
	@echo "==> k8s cluster destroyed"

# ============================================================================
# AWS (ephemeral EKS) — see docs/superpowers/specs/2026-06-10-aws-deployment-design.md
# ============================================================================
.PHONY: aws-bootstrap aws-up aws-push aws-infra-up aws-down aws-leak-check aws-all

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

.PHONY: k8s-use k8s-ctx

k8s-ctx:
	@kubectl config current-context

k8s-use:
	@case "$(ENV)" in \
	""|local) ctx=kind-microecom ;; \
	eks)      ctx=microecom-eks ;; \
	*) echo "Unknown ENV '$(ENV)' — use ENV=local or ENV=eks"; exit 1 ;; \
	esac; \
	kubectl config use-context "$$ctx" && echo "==> now on $$ctx"
