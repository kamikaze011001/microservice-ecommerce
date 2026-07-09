# Frontend enhance loops

Three local, self-paced `/loop` runners. Each does ONE unit of work per wake-up, commits it,
and ends at ONE PR a human merges. State lives in git — interrupt anytime and re-run to resume.

## `/loop /migrate-sweep`

Drains `frontend/scripts/consistency-baseline.json` to all-zero by migrating each file's raw
`<button>/<input>/<select>` to the `B*` primitives. Opens a PR on
`chore/migrate-primitives-sweep` when the detector reports `DONE`.

- Next target: `cd frontend && node scripts/next-migration-target.mjs`
- Skill: `.claude/skills/migrate-sweep/SKILL.md`

## `/loop /coverage-step`

Writes a Vitest spec for each untested composable/store (detector priority: `useToast`,
`usePageMeta`, then any newcomer alphabetically). Opens a PR on
`test/coverage-composables-stores` when the detector reports `DONE`.

- Next target: `cd frontend && node scripts/next-coverage-target.mjs`
- Skill: `.claude/skills/coverage-step/SKILL.md`

## `/loop /a11y-step`

Adds a passing axe guard (a jsdom `vitest-axe` spec) + a keyboard/landmark rubric to each app
page and `AppNav`, fixing real violations page-only. Opens a PR on `a11y/harden-pages` when the
detector reports `DONE`.

- Next target: `cd frontend && node scripts/next-a11y-target.mjs`
- Skill: `.claude/skills/a11y-step/SKILL.md`
- Guards are separate `tests/unit/**/<Base>.a11y.spec.ts` files whose first line pins
  `// @vitest-environment jsdom` (axe-core's reference DOM) so axe runs deterministically
  regardless of the global happy-dom env — defense-in-depth, not a hard requirement (axe runs
  fine under the pinned happy-dom v15).

## Four-gate stop contract (all three loops)

1. **Success** — detector prints `DONE` → open the PR, stop.
2. **Blocked** — 2 consecutive un-fixable failures → draft PR + `needs-human`, stop.
3. **Hard cap** — commits reach the cap (migrate: 10, coverage: 4, a11y: 8) → open the PR, stop.
4. **User interrupt** — stop `/loop` anytime; last commit is safe; re-run to resume.

Design specs: `docs/superpowers/specs/2026-07-08-frontend-enhance-loops-design.md`,
`docs/superpowers/specs/2026-07-09-frontend-a11y-step-loop-design.md`.
