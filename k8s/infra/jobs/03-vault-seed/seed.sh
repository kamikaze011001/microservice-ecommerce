#!/usr/bin/env sh
# Vault seed Job — baseline secrets only (s3, db/redis/mongo/kafka, jwt).
# Path layout for remaining services is decided in Checkpoint 5 (Task 16).
#
# Idempotency: vault kv put is unconditional, but we gate each path with
# `vault kv get` first — if the path already has data, skip. This means a
# re-run after a partial failure picks up where it left off, and a re-run
# after manual edits leaves the manual values alone.
set -eu

export VAULT_ADDR="${VAULT_ADDR:-http://vault.infra.svc.cluster.local:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

# Enable KV v2 at secret/ (no-op if already mounted).
vault secrets enable -version=2 -path=secret kv 2>/dev/null || true

put_if_missing() {
  path="$1"
  shift
  if vault kv get "secret/${path}" >/dev/null 2>&1; then
    echo "secret/${path} exists; skipping"
    return 0
  fi
  echo "writing secret/${path}"
  vault kv put "secret/${path}" "$@"
}

# ── core-s3 ────────────────────────────────────────────────────────────────
put_if_missing core-s3 \
  s3.endpoint="http://minio.infra.svc.cluster.local:9000" \
  s3.region="us-east-1" \
  s3.bucket="ecommerce-media" \
  s3.access-key="minioadmin" \
  s3.secret-key="minioadmin" \
  s3.path-style="true" \
  s3.public-base-url="http://minio.infra.svc.cluster.local:9000/ecommerce-media" \
  s3.presign-ttl="PT5M" \
  s3.max-upload-size="5242880" \
  s3.allowed-types="image/jpeg,image/png,image/webp"

# ── ecommerce common (db, redis, mongo, kafka) ─────────────────────────────
# Master writes → mysql; reads → mysql-replica (same Pod, different Service).
put_if_missing ecommerce \
  spring.datasource.master.url="jdbc:mysql://mysql.infra.svc.cluster.local:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC" \
  spring.datasource.master.username="root" \
  spring.datasource.master.password="root" \
  spring.datasource.master.driver-class-name="com.mysql.cj.jdbc.Driver" \
  spring.datasource.slave1.url="jdbc:mysql://mysql-replica.infra.svc.cluster.local:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC" \
  spring.datasource.slave1.username="root" \
  spring.datasource.slave1.password="root" \
  spring.datasource.slave1.driver-class-name="com.mysql.cj.jdbc.Driver" \
  spring.datasource.slave2.url="jdbc:mysql://mysql-replica.infra.svc.cluster.local:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC" \
  spring.datasource.slave2.username="root" \
  spring.datasource.slave2.password="root" \
  spring.datasource.slave2.driver-class-name="com.mysql.cj.jdbc.Driver" \
  spring.data.redis.host="redis-master.infra.svc.cluster.local" \
  spring.data.redis.port="6379" \
  spring.data.redis.password="" \
  spring.data.redis.database="0" \
  spring.data.mongodb.uri="mongodb://ecommerce:ecommerce123@mongodb.infra.svc.cluster.local:27017/ecommerce_inventory?authSource=admin" \
  spring.kafka.bootstrap-servers="kafka.infra.svc.cluster.local:9092"

# ── authorization-server (jwt) ─────────────────────────────────────────────
put_if_missing authorization-server \
  server.port="6666" \
  application.access-token.life-time="900000" \
  application.refresh-token.life-time="604800000" \
  application.authentication-key-id="ecommerce-auth-key-2026"

echo "vault baseline seed complete"
