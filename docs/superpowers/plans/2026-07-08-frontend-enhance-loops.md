# Frontend Enhance Loops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two self-paced `/loop` runners — `/loop /migrate-sweep` (drains the primitive-migration baseline) and `/loop /coverage-step` (covers untested composables/stores) — each ending at one human-merged PR.

**Architecture:** Each loop = a tiny **unit-tested detector script** in `frontend/scripts/` (deterministic "next target or `DONE`") + a **skill** in `.claude/skills/` that does exactly one unit of work per invocation and self-paces via `/loop`. This plan builds the *machinery only*. Running the loops (which migrates the 9 baseline components and writes the 2 composable specs) is a separate user action after merge — do NOT migrate components or write composable specs in this plan.

**Tech Stack:** Node ESM `.mjs` scripts (mirroring existing `scripts/check-*.mjs`), Vitest (`tests/unit/**/*.spec.ts`, happy-dom, globals), pnpm, Markdown skill files.

## Global Constraints

- Detector scripts live in `frontend/scripts/`, ESM `.mjs`, and export a pure function plus a `if (process.argv[1] === fileURLToPath(import.meta.url))` CLI block — copy the pattern from `frontend/scripts/check-primitive-reuse.mjs`.
- Detector tests live in `frontend/tests/unit/scripts/<name>.spec.ts` and import the `.mjs` with `// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest`.
- Skills live at repo-root `.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`) — mirror `.claude/skills/consistency-loop/SKILL.md`.
- Skills NEVER touch `tokens.css`, `check-consistency.sh`, or CI, and NEVER auto-merge — output is always a PR a human merges.
- All `pnpm`/`node` commands run from `frontend/` (the shell may already be there).
- Commit messages end with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

## File Structure

- Create: `frontend/scripts/next-migration-target.mjs` — prints the lowest-count baseline entry or `DONE`.
- Create: `frontend/tests/unit/scripts/next-migration-target.spec.ts` — unit tests for the above.
- Create: `.claude/skills/migrate-sweep/SKILL.md` — one migration iteration + four-gate stop contract.
- Create: `frontend/scripts/next-coverage-target.mjs` — prints the next untested composable/store or `DONE`.
- Create: `frontend/tests/unit/scripts/next-coverage-target.spec.ts` — unit tests for the above.
- Create: `.claude/skills/coverage-step/SKILL.md` — one coverage iteration + four-gate stop contract.
- Create: `frontend/docs/enhance-loops.md` — runbook for both loops.
- Modify: `frontend/CLAUDE.md` — add a one-line pointer to the runbook.

---

### Task 1: Migration detector script

**Files:**
- Create: `frontend/scripts/next-migration-target.mjs`
- Test: `frontend/tests/unit/scripts/next-migration-target.spec.ts`

**Interfaces:**
- Produces: `pickNextMigration(baseline: Record<string, number>): { file: string, count: number } | null` — the entry with the smallest count `> 0`, ties broken lexicographically by `file`; `null` when all entries are `0`.
- CLI: reads `frontend/scripts/consistency-baseline.json`, prints `next.file` or `DONE`.

- [ ] **Step 1: Write the failing test**

Create `frontend/tests/unit/scripts/next-migration-target.spec.ts`:

```ts
import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextMigration } from '../../../scripts/next-migration-target.mjs';

describe('pickNextMigration', () => {
  it('returns the entry with the lowest count > 0', () => {
    expect(pickNextMigration({ 'a.vue': 3, 'b.vue': 1, 'c.vue': 2 })).toEqual({
      file: 'b.vue',
      count: 1,
    });
  });

  it('breaks ties lexicographically by file path', () => {
    expect(pickNextMigration({ 'z.vue': 2, 'a.vue': 2 })).toEqual({ file: 'a.vue', count: 2 });
  });

  it('skips entries already at 0', () => {
    expect(pickNextMigration({ 'done.vue': 0, 'todo.vue': 5 })).toEqual({
      file: 'todo.vue',
      count: 5,
    });
  });

  it('returns null when every entry is 0 (stop condition)', () => {
    expect(pickNextMigration({ 'a.vue': 0, 'b.vue': 0 })).toBeNull();
  });

  it('returns null for an empty baseline', () => {
    expect(pickNextMigration({})).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/scripts/next-migration-target.spec.ts`
