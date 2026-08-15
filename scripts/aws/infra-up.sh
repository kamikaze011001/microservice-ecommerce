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

# ── Default StorageClass: gp3 (xfs, encrypted) — MUST precede any PVC ─────────
# The infra statefulsets' volumeClaimTemplates name no storageClassName, so each
# PVC binds to the cluster's DEFAULT class. A fresh EKS ships gp2 as the default
# (in-tree provisioner, ext4 → Kafka's lost+found crash). Apply our gp3 class
# (ebs.csi.aws.com, xfs, encrypted) as the new default and demote gp2 BEFORE the
# statefulsets below create their PVCs, or those PVCs sit Pending forever with
# "no storage class is set". Idempotent: apply + patch both re-run cleanly.
echo "▶ applying gp3 default StorageClass (xfs) + demoting gp2"
kubectl apply -f k8s/infra/overlays/aws/storageclass-gp3.yaml
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  >/dev/null 2>&1 || true

# ── Helm repos for the observability charts ──────────────────────────────────
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update vm grafana

# ── External Secrets Operator (ESO) + ClusterSecretStore ─────────────────────
# ESO materializes AWS Secrets Manager secrets into native k8s Secrets, which the
# JVM apps consume via configtree (Phase 3). The controller's SA uses IRSA — no
# static AWS keys. installCRDs=true installs the ExternalSecret/ClusterSecretStore
# CRDs. Ordering is load-bearing: the SA must exist BEFORE the Helm install,
# because the chart runs with serviceAccount.create=false and a pod whose
# serviceAccountName doesn't exist is rejected by SA admission — `helm --wait`
# would then deadlock until timeout. So: stamp+apply the SA, THEN helm (pod
# schedules with the IRSA-annotated SA from creation, no restart needed), THEN
# apply the ClusterSecretStore (which needs the CRD the chart just installed).
echo "▶ installing External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

# 1. SA first, with the real IRSA role ARN from terraform (Task 2 must be applied).
ESO_ROLE_ARN="$(cd aws/main && terraform output -raw eso_irsa_role_arn)" || {
  echo "ERROR: 'terraform output eso_irsa_role_arn' failed — run Task 2 first (cd aws/main && terraform apply)" >&2
  exit 1
}
sed "s|PLACEHOLDER_ESO_ROLE_ARN|${ESO_ROLE_ARN}|" \
  "$MANIFESTS/external-secrets-sa.yaml" | kubectl apply -f -

# 2. Helm install (chart uses our pre-created SA; --wait blocks until controller is up).
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace infra --version 0.10.4 \
  --set installCRDs=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets \
  --wait --timeout 5m

# 3. ClusterSecretStore last (needs the CRD the chart installed in step 2).
kubectl apply -f "$MANIFESTS/external-secrets-store.yaml"

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
# The values files enable an nginx-class Ingress (vm/grafana.microecom.local) for
# local kind + ingress-nginx. On EKS there is NO ingress-nginx, and the AWS Load
# Balancer Controller's validating webhook rejects any Ingress whose class isn't
# found ("IngressClass nginx not found"). Phase 2 reaches these via port-forward,
# so disable both ingresses here via --set — the shared values files stay
# untouched and local behavior is unchanged. (Same portability principle as the
# xfs StorageClass fix: AWS-specific deltas live in the AWS path, not the base.)
echo "▶ installing VictoriaMetrics (single)"
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml \
  --set server.ingress.enabled=false \
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
  --set ingress.enabled=false \
  --wait --timeout 5m

# ── Register the Mongo CDC connector (best-effort) ───────────────────────────
# Mirrors install.sh's note that registration is a separate Job. Best-effort in
# Phase 2: the connector is the Saga's Mongo→Kafka stream, which no Phase-2
# workload consumes yet, so a registration hiccup must NOT fail the infra bring-up.
echo "▶ registering Kafka Connect connectors (best-effort)"
if kubectl apply -k deploy/k8s-jobs/04-kafka-connect-register/; then
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
