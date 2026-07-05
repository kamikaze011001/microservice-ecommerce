#!/usr/bin/env bash
# Enumerate the design-system SSOT from source — no Storybook build needed.
set -euo pipefail
root="$(git rev-parse --show-toplevel)/frontend"

echo "== Stories =="
grep -rh "title:" "$root/src" --include=*.stories.ts | sed 's/.*title:[[:space:]]*//; s/['\''",]//g' | grep '/' | sort

echo; echo "== Foundations & Guides (MDX) =="
grep -rhoE 'title="[^"]+"' "$root/src/design-system" 2>/dev/null | sed 's/title=//; s/"//g' | sort

echo; echo "== Tokens =="
grep -oE '^\s*--[a-z0-9-]+:' "$root/src/styles/tokens.css" | tr -d ' :' | sort -u
