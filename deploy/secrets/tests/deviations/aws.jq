# Intended deviations from golden/aws.json — see k8s.jq for the convention.

# 2026-10-18, ADR 0012: each migrated service (identified below by a key only it
# owns: payment, inventory, order, auth) connects through ProxySQL with
# one plain spring.datasource.* set (no master/slave routing, no Atomikos).
# The resolved values must match deploy/secrets/contexts/aws.yaml mysql.proxy.*.
if type == "object" and (has("application.paypal.success-path")
                          or has("application.kafka.group-id.product.update")
                          or has("application.kafka.group-id.order.update-status")
                          or has("application.authentication-key-id")) then . + {
  "spring.datasource.driver-class-name": "com.mysql.cj.jdbc.Driver",
  "spring.datasource.url": "jdbc:mysql://microecom-fixture.cluster-xxxx.ap-southeast-1.rds.amazonaws.com:3306/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.username": "admin",
  "spring.datasource.password": "fixture-db-password"
} else . end
