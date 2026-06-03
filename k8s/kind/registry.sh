#!/usr/bin/env bash
# Local Docker registry for the kind cluster.
# Each kind node is pointed at this registry via the containerd `config_path`
# hosts.toml mechanism (written below), so `docker push localhost:5001/svc:tag`
# from the host is pulled by Pods as `localhost:5001/svc:tag` from inside the
# cluster. We deliberately do NOT use a `containerdConfigPatches` mirrors block
# in cluster.yaml: containerd 2.x (kindest/node from kind >= 0.30) rejects inline
# `registry.mirrors` when `config_path` is set, which breaks the CRI plugin.
# Ref: https://kind.sigs.k8s.io/docs/user/local-registry/
set -euo pipefail

CLUSTER_NAME='microecom'
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

# Point each node's containerd at the registry via config_path hosts.toml.
# kind already sets config_path=/etc/containerd/certs.d in the node image, so we
# just drop a hosts.toml per node — picked up live, no containerd restart needed.
REG_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REG_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REG_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done

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
