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
  s3.public-endpoint="http://media.microecom.local" \
  s3.region="us-east-1" \
  s3.bucket="ecommerce-media" \
  s3.access-key="minioadmin" \
  s3.secret-key="minioadmin" \
  s3.path-style="true" \
  s3.public-base-url="http://media.microecom.local/ecommerce-media" \
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
  spring.data.mongodb.database="ecommerce_inventory" \
  spring.kafka.bootstrap-servers="kafka.infra.svc.cluster.local:9092" \
  spring.kafka.properties.schema.registry.url="http://schema-registry.infra.svc.cluster.local:8081" \
  eureka.client.enabled="false" \
  spring.mail.host="smtp.gmail.com" \
  spring.mail.port="587" \
  spring.mail.protocol="smtp" \
  spring.mail.properties.mail.smtp.auth="true" \
  spring.mail.properties.mail.smtp.starttls.enable="true"
  # NOTE: spring.mail.username/password are NOT seeded here. They are user-owned
  # creds supplied via the app-secrets k8s Secret (k8s/.env → envFrom on
  # authorization-server); application.yml reads them as ${APPLICATION_MAIL_*}.
  # Seeding blank values here would shadow the env vars.

# authorization-server: token policy + JWK key-id. Values mirror
# docker/vault-configs/authorization-server.json. application.jwk is the STABLE
# RSA signing key (private JWK JSON) loaded by AuthorizationServerConfiguration;
# it MUST be identical across restarts and replicas because the gateway caches
# JWKS by kid — a per-startup key broke token validation on every deploy and
# blocked horizontal scaling of the auth tier. life-times are milliseconds.
# (The original k8s seed omitted this block, so the service crashed with
# "Could not resolve placeholder 'application.access-token.life-time'".)
put_if_missing authorization-server \
  server.port="6666" \
  application.access-token.life-time="900000" \
  application.refresh-token.life-time="604800000" \
  application.authentication-key-id="ecommerce-auth-key-2024" \
  application.jwk='{"kty":"RSA","kid":"ecommerce-auth-key-2024","use":"sig","alg":"RS256","n":"8O-ohPxhOmVzHBBVTXIC5_peX3twa0-cbaaU-HuGtRx1KkvMrC4CcBv1uzM00O4DDrNuYuSvpuNusF5l0aLcywYjq7kq4tTD1BznKmjUuas9XPGC4ZDS_F537Gw74oPjFvCfvsXQjbQkjyupnKuFM7F6Qk2on4VEvCI6nbpHSWET5Rthy2nZJwcxw1rHTjm2xqzOANe88vZia02x5yIu51qlh9AuJQQ8GmM8_ikS4yAcGom5HbvIPpl2jLpKlHMjGFjQuAkEgg3VkBDpxcJYVM_AmJvSfPwYpEaQoaerayrVriXxhOreRUakErxjWXfx4fE4aqqMv1O_76lUGK8fSQ","e":"AQAB","d":"BsR8jnZhAW5oZtE7TChtK3iYCQTjGf3g-MrVOWDi3kMf3rcarHrDB8TJSLT-AUuw20tanj1_2jyzgbxiY2_jKsgP3XAfORgyg0qSiwQ_IWiixHG7iZFzU7Jlmkb0rFP5tM2_zEXV1KfK38NMCYIJ2kixv0YGJquWzCqxTHfh2Q4_4q_nqQUW-R1fzWmgNdqss6aohP1r52QopsTdRIv0394YRdr-lHb17UXJ8lIpMZJQxuvFZRNbYA8d6jabJrzS37cIRYXd977S2GNLCO9zbOEDxm_Vfd3hSs-_9U5i1_x00N1VJzxTkcMGvulmbPg4cdm2-YY9n1QySc08xbOdwQ","p":"_ORNmdZaNAdNPsYnXfw6Z7DaUEtujtLavaWuwCJO0KwP9GHDoYZ9AOz4CJZhut4N69-7-kC3VXqA2ZydPXkt1lVs-I7eTdfiRpqq6x-YC59JLcD2jeQP3hU50lRoYgI59BAw2r5zKf_g-FAivRuTWv5zAEZ1YkxzIQwG1ziXKBk","q":"8-W87cVZcceULkLuEbXo-xbuWbFW-iPmg5FsCmVq2MBWVLjYCYHrysFbRjDVBErEB8ZIGqtP5jQjpjuT7SSLmyq5mLcWzhT602t-aWvOI_Z6f-mproQCzhsbp9WlzhMqBOswTlitOdVFtSH0_jJmSB7Ie4JxOPi7W4Li9VzUVrE","dp":"jIBfKNgxl3RzEyxOVOY8oL1eHXw7OXimdPUnKLIm7cKavqDOauBodOozR7odJBAY1fKg4oGwGfqMudpMdgnsUId3moTtt3v4yFdIHIeaFuLxak0p7l1F_5H1ZQjmUYWBIzsXmYB0RWJXYD5NfplifgyeYgnDT9C_qh2fc1WKjYk","dq":"5shjjmWoLjaYa3HfjZig_T6EiRB6abUgwSwQnIG8qZ7N0dsaaVyrfi6aLH-2gRoyBd1Eix_BOeXqObi0T7e99jRmbDAK_zPw568WbbCZ3YO0BGdYrQ6zDM2vzI8oFigiIYdeLTRRraC2FiAsj3-nMuUV9XDHrA4IUx41ndCaB_E","qi":"kdzDggJVAyKwuNiLAr38A8fl33dg3lmT_nqm7rE2KH22xuveYPbVepcnE5ijT-dULtObB60XYBi0fs8fjWSqt90-3MZPv8Kb8DWXNZSlGmlefJOE6Wky_1chaKSoUECIWYo5enxNe1nwTmnMLkWRxw3IzoL7QfON-ARuYq66ITc"}'

