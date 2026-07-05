---
name: two-memory-systems-coexist
description: Two memory stores exist by design — global personal auto-memory vs in-repo team-shared .claude/memory/
metadata: { type: convention, date: 2026-07-04 }
---
As of 2026-07-04 this project has **two** memory stores. They do not conflict; use the right one:

- **Global auto-memory** — `~/.claude/projects/-Users-sonanh-...-microservice-ecommerce/memory/`.
  Personal, cross-session, NOT in git. Holds the long-running `project_*` / `feedback_*` /
  `user_*` notes (AWS deploy progress, stress-test findings, user preferences). Indexed by its
  own `MEMORY.md`. This is the store the running assistant recalls automatically each session.
- **In-repo memory** — `.claude/memory/` (this dir). Committed to git, shared with teammates,
  for onboarding + cross-session catch-up on repo work. Written by `/save-memory`.

**Rule of thumb:** personal/private recall or preferences → global. Anything a teammate cloning
the repo should see (decisions, conventions, WIP handoff) → in-repo. A rule that must bind
subagents → neither; it goes in `CLAUDE.md`. Related: [[0001-in-repo-memory-alongside-untouched-claude-md]].
