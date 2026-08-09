#!/usr/bin/env bash
# Captures `make -n --no-print-directory <target>` for every OLD target the
# Phase 6 unified verbs (`make <verb> ENV=<env>`) will wrap. This is the
# ORACLE: later tasks assert `make -n <verb> ENV=<env>` expands identically
# to the corresponding line here. Task 3 in particular converts `bootstrap`
# and `status` into dispatchers, moving their recipes into
# `bootstrap-compose` / `status-compose` — this baseline is the only proof
# that move was verbatim. See
# .superpowers/sdd/2026-08-09-unified-make-verbs/task-1-brief.md and
# docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md §4.
#
#   ./deploy/scripts/tests/capture-baseline.sh
#
# This script only CAPTURES and asserts non-emptiness — it does not compare.
# Layer A equivalence (verb expansion vs. this baseline) is a later task.
#
# Safety, verified before this script was written (see task-1-report.md):
#   - Every recipe here is a single `@<script>` line or a prerequisite
#     chain with no `$(MAKE)` reference, so under `-n` it is PRINTED, never
#     executed — this covers all aws-* targets (no AWS auth/spend/mutation).
#   - The one exception is k8s-bootstrap, whose own recipe ends in
#     `@$(MAKE) k8s-status`. GNU make always runs `$(MAKE)` lines even under
#     `-n`, but MAKEFLAGS (including `-n`) propagates to that sub-make, so
#     the sub-make also just prints k8s-status's recipe instead of running
#     kubectl for real. Confirmed empirically: the nested block contains no
#     real kubectl output, only the echoed command text.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/baseline"

# Old targets the Phase 6 verbs wrap (design spec §3's verb table), one
# baseline file each.
TARGETS=(
  bootstrap   k8s-bootstrap   aws-all
  svc-start   k8s-apps
  status      k8s-status
  down        k8s-down        aws-down
  k8s-build   aws-push
  svc-restart k8s-rebuild
)

mkdir -p "$OUT"

fail=0
for t in "${TARGETS[@]}"; do
  out="$OUT/$t.txt"
  ( cd "$ROOT" && make -n --no-print-directory "$t" ) >"$out" 2>&1
  if [ ! -s "$out" ]; then
    echo "FAIL: $t captured NOTHING — oracle is broken" >&2
    fail=1
    continue
  fi
  lines=$(wc -l < "$out" | tr -d ' ')
  echo "ok   $t  ($lines lines) -> deploy/scripts/tests/baseline/$t.txt"
done

if [ "$fail" -ne 0 ]; then
  echo "capture-baseline: one or more targets produced an empty capture — oracle is broken" >&2
  exit 1
fi

echo "capture-baseline: all ${#TARGETS[@]} targets captured, none empty"