# gateway: jwt/jwk config AND route URIs MUST be in ONE put_if_missing call —
# put_if_missing skips a path that already exists, so a second `put_if_missing
# gateway` block would be silently dropped. The route URIs replace the
# application.yml `lb://NAME` (Eureka) defaults with in-cluster Service DNS;
# required because Eureka is disabled (eureka.client.enabled=false). Without
# them gateway routes resolve to lb:// → no instances → 503 on every request.
put_if_missing gateway \
  server.port="6868" \
  application.jwk-set-uri="http://authorization-server/authorization-server/.well-known/jwks.json" \
  jwt.token.retry.max-attempts="3" \
  jwt.token.retry.delay="500" \
  jwt.token.cache.refresh-minutes="30" \
  jwt.token.cache.force-refresh-threshold="5" \
  gateway.routes.authorization-server.uri="http://authorization-server.apps.svc.cluster.local:6666" \
  gateway.routes.inventory-service.uri="http://inventory-service.apps.svc.cluster.local:6969" \
  gateway.routes.product-service.uri="http://product-service.apps.svc.cluster.local:7777" \
  gateway.routes.order-service.uri="http://order-service.apps.svc.cluster.local:9696" \
  gateway.routes.payment-service.uri="http://payment-service.apps.svc.cluster.local:8484" \
  gateway.routes.bff-service.uri="http://bff-service.apps.svc.cluster.local:8087" \
  gateway.routes.mock-paypal-service.uri="http://mock-paypal-service.apps.svc.cluster.local:8585"

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
# from envFrom (k8s Secret built from k8s/.env). frontend base-url is the
# BROWSER-FACING SPA host: IPNPaypalController issues a 302 redirect to
# `${frontend.base-url}/payment/success` after PayPal returns, so it must be a
# host the user's browser can resolve — the ingress host (microecom.local), NOT
# the in-cluster Service DNS (which NXDOMAINs in the browser). In AWS this
# becomes the public SPA domain.
put_if_missing payment-service \
  server.port="8484" \
  application.frontend.base-url="http://microecom.local" \
  application.paypal.base-url="https://api-m.sandbox.paypal.com" \
  application.paypal.success-path="/payment-service/v1/paypal:success" \
  application.paypal.cancel-path="/payment-service/v1/paypal:cancel"
  # NOTE: application.paypal.client-id/client-secret/tunnel-url are NOT seeded
  # here. They are user-owned creds supplied via the app-secrets k8s Secret
  # (k8s/.env → envFrom on payment-service); application.yml reads them as
  # ${PAYPAL_*}. Seeding blank values here would shadow the env vars.

# bff-service: eureka.* keys omitted — k8s uses Service DNS, not Eureka.
# inventory.grpc.host swapped to in-cluster Service DNS.
put_if_missing bff-service \
  server.port="8087" \
  inventory.grpc.host="inventory-service.apps.svc.cluster.local" \
  inventory.grpc.port="9090" \
  feign.client.product-service.url="http://product-service.apps.svc.cluster.local:7777" \
  feign.client.order-service.url="http://order-service.apps.svc.cluster.local:9696" \
  feign.client.payment-service.url="http://payment-service.apps.svc.cluster.local:8484"

# mock-paypal-service: standalone PayPal mock (stress test / local dev).
put_if_missing mock-paypal-service \
  server.port="8585" \
  mock.public-base-url="http://api.microecom.local/mock-paypal-service"

echo "vault baseline seed complete"
