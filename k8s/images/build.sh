#!/usr/bin/env bash
# Build images for the local minikube cluster and push to its registry addon.
#
# Usage:
#   k8s/images/build.sh                 # build cores + all services
#   SVC=order-service k8s/images/build.sh   # build cores + one service
#   SVC=cores k8s/images/build.sh           # rebuild cores only
set -euo pipefail

# Host builds push through the port-forward on 5001. Pods pull the same
# repositories through the registry addon's node proxy on localhost:5000.
REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${TAG:-dev}"

# How many service images to build at once. Safe only because each service has
# its own Maven cache (id=m2-${SERVICE} in Dockerfile.jvm) -- Maven's local
# repository is not safe for concurrent writes. 4 is conservative for a 12-core
# laptop; raise it if the machine is idle during a build.
BUILD_JOBS="${BUILD_JOBS:-4}"

# Absolute path to this script, resolved BEFORE the cd below. The parallel build
# re-execs one child per service and callers invoke us both relatively (Makefile)
# and absolutely (scripts/aws/push-images.sh), so "$0" is not reliable here.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

cd "$(git rev-parse --show-toplevel)"

if ! curl -fsS -o /dev/null "http://${REGISTRY}/v2/" 2>/dev/null; then
  echo "ERROR: registry at ${REGISTRY} is not reachable." >&2
  echo "Run 'make k8s-cluster-up' or 'make k8s-registry-forward' first." >&2
  exit 1
fi

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

# maven-cores is a BUILD-ONLY base: Dockerfile.jvm consumes it through
# `FROM ${CORES_IMAGE}`, which resolves from the local image store. No pod ever
# pulls it, so it is not pushed -- that keeps 764 MB off the registry forward on
# every build. Its reuse check therefore asks docker, not the registry.
image_in_local_store() {  # $1=repo:tag -> exit 0 if present locally
  docker image inspect "$1" >/dev/null 2>&1
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
  if [ -n "${REUSE_EXISTING:-}" ] && image_in_local_store "${REGISTRY}/maven-cores:${TAG}"; then
    echo "==> reusing ${REGISTRY}/maven-cores:${TAG} (already in the local image store)"
    return 0
  fi
  echo "==> building cores base image"
  docker build \
    -f k8s/images/Dockerfile.cores \
    -t "${REGISTRY}/maven-cores:${TAG}" \
    .
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
  #   - local/minikube (var UNSET): defaults to http://api.microecom.local.
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
  # Build the service images concurrently. Each child re-execs this script with
  # SVC set, so it runs exactly one build_service; REGISTRY / TAG /
  # REUSE_EXISTING / VITE_API_BASE_URL are already exported by the caller and
  # are inherited. xargs exits non-zero if any child failed and `set -e` turns
  # that into a failed run -- verified on macOS xargs, which returns 1.
  # BUILDKIT_PROGRESS=plain because concurrent fancy progress renderers fight
  # over the terminal and produce unreadable output.
  echo "==> building ${#SERVICES[@]} services, ${BUILD_JOBS} at a time"
  printf '%s\n' "${SERVICES[@]}" \
    | BUILDKIT_PROGRESS=plain xargs -P "${BUILD_JOBS}" -I{} \
        env SVC={} SKIP_CORES=1 "$SELF"
  build_frontend
  build_mock_paypal
fi
