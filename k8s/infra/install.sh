#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Repos
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
# NOTE: no bitnami repo — the 5 stateful services migrated to Docker Official
# images as plain manifests (Bitnami images deleted 2025-09-29). See k8s/CLAUDE.md.
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
# metrics-server: upstream kubernetes-sigs chart (NOT bitnami/metrics-server).
# Bitnami deleted docker.io/bitnami/* versioned images on 2025-09-29; the
# upstream chart is the maintained, free replacement.
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update

# Namespaces
for ns in infra apps monitoring bootstrap; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done

# Ingress
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace infra \
  --version 4.10.0 \
  -f k8s/infra/values/ingress-nginx.yaml \
  --wait --timeout 5m

# Metrics-server (separate chart) — required for HPA.
# Upstream kubernetes-sigs chart. --kubelet-insecure-tls is required on kind
# (kubelet serving certs are self-signed); InternalIP avoids inter-node
# hostname resolution issues. Upstream uses an `args` list, NOT bitnami's
# `extraArgs`/`apiService.create` keys.
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace infra \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --wait --timeout 3m

# Observability: VictoriaMetrics single-node + Grafana + kube-state-metrics.
# See docs/superpowers/specs/2026-06-02-victoriametrics-observability-design.md
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring \
  --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml \
  --wait --timeout 5m

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --version 10.5.15 \
  -f k8s/infra/values/grafana.yaml \
  --wait --timeout 5m

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace monitoring \
  --wait --timeout 3m

# ── Stateful services — Docker Official images as plain manifests ────────────
# Migrated off Bitnami (docker.io/bitnami/* deleted 2025-09-29). Each manifest
# keeps its Service DNS name unchanged so the Vault seed + app config + seed
# Jobs need no edits. See k8s/CLAUDE.md and the design spec.
MANIFESTS=k8s/infra/manifests

# MongoDB needs an internal keyFile (auth + replica set together). Create it
# only if missing — re-runs must NOT rotate it, since rotating the keyfile
# would break the already-initialized replica set.
if ! kubectl -n infra get secret mongodb-keyfile >/dev/null 2>&1; then
  echo "creating mongodb-keyfile secret"
  kubectl -n infra create secret generic mongodb-keyfile \
    --from-literal=keyfile="$(openssl rand -base64 756 | tr -d '\n')"
fi

kubectl apply \
  -f "$MANIFESTS/mysql.yaml" \
  -f "$MANIFESTS/mysql-replica-service.yaml" \
  -f "$MANIFESTS/mongodb.yaml" \
  -f "$MANIFESTS/redis.yaml" \
  -f "$MANIFESTS/minio.yaml" \
  -f "$MANIFESTS/minio-ingress.yaml" \
  -f "$MANIFESTS/kafka.yaml"

# Wait for each to be Ready. The mongodb `bootstrap` and minio `setup` sidecars
# gate pod-readiness on a completion sentinel, so a Ready pod guarantees the
# replica-set users / bucket already exist — the seed Jobs that run later won't
# race ahead and fail to authenticate or write.
kubectl -n infra rollout status statefulset/mysql   --timeout=5m
kubectl -n infra rollout status statefulset/mongodb --timeout=5m
kubectl -n infra rollout status deployment/redis    --timeout=3m
kubectl -n infra rollout status statefulset/minio   --timeout=5m
kubectl -n infra rollout status statefulset/kafka   --timeout=5m

helm upgrade --install vault hashicorp/vault \
  --namespace infra --version 0.27.0 \
  -f k8s/infra/values/vault.yaml --wait --timeout 5m

# Sensitive creds (PayPal, mail) come from k8s/.env (gitignored, not in
# any committed values.yaml or seed.sh). The vault-seed Job mounts this
# Secret via envFrom and references the keys from inside seed.sh.
# If k8s/.env is missing we still create an empty Secret so the Job's
# envFrom resolves — the put_if_missing blocks that reference these env
# vars will just write empty strings (acceptable for a smoke install
# without a working PayPal sandbox account).
if [ -f k8s/.env ]; then
  kubectl create secret generic vault-seed-env \
    --namespace bootstrap \
    --from-env-file=k8s/.env \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "warn: k8s/.env missing — creating empty vault-seed-env Secret. Copy k8s/.env.example to k8s/.env and re-run for working mail/PayPal."
  kubectl create secret generic vault-seed-env \
    --namespace bootstrap \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Kafka Connect — long-running Deployment hosting source/sink connectors.
# Connector registration is a separate Job (k8s/infra/jobs/04-kafka-connect-register).
kubectl apply -f k8s/infra/manifests/kafka-connect.yaml
kubectl -n infra rollout status deployment/kafka-connect --timeout=5m

echo "infra install complete"
