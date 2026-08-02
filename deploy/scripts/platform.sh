#!/usr/bin/env bash
# Cluster-wide platform charts + Helm dependency vendoring.
#
# ingress-nginx and metrics-server stay SEPARATE releases, not umbrella
# dependencies: they are cluster-wide singletons, and on EKS both are replaced
# outright (ALB controller, EKS addon). Bundling them into a release that also
# owns the MySQL data would mean a failed ingress upgrade can touch a database.
#
#   ./deploy/scripts/platform.sh [ENV]      ENV: local-k8s (default) | aws
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/colors.sh
. deploy/scripts/lib/colors.sh

ENV="${1:-local-k8s}"
CHART=deploy/charts/microecom

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# `helm dependency update` does NOT recurse into subcharts — it must run against
# charts/infra directly. `build` (not `update`) so Chart.lock stays authoritative.
log_info "vendoring infra subchart dependencies"
helm dependency build "$CHART/charts/infra"

if [ "$ENV" = "aws" ]; then
  log_warn "aws platform charts (ALB controller, EKS addons) are Phase 7 — skipping"
  exit 0
fi

log_info "installing ingress-nginx"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace infra --create-namespace \
  --version 4.10.0 \
  -f k8s/infra/values/ingress-nginx.yaml \
  --wait --timeout 5m

# --kubelet-insecure-tls: minikube kubelet serving certs are self-signed.
# InternalIP avoids inter-node hostname resolution issues. Upstream chart uses
# an `args` list, NOT bitnami's extraArgs/apiService.create keys.
log_info "installing metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace infra \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --wait --timeout 3m

log_ok "platform ready"
