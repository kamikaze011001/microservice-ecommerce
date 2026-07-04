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

# When REUSE_EXISTING is set, skip building an image whose tag is already in the
# local registry. Used by `make k8s-build-reuse` (the bootstrap path) so a
# down->bootstrap cycle does not rebuild unchanged images. `make k8s-build`
# leaves REUSE_EXISTING unset = always rebuild. Fails "closed": if the registry
# probe errors, the image is treated as absent and gets built.
image_in_registry() {  # $1=repo $2=tag -> exit 0 if present
  curl -fsS -o /dev/null \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/$1/manifests/$2" 2>/dev/null
}
reuse_or_build() {  # $1=repo -> exit 0 (caller should skip) if reusing
  if [ -n "${REUSE_EXISTING:-}" ] && image_in_registry "$1" "${TAG}"; then
    echo "==> reusing ${REGISTRY}/$1:${TAG} (already in registry)"
    return 0
  fi
  return 1
}

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
  reuse_or_build "maven-cores" && return 0
  echo "==> building cores base image"
  docker build \
    -f k8s/images/Dockerfile.cores \
    -t "${REGISTRY}/maven-cores:${TAG}" \
    .
  docker push "${REGISTRY}/maven-cores:${TAG}"
}

build_service() {
  local svc="$1"
  reuse_or_build "${svc}" && return 0
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

build_frontend() {
  reuse_or_build "frontend" && return 0
  echo "==> building frontend"
  # VITE_API_BASE_URL is inlined at build time (Vite compiles env vars in).
  #   - local/kind (var UNSET): defaults to http://api.microecom.local (nginx host).
  #   - AWS (var set to ""): kept empty → the SPA issues RELATIVE calls
  #     (fetch('/bff-service/v1/…')) and is served same-origin behind the ALB.
  # The dash (no colon) is load-bearing: ${VAR-default} only falls back when the
  # var is UNSET, so an intentional empty value from AWS survives. ${VAR:-default}
  # would clobber the empty string back to the local host.
  docker build \
    -f frontend/Dockerfile \
    --build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL-http://api.microecom.local}" \
    -t "${REGISTRY}/frontend:${TAG}" \
    frontend
  docker push "${REGISTRY}/frontend:${TAG}"
}

build_mock_paypal() {
  reuse_or_build "mock-paypal-service" && return 0
  echo "==> building mock-paypal-service (Java 25, standalone Dockerfile)"
  docker build \
    -f mock-paypal-service/Dockerfile \
    -t "${REGISTRY}/mock-paypal-service:${TAG}" \
    mock-paypal-service
  docker push "${REGISTRY}/mock-paypal-service:${TAG}"
}

if [ -n "${SVC:-}" ]; then
  if [ "$SVC" = "frontend" ]; then
    build_frontend
  elif [ "$SVC" = "mock-paypal-service" ]; then
    build_mock_paypal
  else
    build_service "$SVC"
  fi
else
  for svc in "${SERVICES[@]}"; do
    build_service "$svc"
  done
  build_frontend
  build_mock_paypal
fi
