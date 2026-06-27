#!/usr/bin/env bash
# Build arm64 images and push them to ECR.
#
# Thin wrapper over the existing k8s/images/build.sh — that script is already
# REGISTRY/TAG/SVC-parameterized and builds the maven-cores base first. We add
# two things: ECR docker-login, and reading the registry host from the bootstrap
# stack output so the URL is never hard-coded.
#
# build.sh's contract (NOT positional args — it reads $SVC):
#   SVC=gateway  -> builds maven-cores + gateway
#   SVC=cores    -> builds maven-cores only
#   (no SVC)     -> builds maven-cores + ALL services
#
# Usage:
#   scripts/aws/push-images.sh            # Phase 2 minimum: gateway (+ cores base)
#   scripts/aws/push-images.sh gateway    # one named service (+ cores base)
#   scripts/aws/push-images.sh all        # everything (+ cores base)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"
TAG="${TAG:-dev}"

# AWS serves the SPA same-origin behind the gateway ALB, so the frontend image
# must be built with an EMPTY API base → the SPA issues relative calls
# (fetch('/bff-service/v1/…')). build.sh uses ${VITE_API_BASE_URL-default}
# (no colon), so this empty value is preserved rather than falling back.
export VITE_API_BASE_URL=""

# Registry host comes from the persistent bootstrap stack (Task 1's output),
# e.g. 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
REGISTRY="$(terraform -chdir="$ROOT/aws/bootstrap" output -raw ecr_registry)"

# Phase 2 default target is the gateway; "all" means build the whole catalog.
TARGET="${1:-gateway}"

# 1. Authenticate docker to ECR. The token is a 12h STS-backed credential, not a
#    stored secret — re-run this script if a later push 401s.
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# 2. Build + push via the existing builder. "all" -> leave SVC unset.
if [ "$TARGET" = "all" ]; then
  REGISTRY="$REGISTRY" TAG="$TAG" "$ROOT/k8s/images/build.sh"
  echo "✅ pushed ALL services (+ maven-cores) to $REGISTRY (tag: $TAG)"
else
  REGISTRY="$REGISTRY" TAG="$TAG" SVC="$TARGET" "$ROOT/k8s/images/build.sh"
  echo "✅ pushed $TARGET (+ maven-cores base) to $REGISTRY (tag: $TAG)"
fi
