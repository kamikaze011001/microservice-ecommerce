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
	@echo "  make k8s-down         — tear down apps + cluster"
	@echo "  make k8s-status       — pods across nodes/infra/bootstrap/apps"
	@echo "  make k8s-apps         — re-apply just the service overlay"
	@echo "  make k8s-rebuild svc=NAME — rebuild one image + rollout restart"
	@echo "  make k8s-stress       — fire k6 load Job (opt-in)"
	@echo "  make k8s-stress-logs  — tail k6 output"

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

.PHONY: k8s-cluster-up k8s-cluster-down k8s-cluster-status

k8s-cluster-up:
	@if ! kind get clusters | grep -q "^$(K8S_CLUSTER)$$"; then \
	  kind create cluster --config k8s/kind/cluster.yaml; \
	fi
	@k8s/kind/registry.sh
	@kubectl cluster-info --context kind-$(K8S_CLUSTER)

k8s-cluster-down:
	-kind delete cluster --name $(K8S_CLUSTER)
	-docker rm -f kind-registry

k8s-cluster-status:
	@kind get clusters
	@kubectl get nodes -o wide 2>/dev/null || echo "(cluster not running)"

.PHONY: k8s-build k8s-rebuild

k8s-build:
	@k8s/images/build.sh

k8s-rebuild:
	@if [ -z "$(svc)" ]; then echo "Usage: make k8s-rebuild svc=NAME"; exit 1; fi
	@SVC=$(svc) SKIP_CORES=1 k8s/images/build.sh
	@kubectl -n apps rollout restart deployment/$(svc)

.PHONY: k8s-infra k8s-seed k8s-seed-mysql k8s-seed-inventory k8s-seed-images k8s-app-secrets

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

# k8s-seed-images: upload the real product images (docker/seed-images/*) into
# MinIO at products/<id>/<slug>.jpg. Runs AFTER k8s-seed (needs the
# ecommerce-media bucket). Host-side because the images live in the repo, not a
# configMap. Idempotent (mc cp overwrites).
k8s-seed-images:
	@scripts/seed/k8s-product-images.sh

.PHONY: k8s-apps k8s-apps-down k8s-status k8s-stress k8s-stress-logs

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

# Fire the k6 stress Job. Opt-in (NOT part of k8s-apps) so `make k8s-apps`
# doesn't trigger load. Re-runnable — deletes the previous Job first.
k8s-stress:
	@kubectl -n apps delete job k6-stress --ignore-not-found
	@kubectl apply -k k8s/apps/base/k6-stress
	@echo "k6 stress running. Watch with: make k8s-stress-logs"
	@echo "Watch HPA: kubectl -n apps get hpa -w"

k8s-stress-logs:
	@kubectl -n apps logs -f -l app=k6-stress --tail=-1

.PHONY: k8s-bootstrap k8s-down

# One-shot: cluster -> infra -> images -> seed -> apps. Idempotent —
# safe to re-run after editing manifests or pulling new code. Mirrors
# the docker-compose `make bootstrap` flow but for the kind cluster.
k8s-bootstrap: k8s-cluster-up k8s-infra k8s-build k8s-seed k8s-seed-images k8s-apps k8s-seed-mysql k8s-seed-inventory
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
