---
name: nested-claude-md-loads-only-in-scope
description: A nested <module>/CLAUDE.md loads only when Claude works under that directory — so cross-cutting rules must stay in root even if a nested file repeats them
metadata: { type: convention, date: 2026-07-10 }
---
`<module>/CLAUDE.md` is **lazily loaded**: it enters context only when Claude touches files under
that directory. Root `CLAUDE.md` is loaded always.

The trap: seeing a rule duplicated in both root and a nested file and "deduplicating" it by
deleting the root copy. That silently removes the rule from every session that isn't working in
that module.

Test before moving a section out of root: **does this rule bind someone editing a different
module?**

- *Yes* → keep it in root, duplication and all. Examples: `Bean wiring` (manual `@Bean`
  construction, no `@Service`) is documented in `order-service/CLAUDE.md` but applies to
  product/payment/inventory too. Same for `Repository layout` (master/slave packages),
  `Response & paging shapes`, `User identity` (`X-User-Id`), and `Gateway routing — no StripPrefix`
  (which governs every new controller's paths, not just gateway edits).
- *No* → move it. Examples: `Gateway CORS` (gateway only, by its own admission — "per-service CORS
  would be redundant"), `Image storage` (already verbatim in `core/core-s3/CLAUDE.md`,
  `product-service/CLAUDE.md`, and `authorization-server/CLAUDE.md`), `Mock PayPal`.

When a moved section still has a chance of being needed out of scope, leave a **one-line pointer**
in root rather than the full text — pointers are cheap and are the one thing a session can't derive.
Related: [[0002-root-claude-md-delegates-to-nested-module-files]].
