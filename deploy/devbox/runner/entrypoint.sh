#!/usr/bin/env bash
# Give devbox.sh the named kube context it insists on (it never uses an ambient
# one): "devbox-runner", built from the pod's own ServiceAccount — this cluster,
# nothing else. Then run the one command the portal asked for.
set -euo pipefail

SA=/var/run/secrets/kubernetes.io/serviceaccount
kubectl config set-cluster in-cluster --server=https://kubernetes.default.svc \
  --certificate-authority="$SA/ca.crt" >/dev/null
kubectl config set-credentials devbox-runner --token="$(cat "$SA/token")" >/dev/null
kubectl config set-context devbox-runner --cluster=in-cluster --user=devbox-runner >/dev/null
# seed.sh also checks kubectl's CURRENT context matches --context (its guard
# against seeding the wrong cluster) — so select it, not just define it.
kubectl config use-context devbox-runner >/dev/null

export CONTEXT=devbox-runner
echo "devbox-runner: $*"
exec bash /workspace/deploy/devbox/devbox.sh "$@"
