#!/usr/bin/env bash
# Load 3rd-party images referenced by the infra manifests from the host Docker
# into the kind nodes, so a freshly (re)created cluster does not cold-pull them
# from docker.io (the Confluent images are ~1.8GB). Images not yet on the host
# are skipped and pull normally the first time. Idempotent.
set -euo pipefail

CLUSTER_NAME='microecom'
cd "$(git rev-parse --show-toplevel)"

# Only run if the cluster exists (kind load targets its nodes).
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "preload-images: cluster '${CLUSTER_NAME}' not found, skipping"
  exit 0
fi

grep -rhE '^[[:space:]]*image:' k8s/infra/manifests/*.yaml \
  | awk '{print $2}' | sort -u \
  | while read -r img; do
      [ -n "$img" ] || continue
      if docker image inspect "$img" >/dev/null 2>&1; then
        echo "==> kind load $img"
        kind load docker-image "$img" --name "${CLUSTER_NAME}"
      else
        echo "skip (not on host yet, will pull): $img"
      fi
    done

echo "preload-images: done"
