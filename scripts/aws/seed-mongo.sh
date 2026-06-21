#!/usr/bin/env bash
# Seed MongoDB (api_role + product + productQuantityHistory) on the EKS cluster.
#
# Mongo stays self-hosted in-cluster in Phase 4 (only MySQL/Redis/MinIO move to
# managed services), so the existing k8s/infra/jobs/02-mongo-seed Job runs here
# verbatim — it connects to mongodb.infra.svc.cluster.local. This is the AWS twin
# of the Makefile `k8s-seed` 02-mongo-seed case.
#
# WHY this is critical: without api_role the gateway 403s every route; without
# product the catalog is empty. The Job itself is fail-closed (waits for mongo
# PRIMARY, verifies non-empty counts before reporting success).
#
# The two configMaps are created imperatively (NOT a kustomize generator): the
# data files live under docker/, out of the Job's kustomize tree, and kubectl's
# embedded kustomize forbids out-of-tree configMapGenerator sources. See the
# SCAR note in k8s/infra/jobs/02-mongo-seed/job.yaml.
#
# Idempotent: the Job's seed.sh skips when api_role already has docs; we delete
# the prior Job first because Jobs are immutable.
#
# Usage:  AWS_PROFILE=microecom scripts/aws/seed-mongo.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOB_DIR="$ROOT/k8s/infra/jobs/02-mongo-seed"

# bootstrap ns is created by infra-up.sh; ensure it exists so this is runnable
# standalone too.
kubectl get ns bootstrap >/dev/null 2>&1 || kubectl create ns bootstrap

echo "▶ (re)creating mongo-seed configmaps in bootstrap ns ..."
kubectl -n bootstrap create configmap mongo-seed-scripts \
  --from-file="$JOB_DIR/seed.sh" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n bootstrap create configmap mongo-seed-data \
  --from-file="$ROOT/docker/api_role.json" \
  --from-file="$ROOT/docker/product.json" \
  --from-file="$ROOT/docker/product-quantity-history.json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▶ applying mongo-seed Job ..."
kubectl -n bootstrap delete job mongo-seed --ignore-not-found >/dev/null
kubectl apply -f "$JOB_DIR/job.yaml"

echo "▶ waiting for mongo-seed to complete (the Job verifies non-empty counts) ..."
kubectl -n bootstrap wait --for=condition=complete --timeout=5m job/mongo-seed
echo "✅ mongo seed complete (api_role + product + productQuantityHistory)."
