---
name: 0001-in-repo-memory-alongside-untouched-claude-md
description: Kept the hand-crafted CLAUDE.md as-is; added the in-repo .claude/memory/ lifecycle alongside it
metadata: { type: decision, date: 2026-07-04 }
---
Ran `/shipwithai-starter:setup-memory` on 2026-07-04. Chose **Skip** for CLAUDE.md and
**Full lifecycle** for `.claude/memory/` (store + SessionStart/Stop hooks + `/save-memory` skill).

**Why:** The existing `CLAUDE.md` (~396 lines) is far richer than the starter's generic template —
it holds the architecture map, non-obvious code conventions (colon-action paths, snake_case Feign
maps, master/slave repo split), the logging convention, and a "known scars" section. Merging or
overwriting with the template would have been a strict downgrade. The memory *lifecycle*, by
contrast, was genuinely additive: a version-controlled, team-shared catch-up store the repo
didn't have.

**How to apply:** Treat `CLAUDE.md` as the SSOT for rules that must reach subagents (subagents get
CLAUDE.md, NOT the injected memory files). Use `.claude/memory/` for cross-session catch-up and
rationale. When re-running any shipwithai-starter pillar skill, default to Skip on CLAUDE.md.
Related: [[two-memory-systems-coexist]].
