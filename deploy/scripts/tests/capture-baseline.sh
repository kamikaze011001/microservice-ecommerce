#!/usr/bin/env bash
# Captures `make -n --no-print-directory <target>` for every OLD target the
# Phase 6 unified verbs (`make <verb> ENV=<env>`) will wrap. This is the
# ORACLE: later tasks assert `make -n <verb> ENV=<env>` expands identically
# to the corresponding line here.
#
#   ./deploy/scripts/tests/capture-baseline.sh
#   FORCE=1 ./deploy/scripts/tests/capture-baseline.sh   (regenerate on purpose)
#
# This script only CAPTURES and asserts non-emptiness — it does not compare.
# Layer A equivalence (verb expansion vs. this baseline) is a later task
# (deploy/scripts/tests/verb-equivalence-test.sh).
#
# REFUSE-TO-OVERWRITE (added after a real incident — see Phase 7's
# aws-cutover task-4-report.md): every baseline file here is committed
# evidence, not a cache. A bare re-run used to regenerate-in-place
# unconditionally, so a target whose CURRENT recipe is a dispatcher
# (baseline/bootstrap.txt, baseline/status.txt — see below) got silently
# overwritten with the dispatcher's one-line expansion instead of the
# original recipe it exists to prove. This is the fourth instance in this
# project of an oracle that can be silently invalidated by regeneration
# (Phase 4's secrets goldens, Phase 5's seed goldens, and Phase 7's AWS
# oracle are the others) — and the worst of the four, because it fails
# silently by writing WRONG content, not by going missing. Now: if
# baseline/$t.txt already exists, it is left untouched and skipped (with a
# reason printed) unless FORCE=1 is set. Only a target with no existing
# baseline is captured on a bare run.
#
# bootstrap.txt / status.txt ARE FROZEN, PRE-CONVERSION EVIDENCE — DO NOT
# regenerate them even with FORCE=1. Task 3 of the original unified-verbs
# work (docs/superpowers/specs/2026-08-09-unified-make-verbs-design.md §4,
# a human-approved narrow exception) converted the `bootstrap` and `status`
# Makefile targets themselves into dispatchers, moving their real recipes
# verbatim into new targets `bootstrap-compose` / `status-compose`.
# baseline/bootstrap.txt and baseline/status.txt were captured BEFORE that
# conversion, from the targets named `bootstrap` and `status` while those
# names still held the real recipe — they are the only proof the move was
# verbatim, and capturing `bootstrap`/`status` today would capture the
# DISPATCHER's own one-line expansion instead (wrong, and not what
# verb-equivalence-test.sh's baseline/bootstrap.txt and baseline/status.txt
# are supposed to hold). So `bootstrap`/`status` are deliberately NOT in
# TARGETS below — not even under FORCE. Ongoing regeneration targets the
# targets that actually hold the recipe today: `bootstrap-compose` and
# `status-compose`, captured to their own baseline/bootstrap-compose.txt and
# baseline/status-compose.txt files. verb-equivalence-test.sh's Part 1 still
# diffs against baseline/bootstrap.txt / baseline/status.txt (the frozen
# files) — see that script's own header comment for why the filename and
# the live target name differ.
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
# baseline file each. `bootstrap` / `status` are deliberately absent — see
# the REFUSE-TO-OVERWRITE / frozen-evidence comment above. `bootstrap-compose`
# / `status-compose` capture the same recipes under the names that actually
# hold them today.
TARGETS=(
  bootstrap-compose  k8s-bootstrap   aws-all
  svc-start   k8s-apps        aws-deploy-apps
  status-compose      k8s-status
  down        k8s-down        aws-down
  k8s-build   aws-push
  svc-restart k8s-rebuild
)

mkdir -p "$OUT"

fail=0
skipped=0
for t in "${TARGETS[@]}"; do
  out="$OUT/$t.txt"
  if [ -s "$out" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "skip $t  (baseline/$t.txt already exists -- committed evidence, not a cache; set FORCE=1 to regenerate on purpose)"
    skipped=$((skipped + 1))
    continue
  fi
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

echo "capture-baseline: ${#TARGETS[@]} targets processed, $skipped skipped (already captured), $((${#TARGETS[@]} - skipped)) (re)captured, none empty"
