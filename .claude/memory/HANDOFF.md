# HANDOFF — microservice-ecommerce — 2026-07-04

> Ephemeral WIP state. Overwritten by `/save-memory` each session. The next session reads this
> first — write it so anyone grasps "where we are, what's next" in 10 seconds.

## Current goal
Harness memory pillar set up. No feature work in progress.

## Done (settled, do not redo)
- `.claude/memory/` lifecycle installed (store + SessionStart/Stop hooks + `/save-memory` skill).
- `CLAUDE.md` deliberately left untouched — see [[0001-in-repo-memory-alongside-untouched-claude-md]].
- Verified: `settings.json` valid JSON; SessionStart load hook renders; files git-tracked; Stop hook fires.

## In progress / Next steps
- Uncommitted: the whole `.claude/` memory setup + `.DS_Store` + `.superpowers/` from before.
- Optional: `git add .claude/ && git commit` to share the memory system with the team (user was asked, deferred).

## Settled decisions + rationale
- [[0001-in-repo-memory-alongside-untouched-claude-md]] — CLAUDE.md stays SSOT; memory lifecycle is additive.

## Context to Load (paths only, do NOT paste contents)
- `.claude/memory/README.md` — how this memory system works
- `.claude/memory/conventions/two-memory-systems-coexist.md` — global vs in-repo memory

## Blocked / Needs user input
- Whether to commit `.claude/` now — pending user decision.
