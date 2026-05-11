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
  spring.kafka.bootstrap-servers="kafka.infra.svc.cluster.local:9092" \
  spring.mail.host="smtp.gmail.com" \
  spring.mail.port="587" \
  spring.mail.protocol="smtp" \
  spring.mail.properties.mail.smtp.auth="true" \
  spring.mail.properties.mail.smtp.starttls.enable="true" \
  spring.mail.username="${APPLICATION_MAIL_USERNAME:-}" \
  spring.mail.password="${APPLICATION_MAIL_PASSWORD:-}"

put_if_missing gateway \
  server.port="6868" \
  application.jwk-set-uri="http://authorization-server/authorization-server/.well-known/jwks.json" \
  jwt.token.retry.max-attempts="3" \
  jwt.token.retry.delay="500" \
  jwt.token.cache.refresh-minutes="30" \
  jwt.token.cache.force-refresh-threshold="5"

put_if_missing product-service \
  server.port="7777" \
  application.kafka.topics.inventory-service.product.update="inventory-service.product.update" \
  application.kafka.topics.product-service.product.update-quantity="product-service.product.update-quantity" \
  application.kafka.group-id.product-service.product.update-quantity="product-service.product.update-quantity"

put_if_missing inventory-service \
  server.port="6969" \
  grpc.server.port="9090" \
  application.kafka.topics.inventory-service.product.update="inventory-service.product.update" \
  application.kafka.topics.inventory-service.inventory-product.update-quantity="inventory-service.inventory-product.update-quantity" \
  application.kafka.group-id.product.update="product-update-group" \
  application.kafka.group-id.payment.success="payment-success-group"

# order-service: grpc host swapped from localhost to in-cluster inventory Service DNS.
put_if_missing order-service \
  server.port="9696" \
  grpc.server.host="inventory-service.apps.svc.cluster.local" \
  grpc.server.port="9090" \
  application.kafka.topics.order-service.order.success-status="order-service.order.success-status" \
  application.kafka.topics.order-service.order.failed-status="order-service.order.failed-status" \
  application.kafka.topics.order-service.order.canceled-status="order-service.order.canceled-status" \
  application.kafka.group-id.order.update-status="order.update-status"

# orchestrator-service: datasource host localhost->mysql Service DNS, password
# normalised to root (matches the kind cluster's mysql chart rootPassword).
put_if_missing orchestrator-service \
  server.port="9999" \
  spring.datasource.url="jdbc:mysql://mysql.infra.svc.cluster.local:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC" \
  spring.datasource.username="root" \
  spring.datasource.password="root" \
  spring.datasource.driver-class-name="com.mysql.cj.jdbc.Driver" \
  application.kafka.topics.mongo.event="ecommerce_db.ecommerce_inventory.event" \
  application.kafka.topics.product-service.product.update-quantity="product-service.product.update-quantity" \
  application.kafka.topics.order-service.order.success-status="order-service.order.success-status" \
  application.kafka.topics.order-service.order.failed-status="order-service.order.failed-status" \
  application.kafka.topics.order-service.order.canceled-status="order-service.order.canceled-status" \
  application.kafka.topics.inventory-service.inventory-product.update-quantity="inventory-service.inventory-product.update-quantity" \
  application.kafka.topics.inventory-service.product.update="inventory-service.product.update" \
  application.kafka.group-id.mongo.event="mongo-event-group" \
  application.saga.timeout-check-interval="60000" \
  application.saga.compensation-max-retries="3" \
  application.saga.saga-ttl-minutes="30"

# payment-service: PayPal client-id, client-secret, and tunnel-url come
# from envFrom (k8s Secret built from k8s/.env). frontend base-url points
# at the in-cluster frontend Pod (or replaced by the ALB hostname in AWS).
put_if_missing payment-service \
  server.port="8484" \
  application.frontend.base-url="http://frontend.apps.svc.cluster.local" \
  application.paypal.base-url="https://api-m.sandbox.paypal.com" \
  application.paypal.success-path="/payment-service/v1/paypal:success" \
  application.paypal.cancel-path="/payment-service/v1/paypal:cancel" \
  application.paypal.client-id="${PAYPAL_CLIENT_ID:-}" \
  application.paypal.client-secret="${PAYPAL_CLIENT_SECRET:-}" \
  application.paypal.tunnel-url="${PAYPAL_TUNNEL_URL:-}"

# bff-service: eureka.* keys omitted — k8s uses Service DNS, not Eureka.
# inventory.grpc.host swapped to in-cluster Service DNS.
put_if_missing bff-service \
  server.port="8087" \
  inventory.grpc.host="inventory-service.apps.svc.cluster.local" \
  inventory.grpc.port="9090"

echo "vault baseline seed complete"
