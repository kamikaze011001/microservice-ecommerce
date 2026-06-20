#!/usr/bin/env bash
# Deploy the Phase 2 self-hosted infra SUBSET onto the CURRENT kubectl context:
#   Kafka (KRaft) · Schema Registry · Kafka Connect · MongoDB · VictoriaMetrics · Grafana
#
# This mirrors the relevant steps of k8s/infra/install.sh — it does NOT rewrite
# them. The manifests are context-agnostic: because gp3 is the default
# StorageClass (Task 4) and the EBS CSI driver is installed (Task 3), the very
# same kafka.yaml / mongodb.yaml that bind kind local-path volumes now bind real
# AWS EBS volumes. That portability is the whole point of the migration.
#
# NOT in Phase 2 (come later): MySQL / Redis / MinIO / Vault / the JVM apps.
# (Spec §8 — those arrive with the apps in Phase 3, then get swapped for
#  RDS/ElastiCache/S3 in Phase 4.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

MANIFESTS="k8s/infra/manifests"

# ── Guard: never run this against the local kind cluster by accident ─────────
CTX="$(kubectl config current-context)"
if [[ "$CTX" != "microecom-eks" ]]; then
  echo "✋ kubectl context is '$CTX', not 'microecom-eks'. Aborting so we don't"
  echo "   deploy the AWS infra subset onto kind. Run:"
  echo "     aws eks update-kubeconfig --name microecom-eks --region ap-southeast-1 --alias microecom-eks"
  exit 1
fi
echo "▶ context OK: $CTX"

# ── Namespaces (idempotent) ──────────────────────────────────────────────────
for ns in infra monitoring bootstrap; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done

# ── Helm repos for the observability charts ──────────────────────────────────
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update vm grafana

# ── MongoDB keyfile Secret (auth + replica set) ──────────────────────────────
# Create only if missing — re-runs must NOT rotate it, or the already-initialized
# single-member replica set breaks. (Same rule as install.sh.)
if ! kubectl -n infra get secret mongodb-keyfile >/dev/null 2>&1; then
  echo "▶ creating mongodb-keyfile secret"
  kubectl -n infra create secret generic mongodb-keyfile \
    --from-literal=keyfile="$(openssl rand -base64 756 | tr -d '\n')"
fi

# ── Stateful workloads → EBS-backed PVCs ─────────────────────────────────────
# MongoDB (4Gi) + Kafka (10Gi) carry volumeClaimTemplates with NO storageClassName,
# so each PVC binds to the gp3 default → one encrypted EBS volume per replica.
echo "▶ applying MongoDB + Kafka"
kubectl apply -f "$MANIFESTS/mongodb.yaml" -f "$MANIFESTS/kafka.yaml"

# WaitForFirstConsumer means the EBS volume isn't cut until the pod is scheduled,
# so "rollout complete" here is also the proof the volume provisioned in-AZ.
kubectl -n infra rollout status statefulset/mongodb --timeout=8m
kubectl -n infra rollout status statefulset/kafka   --timeout=8m

# Schema Registry depends on Kafka (stores subjects in a compacted _schemas topic).
# 10m (not 5m): the confluentinc/cp-* image is ~1.8GB and a cold node pull alone
# can take ~5m. Same reasoning as install.sh.
echo "▶ applying Schema Registry"
kubectl apply -f "$MANIFESTS/schema-registry.yaml"
kubectl -n infra rollout status deployment/schema-registry --timeout=10m

# Kafka Connect — hosts the Mongo CDC source connector (registered below).
echo "▶ applying Kafka Connect"
kubectl apply -f "$MANIFESTS/kafka-connect.yaml"
kubectl -n infra rollout status deployment/kafka-connect --timeout=10m

# ── Observability: VictoriaMetrics single + Grafana ──────────────────────────
echo "▶ installing VictoriaMetrics (single)"
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml \
  --wait --timeout 5m

# Custom dashboards (JVM/Kafka/MySQL) → ConfigMap that Grafana mounts as a volume,
# so it MUST exist before the grafana pod starts. Glob *.json explicitly so a
# stray file (e.g. .DS_Store) never becomes a key Grafana fails to parse.
echo "▶ creating grafana-custom-dashboards ConfigMap"
kubectl create configmap grafana-custom-dashboards \
  --namespace monitoring \
  $(find k8s/infra/dashboards -name '*.json' | sort | sed 's/^/--from-file=/') \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▶ installing Grafana"
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version 10.5.15 \
  -f k8s/infra/values/grafana.yaml \
  --wait --timeout 5m

# ── Register the Mongo CDC connector (best-effort) ───────────────────────────
# Mirrors install.sh's note that registration is a separate Job. Best-effort in
# Phase 2: the connector is the Saga's Mongo→Kafka stream, which no Phase-2
# workload consumes yet, so a registration hiccup must NOT fail the infra bring-up.
echo "▶ registering Kafka Connect connectors (best-effort)"
if kubectl apply -k k8s/infra/jobs/04-kafka-connect-register/; then
  kubectl -n bootstrap wait --for=condition=complete job/kafka-connect-register --timeout=3m \
    || echo "warn: connector register Job did not complete in 3m — not fatal for Phase 2 (check later with: kubectl -n bootstrap logs job/kafka-connect-register)"
else
  echo "warn: could not apply connector register Job — skipping (not fatal for Phase 2)"
fi

# ── Summary — the Phase 2 money shot ─────────────────────────────────────────
echo ""
echo "✅ infra subset up. PVCs should be Bound on gp3 (each = a real EBS volume):"
kubectl -n infra get pvc
echo ""
kubectl -n infra get pods
echo ""
echo "Prove the PVCs became AWS EBS volumes:"
echo "  aws ec2 describe-volumes --region ap-southeast-1 \\"
echo "    --filters Name=tag:kubernetes.io/created-for/pvc/name,Values='*' \\"
echo "    --query 'Volumes[].{id:VolumeId,size:Size,az:AvailabilityZone,state:State}' --output table"
