# Project Memory Index — microservice-ecommerce

*One line per memory. Auto-loaded at session start. Keep it compact and grouped.*

## Decisions (decision + rationale, durable)
- [0001 — in-repo memory alongside untouched CLAUDE.md](decisions/0001-in-repo-memory-alongside-untouched-claude-md.md) — kept CLAUDE.md as SSOT, added the `.claude/memory/` lifecycle
- [0002 — root CLAUDE.md delegates to nested module files](decisions/0002-root-claude-md-delegates-to-nested-module-files.md) — root keeps non-derivable + cross-cutting only; module specifics live in `<module>/CLAUDE.md`

## Conventions (conventions + gotchas, durable)
- [two-memory-systems-coexist](conventions/two-memory-systems-coexist.md) — global personal auto-memory vs in-repo team-shared `.claude/memory/`; which to use when
- [nested-claude-md-loads-only-in-scope](conventions/nested-claude-md-loads-only-in-scope.md) — nested files load only under their directory, so a cross-cutting rule stays in root even when a nested file repeats it
- [a11y-guards-jsdom-pin-is-insurance](conventions/a11y-guards-jsdom-pin-is-insurance.md) — a11y-step guards pin jsdom as defense-in-depth, NOT because happy-dom breaks axe (that premise was false)
- [migrating-styled-buttons-to-biconbutton](conventions/migrating-styled-buttons-to-biconbutton.md) — styled raw button → BIconButton keeps its look via a retained page class (parent scoped CSS wins the specificity tie)
- [eks-gp3-storageclass-must-precede-pvcs](conventions/eks-gp3-storageclass-must-precede-pvcs.md) — fresh EKS defaults to gp2; gp3 SC must be applied before any PVC or the aws-all Step-3 infra bring-up stalls
- [rds-replica-inherits-source-parameter-groups](conventions/rds-replica-inherits-source-parameter-groups.md) — terraform-aws-modules/rds replica needs create_db_*_group=false or apply fails on missing engine metadata

## Current
- [HANDOFF](HANDOFF.md) — latest WIP state (overwritten each session)
- [sessions/](sessions/) — progress log per day
