#!/usr/bin/env bash
# Assert which cluster a destructive kubectl call will hit. Source, don't execute.
#
# Why this exists: scripts/aws/down.sh deletes Ingresses so the in-cluster AWS
# Load Balancer Controller deprovisions the ALB, THEN runs terraform destroy.
# Terraform does not know the ALB exists. If those deletes silently hit the wrong
# cluster, the ALB survives, keeps billing, and appears in no terraform state.
#
# The three outcomes are deliberately distinct exit codes: "the context is not in
# your kubeconfig" and "the cluster is not answering" call for different operator
# responses, and collapsing them into one is how a teardown ends up half-done.

# require_kube_context <context>
#   0 = context exists in kubeconfig AND its API server answers
#   1 = context is not in kubeconfig
#   2 = context exists but the cluster did not answer
require_kube_context() {
    local ctx="${1:-}"
    [ -n "$ctx" ] || return 1

    # -qxF: exact whole-line match. A context merely CONTAINING the name is a
    # different cluster.
    kubectl config get-contexts -o name 2>/dev/null \
        | grep -qxF "$ctx" || return 1

    # /readyz over a bounded timeout. Without --request-timeout this blocks on
    # the default (no timeout) against a dead endpoint.
    kubectl --context "$ctx" --request-timeout=10s get --raw /readyz \
        >/dev/null 2>&1 || return 2

    return 0
}
