#!/usr/bin/env bash
# Push per-service config+secrets into AWS Secrets Manager as JSON whose keys are
# the EXACT dotted Spring property names. ESO materializes these verbatim into a
# k8s Secret; the pod mounts it and reads it via configtree (filename = property).
#
# This is the cloud twin of k8s/infra/jobs/03-vault-seed/seed.sh. Non-secret
# config (ports, in-cluster Service DNS, kafka topics) is identical kind<->EKS, so
# the values match seed.sh. Genuine user-owned creds (PayPal, mail) are read from
# the environment so they never live in git. Run AFTER `terraform apply` (the
# containers must exist) and BEFORE `kubectl apply -k` the apps overlay.
#
# Usage:  AWS_PROFILE=microecom PAYPAL_CLIENT_ID=... PAYPAL_CLIENT_SECRET=... \
#         APPLICATION_MAIL_USERNAME=... APPLICATION_MAIL_PASSWORD=... \
#         scripts/aws/seed-secrets.sh
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"

# Required user-owned creds (fail loudly if absent rather than seeding blanks).
: "${PAYPAL_CLIENT_ID:?set PAYPAL_CLIENT_ID}"
: "${PAYPAL_CLIENT_SECRET:?set PAYPAL_CLIENT_SECRET}"
: "${APPLICATION_MAIL_USERNAME:?set APPLICATION_MAIL_USERNAME}"
: "${APPLICATION_MAIL_PASSWORD:?set APPLICATION_MAIL_PASSWORD}"

# The stable RSA signing JWK — MUST be byte-identical to seed.sh's application.jwk
# (the gateway caches JWKS by kid; a different key breaks every token). Sourced
# from the env or a file to avoid a second copy drifting; export APPLICATION_JWK.
: "${APPLICATION_JWK:?set APPLICATION_JWK (the private RSA JWK JSON from seed.sh)}"

# ── Managed-endpoint discovery (Phase 4a — RDS) ──────────────────────────────
# Read the RDS coordinates straight from terraform state so the seeded JDBC URLs
# can never drift from what was actually provisioned. Run this seed AFTER
# `terraform apply`; the outputs won't exist before then. -raw strips the quotes;
# db_master_password is a sensitive output but -raw still returns it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/aws/main"
tf_out() {  # tf_out <output-name>
  terraform -chdir="$TF" output -raw "$1" 2>/dev/null \
    || { echo "ERROR: terraform output '$1' missing — run 'terraform apply' (Phase 4a) first" >&2; exit 1; }
}
RDS_PRIMARY="$(tf_out rds_primary_endpoint)"
RDS_REPLICA="$(tf_out rds_replica_endpoint)"
DB_PASS="$(tf_out db_master_password)"

put() {  # put <service> <json>
  local svc="$1" json="$2"
  echo "▶ app/${svc}"
  # put-secret-value fails with ResourceNotFoundException if the container is
  # missing — i.e. the seed was run before `terraform apply` created the
  # Secrets Manager secret resources. Turn that into an actionable message
  # instead of a bare AWS stack trace that aborts the run under `set -e`.
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id "app/${svc}" --secret-string "$json" >/dev/null \
    || { echo "ERROR: secret app/${svc} not found — run 'terraform apply' (Task 2) first" >&2; exit 1; }
}

DNS=svc.cluster.local

put core-s3 "$(jq -n '{
  "s3.endpoint":"http://minio.infra.'"$DNS"':9000",
  "s3.public-endpoint":"http://media.microecom.local",
  "s3.region":"us-east-1","s3.bucket":"ecommerce-media",
  "s3.access-key":"minioadmin","s3.secret-key":"minioadmin","s3.path-style":"true",
  "s3.public-base-url":"http://media.microecom.local/ecommerce-media",
  "s3.presign-ttl":"PT5M","s3.max-upload-size":"5242880",
  "s3.allowed-types":"image/jpeg,image/png,image/webp"
}')"

