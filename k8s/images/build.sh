#!/usr/bin/env bash
# Build images for the local kind cluster and push to the local registry.
#
# Usage:
#   k8s/images/build.sh                 # build cores + all services
#   SVC=order-service k8s/images/build.sh   # build cores + one service
#   SVC=cores k8s/images/build.sh           # rebuild cores only
set -euo pipefail

REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${TAG:-dev}"

cd "$(git rev-parse --show-toplevel)"

SERVICES=(
  authorization-server
  gateway
  inventory-service
  product-service
  order-service
  payment-service
  orchestrator-service
  bff-service
)

build_cores() {
  echo "==> building cores base image"
  docker build \
    -f k8s/images/Dockerfile.cores \
    -t "${REGISTRY}/maven-cores:${TAG}" \
    .
  docker push "${REGISTRY}/maven-cores:${TAG}"
}

build_service() {
  local svc="$1"
  echo "==> building ${svc}"
  docker build \
    -f k8s/images/Dockerfile.jvm \
    --build-arg "SERVICE=${svc}" \
    --build-arg "CORES_IMAGE=${REGISTRY}/maven-cores:${TAG}" \
    -t "${REGISTRY}/${svc}:${TAG}" \
    .
  docker push "${REGISTRY}/${svc}:${TAG}"
}

# Always rebuild cores first unless explicitly skipped (cores changes are rare,
# but service builds depend on the cores image existing in the registry).
if [ "${SVC:-}" = "cores" ]; then
  build_cores
  exit 0
fi

if [ -z "${SKIP_CORES:-}" ]; then
  build_cores
fi

if [ -n "${SVC:-}" ]; then
  build_service "$SVC"
else
  for svc in "${SERVICES[@]}"; do
    build_service "$svc"
  done
fi
