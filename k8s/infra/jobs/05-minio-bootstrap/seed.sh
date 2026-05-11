#!/usr/bin/env sh
# MinIO bootstrap Job — ensure bucket exists and the two public-read
# prefixes (products/, avatars/) have anonymous download enabled.
#
# Idempotent: mc mb --ignore-existing is a no-op if the bucket exists,
# and mc anonymous set is idempotent — re-applying the same policy is
# fine. No precheck needed.
set -eu

ALIAS=local
ENDPOINT="${MINIO_ENDPOINT:-http://minio.infra.svc.cluster.local:9000}"
USER="${MINIO_ROOT_USER:-minioadmin}"
PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"
BUCKET="${MINIO_BUCKET:-ecommerce-media}"

echo "configuring mc alias -> ${ENDPOINT}"
mc alias set "${ALIAS}" "${ENDPOINT}" "${USER}" "${PASS}" >/dev/null

echo "ensuring bucket ${BUCKET}"
mc mb --ignore-existing "${ALIAS}/${BUCKET}" >/dev/null

# Both prefixes are read-publicly; clients fetch image URLs directly
# from MinIO without going through any JVM service. Writes still
# require a presigned URL (server-side signed, 5min TTL).
for prefix in products avatars; do
  echo "setting anonymous download on ${BUCKET}/${prefix}"
  mc anonymous set download "${ALIAS}/${BUCKET}/${prefix}" >/dev/null
done

echo "minio bootstrap complete"
