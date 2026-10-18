# Intended deviations from golden/compose.json — see k8s.jq for the convention.

# 2026-10-18, ADR 0012 step 2: payment-service connects through ProxySQL with
# one plain spring.datasource.* set (no master/slave routing, no Atomikos).
# The resolved values must match deploy/secrets/contexts/compose.yaml mysql.proxy.*.
if type == "object" and has("application.paypal.success-path") then . + {
  "spring.datasource.driver-class-name": "com.mysql.cj.jdbc.Driver",
  "spring.datasource.url": "jdbc:mysql://localhost:6033/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.username": "ecommerce",
  "spring.datasource.password": "ecommerce_app"
} else . end
