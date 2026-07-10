---
name: 0002-root-claude-md-delegates-to-nested-module-files
description: Root CLAUDE.md keeps only non-derivable, cross-cutting guidance; module specifics live in nested per-module CLAUDE.md
metadata: { type: decision, date: 2026-07-10 }
---
The root `CLAUDE.md` is trimmed to **non-derivable, cross-cutting** guidance only. Anything a
session can reconstruct from the repo (`ls`, `pom.xml`, source) is deleted outright; anything
scoped to one module lives in that module's nested `CLAUDE.md`.

Cut on 2026-07-10 (18,704 → 14,452 chars, ~4.7k → ~3.6k est tokens loaded every session):
- Derivable, deleted: Project Overview, Core Architecture / Microservices Structure, Core Modules,
  Key Technologies, `mvn` build commands, Key Events class list.
- Migrated to nested files: Image storage → `core/core-s3/CLAUDE.md`; Gateway CORS →
  `gateway/CLAUDE.md`; Mock PayPal → new `mock-paypal-service/CLAUDE.md` (+ pointer line in
  `payment-service/CLAUDE.md`, since that's where `application.paypal.base-url` is flipped).

**Why:** every line of root `CLAUDE.md` is resident in context for every session in this repo,
whether or not it's relevant. A service list that `ls` answers, and a dependency list that
`pom.xml` answers, buy nothing and crowd out the gotchas the file exists for. The nested files
already carried the module specifics near-verbatim — the root copies were pure duplication.

**How to apply:** before adding to root `CLAUDE.md`, ask "could a session reconstruct this by
reading the code?" If yes, don't. If it's about one module, put it in that module's `CLAUDE.md`.
Keep in root: gotchas, failure contracts, conventions that DIFFER from framework defaults,
safety prohibitions, and agent directives. Deliberately kept despite being duplicated in nested
files: Bean wiring, Repository layout, Response & paging shapes, User identity, Gateway routing —
each applies to *every* service, and nested files don't load out of scope. See
[[nested-claude-md-loads-only-in-scope]]. Related: [[0001-in-repo-memory-alongside-untouched-claude-md]].
