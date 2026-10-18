# Intended deviations from golden/k8s.json — applied to the golden before
# equivalence-test.sh diffs it. The golden stays untouched (it is evidence of
# what the deleted legacy sources produced); every DELIBERATE change since is
# a reviewable line here, with its reason.

# 2026-10-10, devbox phase 3a: in-cluster app hosts are namespace-relative
# (`order-service`, not `order-service.apps.svc.cluster.local`), so one Vault
# value routes each devbox env to its own services. See contexts/k8s.yaml.
# Infra hosts (`*.infra.svc.cluster.local`) are shared and unchanged.
walk(if type == "string" then gsub("(?<svc>[a-z-]+)\\.apps\\.svc\\.cluster\\.local"; "\(.svc)") else . end)

# 2026-10-18, ADR 0012: each migrated service (identified below by a key only it
# owns: payment, inventory, order, auth, orchestrator) connects through ProxySQL with
# one plain spring.datasource.* set (no master/slave routing, no Atomikos).
# The resolved values must match deploy/secrets/contexts/k8s.yaml mysql.proxy.*.
| if type == "object" and (has("application.paypal.success-path")
                          or has("application.kafka.group-id.product.update")
                          or has("application.kafka.group-id.order.update-status")
                          or has("application.authentication-key-id")
                          or has("application.saga.saga-ttl-minutes")) then . + {
  "spring.datasource.driver-class-name": "com.mysql.cj.jdbc.Driver",
  "spring.datasource.url": "jdbc:mysql://proxysql.infra.svc.cluster.local:6033/ecommerce_dev?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC",
  "spring.datasource.username": "root",
  "spring.datasource.password": "root"
} else . end

# 2026-10-18, ADR 0012: nothing reads the shared master/slave routing set since
# core-routing-db was deleted, so the shared `ecommerce` path no longer carries it.
| if type == "object" and has("spring.datasource.master.url") then
    with_entries(select(.key | test("^spring\\.datasource\\.(master|slave1|slave2)\\.") | not))
  else . end