Expected: FAIL — cannot resolve `../../../scripts/next-migration-target.mjs`.

- [ ] **Step 3: Write the minimal implementation**

Create `frontend/scripts/next-migration-target.mjs`:

```js
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Pick the next migration target from a consistency baseline map.
 * @param {Record<string, number>} baseline  file -> grandfathered raw-element count
 * @returns {{ file: string, count: number } | null}  smallest count > 0 (ties: lexicographic
 *   file path), or null when all entries are 0.
 */
export function pickNextMigration(baseline) {
  let best = null;
  for (const [file, count] of Object.entries(baseline)) {
    if (count <= 0) continue;
    if (best === null || count < best.count || (count === best.count && file < best.file)) {
      best = { file, count };
    }
  }
  return best;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const baseline = JSON.parse(
    readFileSync(fileURLToPath(new URL('./consistency-baseline.json', import.meta.url)), 'utf8'),
  );
  const next = pickNextMigration(baseline);
  console.log(next ? next.file : 'DONE');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && pnpm exec vitest run tests/unit/scripts/next-migration-target.spec.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Verify the CLI against the real baseline**

Run: `cd frontend && node scripts/next-migration-target.mjs`
Expected: prints `pages/CartPage.vue` (lowest count = 1; lexicographically first among the count-1 entries).

- [ ] **Step 6: Commit**

```bash
git add frontend/scripts/next-migration-target.mjs frontend/tests/unit/scripts/next-migration-target.spec.ts
git commit -m "feat(frontend): migration-target detector for /migrate-sweep

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: migrate-sweep skill

**Files:**
- Create: `.claude/skills/migrate-sweep/SKILL.md`

**Interfaces:**
- Consumes: `frontend/scripts/next-migration-target.mjs` (Task 1) via `node scripts/next-migration-target.mjs` → prints a `src`-relative path or `DONE`.

- [ ] **Step 1: Write the skill file**

Create `.claude/skills/migrate-sweep/SKILL.md`:

```markdown
---
name: migrate-sweep
description: >
  Use to run ONE iteration of the primitive-migration sweep, then self-pace via /loop. Picks
  the lowest-count file in consistency-baseline.json, migrates its raw <button>/<input>/<select>
  to B* primitives, drives that baseline entry to 0, verifies the gate, and commits. Ends at one
  human-merged PR. Trigger phrases: "/migrate-sweep", "migration sweep", "/loop /migrate-sweep".
---

# migrate-sweep — one iteration of the primitive-migration loop

**Announce at start:** "Running one migrate-sweep iteration."

Runs as `/loop /migrate-sweep` (no interval → self-paced). Durable state lives in git and
`frontend/scripts/consistency-baseline.json` — a killed session resumes from there. The only
in-session state is a transient blocked-file counter (Gate 2), tracked across this run's
wake-ups and reset safely on restart. Do EXACTLY ONE file per invocation, commit it, then stop
or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "nothing to
   migrate" and STOP.
2. **Blocked stop** — track a blocked-file counter across this run's wake-ups; if 2 files in a
   row fail verification and cannot be fixed in-iteration, open the escape-hatch draft PR
   (below) and STOP. The counter is in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 10, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `chore/migrate-primitives-sweep` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 10, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-migration-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `FILE` (path relative to `src`).
4. Edit `src/<FILE>`: replace every raw `<button>`/`<input>`/`<select>` with the matching
   primitive (`BButton`/`BInput`/`BSelect`) from `src/components/primitives`, preserving props,
   `v-model`, `@events`, and mapping any inline hex/spacing to design tokens. Invoke `/design-kit`
   if unsure of the primitive's API. Do NOT change behavior.
5. In `scripts/consistency-baseline.json`, set `FILE`'s entry to `0`.
6. Verify — all three must pass: `pnpm check:consistency` && `pnpm typecheck` && `pnpm test`.
   - All green → `git add -A && git commit -m "chore(frontend): migrate <FILE> to primitives"`.
   - Un-fixable red → `git checkout -- .` and count this as a blocked file (Gate 2 on the 2nd).
7. Report: "migrated `<FILE>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "chore(frontend): migrate raw elements to B* primitives" \
  --body "Drains consistency-baseline.json to all-zero. Files migrated: <list>. Gate green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): migrate-sweep blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: migrate-sweep needs human" \
  --body "<blocked files + the failing gate/typecheck/test output>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE file per invocation. Never batch.
