# Project Memory Index — microservice-ecommerce

*One line per memory. Auto-loaded at session start. Keep it compact and grouped.*

## Decisions (decision + rationale, durable)
- [0001 — in-repo memory alongside untouched CLAUDE.md](decisions/0001-in-repo-memory-alongside-untouched-claude-md.md) — kept CLAUDE.md as SSOT, added the `.claude/memory/` lifecycle

## Conventions (conventions + gotchas, durable)
- [two-memory-systems-coexist](conventions/two-memory-systems-coexist.md) — global personal auto-memory vs in-repo team-shared `.claude/memory/`; which to use when
- [a11y-guards-jsdom-pin-is-insurance](conventions/a11y-guards-jsdom-pin-is-insurance.md) — a11y-step guards pin jsdom as defense-in-depth, NOT because happy-dom breaks axe (that premise was false)
- [migrating-styled-buttons-to-biconbutton](conventions/migrating-styled-buttons-to-biconbutton.md) — styled raw button → BIconButton keeps its look via a retained page class (parent scoped CSS wins the specificity tie)

## Current
- [HANDOFF](HANDOFF.md) — latest WIP state (overwritten each session)
- [sessions/](sessions/) — progress log per day
