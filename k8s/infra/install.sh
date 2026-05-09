#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Repos
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
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

# Metrics-server (separate chart) — required for HPA
helm upgrade --install metrics-server bitnami/metrics-server \
  --namespace infra \
  --set apiService.create=true \
  --set extraArgs[0]=--kubelet-insecure-tls \
  --wait --timeout 3m

# kube-prometheus-stack
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 58.2.0 \
  -f k8s/infra/values/kube-prometheus-stack.yaml \
  --wait --timeout 10m

helm upgrade --install mysql bitnami/mysql \
  --namespace infra \
  --version 11.1.0 \
  -f k8s/infra/values/mysql.yaml \
  --wait --timeout 5m

kubectl apply -f k8s/infra/manifests/mysql-replica-service.yaml

helm upgrade --install mongodb bitnami/mongodb \
  --namespace infra --version 15.6.0 \
  -f k8s/infra/values/mongodb.yaml --wait --timeout 5m

helm upgrade --install redis bitnami/redis \
  --namespace infra --version 19.5.0 \
  -f k8s/infra/values/redis.yaml --wait --timeout 3m

helm upgrade --install minio bitnami/minio \
  --namespace infra --version 14.6.0 \
  -f k8s/infra/values/minio.yaml --wait --timeout 5m

helm upgrade --install kafka bitnami/kafka \
  --namespace infra --version 29.2.0 \
  -f k8s/infra/values/kafka.yaml --wait --timeout 8m

helm upgrade --install vault hashicorp/vault \
  --namespace infra --version 0.27.0 \
  -f k8s/infra/values/vault.yaml --wait --timeout 5m

echo "infra install complete"
