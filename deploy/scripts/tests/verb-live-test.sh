#!/usr/bin/env bash
# Layer B — live compose run for the Phase 6 unified verbs (`make <verb>
# ENV=<env>`). Proves the compose verb set actually works through the new
# entry points, not just that they expand to the right command text (that's
# Layer A / verb-equivalence-test.sh, which is offline). See
# docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md §4 "Layer B"
# and .superpowers/sdd/2026-08-09-unified-make-verbs/task-5-brief.md.
#
#   ./deploy/scripts/tests/verb-live-test.sh     (from any cwd; needs a
#                                                  running compose stack)
#
# Sequence: deploy -> seed -> status -> rebuild, each run for real (no -n)
# against ENV=compose, asserting exit 0, plus an HTTP check before and after
# that the stack still serves through the gateway.
#
# DELIBERATELY EXCLUDED: `teardown ENV=compose`. It stops the stack that
# later tasks and other work in this repo depend on. Its dispatch mapping
# (teardown -> down) is proven offline by verb-equivalence-test.sh Part 1
# instead — this suite only covers what is safe to run for real without
# taking anything down. See deploy/README.md's Verification status section.
#
# rebuild ENV=compose dispatches to svc-restart, which defaults to
# restarting EVERY service (svc=all) if no svc= is given -- stopping and
# cold-starting all nine JVM services plus the frontend, several minutes of
# risk (Maven cold start, Atomikos pool warmup) for no extra proof that the
# *verb* works. This suite passes svc=mock-paypal-service instead: the
# lightest service in the registry, restarted the same way svc-restart
# restarts anything, and independently checkable afterwards via its own
# actuator endpoint. This exercises the same code path (stop_one + start_one
# + wait_for_port) that svc=all would, just for one service instead of ten.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../lib/colors.sh
. "$ROOT/deploy/scripts/lib/colors.sh"

cd "$ROOT" || exit 1

FAILED=0

# step <description> <command...> — runs a verb for real, asserts exit 0.
# Aborts the suite on the first failure: each step in the sequence assumes
# the stack is in the state the previous step left it in, so continuing past
# a failed step would just produce confusing downstream noise.
step() {
    local desc="$1"; shift
    log_info "==> $desc"
    if "$@"; then
        log_ok "$desc (exit 0)"
    else
        local rc=$?
        log_err "$desc FAILED (exit $rc)"
        FAILED=1
        summarize
        exit 1
    fi
}

# check_http <label> <url> [want_code=200] — does not abort; both the
# before- and after- checks are recorded so a pre-existing outage is never
# misreported as something this suite caused.
check_http() {
    local label="$1" url="$2" want="${3:-200}"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$want" ]; then
        log_ok "$label serves ($url -> $code)"
    else
        log_err "$label NOT serving ($url -> $code, wanted $want)"
        FAILED=1
    fi
}

summarize() {
    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}    all live-run steps exited 0, stack serves"
    else
        echo -e "${RED}FAIL${NC}    see above for which step or check failed"
    fi
}

log_info "Layer B -- live compose verb run: deploy -> seed -> status -> rebuild"

check_http "gateway -> product-service (before)" \
    "http://localhost:6868/product-service/v1/products?page=1&size=1" 200

step "make deploy ENV=compose" \
    make deploy ENV=compose

step "make seed ENV=compose" \
    make seed ENV=compose

step "make status ENV=compose" \
    make status ENV=compose

step "make rebuild ENV=compose svc=mock-paypal-service" \
    make rebuild ENV=compose svc=mock-paypal-service

check_http "gateway -> product-service (after)" \
    "http://localhost:6868/product-service/v1/products?page=1&size=1" 200
check_http "mock-paypal-service actuator health (after rebuild)" \
    "http://localhost:18585/actuator/health" 200

summarize
[ "$FAILED" -eq 0 ]
