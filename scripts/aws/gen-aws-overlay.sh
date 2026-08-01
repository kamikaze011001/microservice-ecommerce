#!/usr/bin/env bash
# Generate the per-service AWS overlay dir (externalsecret + volume patch +
# kustomization) for every deployable service that doesn't already have a
# hand-written overlay. Mirrors k8s/apps/overlays/aws/authorization-server/
# exactly, parameterized by the service name. Re-runnable (overwrites generated
# dirs, never the hand-written ones).
#
# The service set is sourced from scripts/aws/services-secrets.list (single
# source of truth). Entries that are config-only contexts (no
# k8s/apps/base/<name> dir, e.g. core-s3, ecommerce) or hand-written
# (gateway, authorization-server) are skipped automatically.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OVERLAY="k8s/apps/overlays/aws"
ECR="583178372344.dkr.ecr.ap-southeast-1.amazonaws.com"
LIST="scripts/aws/services-secrets.list"

# Hand-written overlays we must never overwrite (leading/trailing spaces for word match).
HANDWRITTEN=" gateway authorization-server frontend "
# Services that also consume the shared S3 config context (avatars / product images).
S3_CONSUMERS=" product-service inventory-service "

while read -r svc _; do
  [[ -z "$svc" || "$svc" == "#"* ]] && continue                # skip comments / blanks
  [[ "$HANDWRITTEN" == *" $svc "* ]] && continue               # skip hand-written
  [[ -d "k8s/apps/base/$svc" ]] || { echo "· skip $svc (no base dir — config-only context)"; continue; }

  dir="$OVERLAY/$svc"; mkdir -p "$dir"

  # dataFrom precedence: shared contexts (app/ecommerce, app/core-s3) FIRST, the
  # service's own secret LAST — so a service-specific key always wins on key
  # collision. Mirrors the hand-written authorization-server/ overlay's order.
  datafrom=$'  dataFrom:\n    - extract: { key: app/ecommerce }'
  [[ "$S3_CONSUMERS" == *" $svc "* ]] && datafrom+=$'\n    - extract: { key: app/core-s3 }'
  datafrom+=$'\n    - extract: { key: app/'"${svc}"' }'

  cat > "$dir/externalsecret.yaml" <<YAML
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: $svc
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: $svc-config
    creationPolicy: Owner
$datafrom
YAML

  cat > "$dir/patch-volume.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $svc
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: $svc
          volumeMounts:
            - { name: app-config, mountPath: /etc/app-config, readOnly: true }
      volumes:
        - name: app-config
          secret:
            secretName: $svc-config
YAML

  cat > "$dir/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../base/$svc
  - externalsecret.yaml
components:
  - ../components/spring-secrets
patches:
  - path: patch-volume.yaml
images:
  - name: localhost:5000/$svc
    newName: $ECR/$svc
    newTag: dev
YAML
  echo "▶ generated $dir"
done < "$LIST"
echo "✅ done. Verify $OVERLAY/kustomization.yaml lists each dir, then apply."