put ecommerce "$(jq -n \
  --arg mu "$APPLICATION_MAIL_USERNAME" --arg mp "$APPLICATION_MAIL_PASSWORD" \
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" --arg rhost "$RDS_REPLICA" '{
  "spring.datasource.master.url":("jdbc:mysql://"+$mhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.master.username":"admin","spring.datasource.master.password":$dpw,
  "spring.datasource.master.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave1.url":("jdbc:mysql://"+$rhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.slave1.username":"admin","spring.datasource.slave1.password":$dpw,
  "spring.datasource.slave1.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.datasource.slave2.url":("jdbc:mysql://"+$rhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.slave2.username":"admin","spring.datasource.slave2.password":$dpw,
  "spring.datasource.slave2.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "spring.data.redis.host":"redis-master.infra.'"$DNS"'","spring.data.redis.port":"6379",
  "spring.data.redis.password":"","spring.data.redis.database":"0",
  "spring.data.mongodb.uri":"mongodb://ecommerce:ecommerce123@mongodb.infra.'"$DNS"':27017/ecommerce_inventory?authSource=admin",
  "spring.data.mongodb.database":"ecommerce_inventory",
  "spring.kafka.bootstrap-servers":"kafka.infra.'"$DNS"':9092",
  "spring.kafka.properties.schema.registry.url":"http://schema-registry.infra.'"$DNS"':8081",
  "eureka.client.enabled":"false",
  "spring.mail.host":"smtp.gmail.com","spring.mail.port":"587","spring.mail.protocol":"smtp",
  "spring.mail.properties.mail.smtp.auth":"true","spring.mail.properties.mail.smtp.starttls.enable":"true",
  "spring.mail.username":$mu,"spring.mail.password":$mp,
  "management.metrics.distribution.percentiles-histogram.http.server.requests":"true"
}')"

put authorization-server "$(jq -n --arg jwk "$APPLICATION_JWK" '{
  "server.port":"6666",
  "application.access-token.life-time":"900000",
  "application.refresh-token.life-time":"604800000",
  "application.authentication-key-id":"ecommerce-auth-key-2024",
  "application.jwk":$jwk
}')"

put gateway "$(jq -n '{
  "server.port":"6868",
  "application.jwk-set-uri":"http://authorization-server/authorization-server/.well-known/jwks.json",
  "jwt.token.retry.max-attempts":"3","jwt.token.retry.delay":"500",
  "jwt.token.cache.refresh-minutes":"30","jwt.token.cache.force-refresh-threshold":"5",
  "gateway.routes.authorization-server.uri":"http://authorization-server.apps.'"$DNS"':6666",
  "gateway.routes.inventory-service.uri":"http://inventory-service.apps.'"$DNS"':6969",
  "gateway.routes.product-service.uri":"http://product-service.apps.'"$DNS"':7777",
  "gateway.routes.order-service.uri":"http://order-service.apps.'"$DNS"':9696",
  "gateway.routes.payment-service.uri":"http://payment-service.apps.'"$DNS"':8484",
  "gateway.routes.bff-service.uri":"http://bff-service.apps.'"$DNS"':8087",
  "gateway.routes.mock-paypal-service.uri":"http://mock-paypal-service.apps.'"$DNS"':8585"
}')"

put product-service "$(jq -n '{
  "server.port":"7777",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.topics.product-service.product.update-quantity":"product-service.product.update-quantity",
  "application.kafka.group-id.product-service.product.update-quantity":"product-service.product.update-quantity"
}')"

put inventory-service "$(jq -n '{
  "server.port":"6969","grpc.server.port":"9090",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.topics.inventory-service.inventory-product.update-quantity":"inventory-service.inventory-product.update-quantity",
  "application.kafka.group-id.product.update":"product-update-group",
  "application.kafka.group-id.payment.success":"payment-success-group"
}')"

put order-service "$(jq -n '{
  "server.port":"9696",
  "grpc.server.host":"inventory-service.apps.'"$DNS"'","grpc.server.port":"9090",
  "application.kafka.topics.order-service.order.success-status":"order-service.order.success-status",
  "application.kafka.topics.order-service.order.failed-status":"order-service.order.failed-status",
  "application.kafka.topics.order-service.order.canceled-status":"order-service.order.canceled-status",
  "application.kafka.group-id.order.update-status":"order.update-status"
}')"

put orchestrator-service "$(jq -n \
  --arg dpw "$DB_PASS" --arg mhost "$RDS_PRIMARY" '{
  "server.port":"9999",
  "spring.datasource.url":("jdbc:mysql://"+$mhost+":3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
  "spring.datasource.username":"admin","spring.datasource.password":$dpw,
  "spring.datasource.driver-class-name":"com.mysql.cj.jdbc.Driver",
  "application.kafka.topics.mongo.event":"ecommerce_db.ecommerce_inventory.event",
  "application.kafka.topics.product-service.product.update-quantity":"product-service.product.update-quantity",
  "application.kafka.topics.order-service.order.success-status":"order-service.order.success-status",
  "application.kafka.topics.order-service.order.failed-status":"order-service.order.failed-status",
  "application.kafka.topics.order-service.order.canceled-status":"order-service.order.canceled-status",
  "application.kafka.topics.inventory-service.inventory-product.update-quantity":"inventory-service.inventory-product.update-quantity",
  "application.kafka.topics.inventory-service.product.update":"inventory-service.product.update",
  "application.kafka.group-id.mongo.event":"mongo-event-group",
  "application.saga.timeout-check-interval":"60000",
  "application.saga.compensation-max-retries":"3","application.saga.saga-ttl-minutes":"30"
}')"

put payment-service "$(jq -n \
  --arg cid "$PAYPAL_CLIENT_ID" --arg sec "$PAYPAL_CLIENT_SECRET" '{
  "server.port":"8484",
  "application.frontend.base-url":"http://microecom.local",
  "application.paypal.base-url":"https://api-m.sandbox.paypal.com",
  "application.paypal.success-path":"/payment-service/v1/paypal:success",
  "application.paypal.cancel-path":"/payment-service/v1/paypal:cancel",
  "application.paypal.client-id":$cid,"application.paypal.client-secret":$sec
}')"

put bff-service "$(jq -n '{
  "server.port":"8087",
  "inventory.grpc.host":"inventory-service.apps.'"$DNS"'","inventory.grpc.port":"9090",
  "feign.client.product-service.url":"http://product-service.apps.'"$DNS"':7777",
  "feign.client.order-service.url":"http://order-service.apps.'"$DNS"':9696",
  "feign.client.payment-service.url":"http://payment-service.apps.'"$DNS"':8484"
}')"

put mock-paypal-service "$(jq -n '{
  "server.port":"8585",
  "mock.public-base-url":"http://api.microecom.local/mock-paypal-service"
}')"

echo "✅ Secrets Manager seed complete."
