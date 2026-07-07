#!/usr/bin/env bash
# App↔Storybook consistency hard gate. Runs every fast check, aggregates failures.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> frontend/

fail=0
echo "▶ story coverage";    node scripts/check-story-coverage.mjs  || fail=1
echo "▶ hard-coded hex";    node scripts/check-tokens.mjs          || fail=1
echo "▶ primitive reuse";   node scripts/check-primitive-reuse.mjs || fail=1

if [ "$fail" -ne 0 ]; then
  echo "✗ consistency gate FAILED"
  exit 1
fi
echo "✓ consistency gate passed"
