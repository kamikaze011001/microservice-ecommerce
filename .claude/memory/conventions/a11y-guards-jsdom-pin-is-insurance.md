---
name: a11y-guards-jsdom-pin-is-insurance
description: a11y-step guards pin `// @vitest-environment jsdom` as defense-in-depth, NOT because happy-dom breaks axe
metadata: { type: convention, date: 2026-07-09 }
---
The `/loop /a11y-step` guards (`tests/unit/**/<Base>.a11y.spec.ts`) each begin with
`// @vitest-environment jsdom`, overriding the repo's global `happy-dom` env
(`frontend/vitest.config.ts:8`). The **original design rationale was wrong** and has been
corrected across the SKILL, spec, plan, `enhance-loops.md`, and the smoke-spec comment.

**The false premise (do not repeat it):** "vitest-axe cannot run under happy-dom because
`Node.prototype.isConnected` returns false for mounted nodes (happy-dom#978) → axe skips every
rule → silent false pass." This is **FALSE for the pinned happy-dom v15.7.4**. Verified
empirically with a controlled probe: under happy-dom axe runs 12 rules (`passes=12`) and flags a
bare-input violation (`violations=1`) — **identical** to jsdom. The isConnected bug was fixed
years ago.

**Why the jsdom pin stays anyway (defense-in-depth):** jsdom is axe-core's reference DOM, so
results are deterministic and insured against a future happy-dom downgrade/regression. The
separate `.a11y.spec.ts` file also keeps a11y guards distinct from behavior specs, lets the
detector discover them by name, and never touches the ~13 existing happy-dom specs.

**Gotcha the smoke tripwire does NOT catch:** `a11y-toolchain.smoke.spec.ts` asserts axe *runs*
in the chosen env (bare input → violation). It does **not** prove the docblock is present —
removing the docblock keeps the smoke spec green (axe also runs under happy-dom). Treat it as
"axe works here," not "the jsdom pin is wired."

**Why:** the correction keeps the architecture honest — a load-bearing rationale that's factually
false rots into cargo-culting. **How to apply:** if anyone questions why guards pin jsdom, the
answer is determinism/insurance, not a happy-dom bug. Related:
[[two-memory-systems-coexist]].