- Never touch `tokens.css`, `check-consistency.sh`, CI, or component behavior.
- Never auto-merge. Output is always a PR a human merges.
```

- [ ] **Step 2: Verify frontmatter and the consumed command resolve**

Run: `cd frontend && head -8 ../.claude/skills/migrate-sweep/SKILL.md && node scripts/next-migration-target.mjs`
Expected: frontmatter shows `name: migrate-sweep`; the detector prints `pages/CartPage.vue` — confirming the skill's step 2 command works.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/migrate-sweep/SKILL.md
git commit -m "feat: /migrate-sweep skill — one primitive-migration iteration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Coverage detector script

**Files:**
- Create: `frontend/scripts/next-coverage-target.mjs`
- Test: `frontend/tests/unit/scripts/next-coverage-target.spec.ts`

**Interfaces:**
- Produces: `pickNextCoverage(sources: string[], specBasenames: Set<string>, priority: string[]): string | null` — the first untested source path, ordered by `[priority index (absent → last), then path]`; `null` when every source has a spec. `sources` are paths excluding `*.spec.ts`; a source is "tested" when its basename-without-`.ts` is in `specBasenames`.
- CLI: walks `src/composables` + `src/stores` for `.ts` (excluding `*.spec.ts`), walks `tests/unit` for `*.spec.ts` basenames, uses `priority = ['useToast', 'usePageMeta']`, prints the next path or `DONE`.

- [ ] **Step 1: Write the failing test**

Create `frontend/tests/unit/scripts/next-coverage-target.spec.ts`:

```ts
import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextCoverage } from '../../../scripts/next-coverage-target.mjs';

const priority = ['useToast', 'usePageMeta'];

