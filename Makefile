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
