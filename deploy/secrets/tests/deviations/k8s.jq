# Intended deviations from golden/k8s.json — applied to the golden before
# equivalence-test.sh diffs it. The golden stays untouched (it is evidence of
# what the deleted legacy sources produced); every DELIBERATE change since is
# a reviewable line here, with its reason.

# 2026-10-10, devbox phase 3a: in-cluster app hosts are namespace-relative
# (`order-service`, not `order-service.apps.svc.cluster.local`), so one Vault
# value routes each devbox env to its own services. See contexts/k8s.yaml.
# Infra hosts (`*.infra.svc.cluster.local`) are shared and unchanged.
walk(if type == "string" then gsub("(?<svc>[a-z-]+)\\.apps\\.svc\\.cluster\\.local"; "\(.svc)") else . end)