describe('pickNextCoverage', () => {
  it('returns the highest-priority untested unit', () => {
    const sources = ['composables/usePageMeta.ts', 'composables/useToast.ts'];
    expect(pickNextCoverage(sources, new Set(), priority)).toBe('composables/useToast.ts');
  });

  it('skips units that already have a spec', () => {
    const sources = ['composables/useToast.ts', 'composables/usePageMeta.ts'];
    expect(pickNextCoverage(sources, new Set(['useToast']), priority)).toBe(
      'composables/usePageMeta.ts',
    );
  });

  it('orders non-priority units after priority ones, alphabetically by path', () => {
    const sources = ['stores/zeta.ts', 'stores/alpha.ts', 'composables/useToast.ts'];
    expect(pickNextCoverage(sources, new Set(), priority)).toBe('composables/useToast.ts');
    expect(pickNextCoverage(sources, new Set(['useToast']), priority)).toBe('stores/alpha.ts');
  });

  it('returns null when every source has a spec (stop condition)', () => {
    const sources = ['composables/useToast.ts', 'stores/auth.ts'];
    expect(pickNextCoverage(sources, new Set(['useToast', 'auth']), priority)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/scripts/next-coverage-target.spec.ts`
Expected: FAIL — cannot resolve `../../../scripts/next-coverage-target.mjs`.

- [ ] **Step 3: Write the minimal implementation**

Create `frontend/scripts/next-coverage-target.mjs`:

```js
import { existsSync } from 'node:fs';
import { basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const stripTs = (p) => basename(p).replace(/\.ts$/, '');

/**
 * Pick the next untested composable/store.
 * @param {string[]} sources         source paths (excluding *.spec.ts)
 * @param {Set<string>} specBasenames basenames (no extension) that already have a spec
 * @param {string[]} priority        basenames in preferred order; others sort after, by path
 * @returns {string | null}  the next untested source path, or null when all are tested.
 */
export function pickNextCoverage(sources, specBasenames, priority) {
  const rank = (p) => {
    const i = priority.indexOf(stripTs(p));
    return i === -1 ? priority.length : i;
  };
  const untested = sources
    .filter((p) => !specBasenames.has(stripTs(p)))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return untested[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const testsRoot = fileURLToPath(new URL('../tests/unit', import.meta.url));
  const sources = ['composables', 'stores']
    .map((d) => `${srcRoot}/${d}`)
    .filter(existsSync)
    .flatMap((d) => walk(d, ['.ts']))
    .filter((p) => !p.endsWith('.spec.ts'))
    .map((p) => relative(srcRoot, p));
  const specBasenames = new Set(
    walk(testsRoot, ['.spec.ts']).map((p) => basename(p).replace(/\.spec\.ts$/, '')),
  );
  const next = pickNextCoverage(sources, specBasenames, ['useToast', 'usePageMeta']);
  console.log(next ?? 'DONE');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && pnpm exec vitest run tests/unit/scripts/next-coverage-target.spec.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Verify the CLI against the real tree**

Run: `cd frontend && node scripts/next-coverage-target.mjs`
Expected: prints `composables/useToast.ts` (highest priority, currently untested).

- [ ] **Step 6: Commit**

```bash
git add frontend/scripts/next-coverage-target.mjs frontend/tests/unit/scripts/next-coverage-target.spec.ts
git commit -m "feat(frontend): coverage-target detector for /coverage-step

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: coverage-step skill

**Files:**
- Create: `.claude/skills/coverage-step/SKILL.md`

**Interfaces:**
- Consumes: `frontend/scripts/next-coverage-target.mjs` (Task 3) via `node scripts/next-coverage-target.mjs` → prints a `src`-relative source path or `DONE`.

- [ ] **Step 1: Write the skill file**

Create `.claude/skills/coverage-step/SKILL.md`:

```markdown
---
name: coverage-step
description: >
  Use to run ONE iteration of the test-coverage sweep, then self-pace via /loop. Picks the next
  untested composable/store, writes a behavior-focused Vitest spec under tests/unit/, verifies,
  and commits. Ends at one human-merged PR. Trigger phrases: "/coverage-step", "coverage sweep",
  "/loop /coverage-step".
---

# coverage-step — one iteration of the test-coverage loop

**Announce at start:** "Running one coverage-step iteration."

Runs as `/loop /coverage-step` (no interval → self-paced). Durable state lives in git and the
test tree — a killed session resumes from there. The only in-session state is a transient
blocked-unit counter (Gate 2), tracked across this run's wake-ups and reset safely on restart.
Write EXACTLY ONE spec per invocation, commit it, then stop or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "everything is
   covered" and STOP.
2. **Blocked stop** — track a blocked-unit counter across this run's wake-ups; if 2 units in a
   row fail verification and cannot be fixed in-iteration, open the escape-hatch draft PR
   (below) and STOP. The counter is in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 4, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `test/coverage-composables-stores` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 4, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-coverage-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `UNIT` (path relative to `src`, e.g. `composables/useToast.ts`).
4. Write `tests/unit/<mirror>/<basename>.spec.ts` (mirror `UNIT`'s dir, e.g.
   `composables/useToast.ts` → `tests/unit/composables/useToast.spec.ts`). Follow the existing
   patterns: Vitest globals (`describe/it/expect`), `happy-dom`, Pinia via
   `setActivePinia(createPinia())` for store-backed units, `vi.useFakeTimers()` for timers.
   Read `UNIT` and cover its real BEHAVIOR branches, not implementation details.
5. Verify — both must pass: `pnpm test` (the new spec passes, nothing else breaks) && `pnpm typecheck`.
   - Green → `git add -A && git commit -m "test(frontend): cover <UNIT>"`.
   - Un-fixable red → `git checkout -- .` and count this as a blocked unit (Gate 2 on the 2nd).
6. Report: "covered `<UNIT>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "test(frontend): cover composables + stores" \
  --body "Adds Vitest specs for previously untested composables/stores: <list>. pnpm test green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): coverage-step blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: coverage-step needs human" \
  --body "<blocked units + the failing test/typecheck output>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE spec per invocation. Never batch.
- Test behavior, not implementation. Never edit the source unit to make a test pass.
- Never auto-merge. Output is always a PR a human merges.
```

- [ ] **Step 2: Verify frontmatter and the consumed command resolve**

Run: `cd frontend && head -8 ../.claude/skills/coverage-step/SKILL.md && node scripts/next-coverage-target.mjs`
Expected: frontmatter shows `name: coverage-step`; the detector prints `composables/useToast.ts` — confirming the skill's step 2 command works.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/coverage-step/SKILL.md
git commit -m "feat: /coverage-step skill — one test-coverage iteration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Runbook and pointer

**Files:**
- Create: `frontend/docs/enhance-loops.md`
- Modify: `frontend/CLAUDE.md` (append one pointer line)

- [ ] **Step 1: Write the runbook**

Create `frontend/docs/enhance-loops.md`:

```markdown
# Frontend enhance loops

Two local, self-paced `/loop` runners. Each does ONE unit of work per wake-up, commits it,
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

## Four-gate stop contract (both loops)
1. **Success** — detector prints `DONE` → open the PR, stop.
2. **Blocked** — 2 consecutive un-fixable failures → draft PR + `needs-human`, stop.
3. **Hard cap** — commits reach the cap (migrate: 10, coverage: 4) → open the PR, stop.
4. **User interrupt** — stop `/loop` anytime; last commit is safe; re-run to resume.

Design spec: `docs/superpowers/specs/2026-07-08-frontend-enhance-loops-design.md`.
```

- [ ] **Step 2: Add the pointer to frontend/CLAUDE.md**

Append this line to the end of `frontend/CLAUDE.md`:

```markdown

## Enhance loops
Two self-paced `/loop` runners live in `.claude/skills/{migrate-sweep,coverage-step}/`. See
`frontend/docs/enhance-loops.md` for `/loop /migrate-sweep` (primitive migration) and
`/loop /coverage-step` (composable/store test coverage).
```

- [ ] **Step 3: Commit**

```bash
git add frontend/docs/enhance-loops.md frontend/CLAUDE.md
git commit -m "docs(frontend): runbook + CLAUDE.md pointer for the enhance loops

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** Loop A machinery → Tasks 1–2; Loop B machinery → Tasks 3–4; four-gate stop contract → embedded verbatim in both SKILL.md files (Tasks 2, 4); deterministic target selection → Tasks 1, 3; packaging as skills → Tasks 2, 4; runbook → Task 5. Actual migration/spec-writing is intentionally out of scope (runtime loop work). No spec section is unimplemented.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows full content; the only `<placeholders>` are inside skill/PR-body templates where a runtime value is substituted by design.

**Type consistency:** `pickNextMigration(baseline) → {file,count}|null` used identically in Task 1 test, impl, and the migrate-sweep skill's `node` call. `pickNextCoverage(sources, specBasenames, priority) → string|null` used identically in Task 3 test, impl, and the coverage-step skill. Skill detector commands (`node scripts/next-*-target.mjs`) match the CLI blocks that print `path`-or-`DONE`.
