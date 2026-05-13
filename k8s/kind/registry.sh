#!/usr/bin/env bash
# Local Docker registry for the kind cluster.
# kind nodes are configured (via containerdConfigPatches in cluster.yaml) to mirror
# localhost:5001 to this container, so `docker push localhost:5001/svc:tag` from the
# host is pulled by Pods as `localhost:5001/svc:tag` from inside the cluster.
set -euo pipefail

REG_NAME='kind-registry'
REG_PORT='5001'

# Start registry container if missing
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "${REG_NAME}" registry:2
fi

# Connect registry to kind network if not already connected
if [ "$(docker network ls --filter name=kind -q)" ] && \
   [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' ${REG_NAME})" = 'null' ]; then
  docker network connect kind "${REG_NAME}"
fi

# Document the registry to the cluster (KEP-1755)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "registry running at localhost:${REG_PORT}"
