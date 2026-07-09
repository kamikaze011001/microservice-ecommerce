# `/loop /a11y-step` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third self-paced `/loop` runner that drains the app-level accessibility backlog — each route page (+ `AppNav`) gets a passing axe guard, real violations fixed in the `.vue`, ending at one human-merged PR.

**Architecture:** Mirrors the two existing enhance-loops (`migrate-sweep`, `coverage-step`). Durable state lives in git + the test tree; each wake-up runs a deterministic detector (`next-a11y-target.mjs`), hardens exactly one target, commits, then stops or lets `/loop` schedule the next wake-up. The guard is a **separate** `<Base>.a11y.spec.ts` file carrying a `// @vitest-environment jsdom` docblock — vitest-axe cannot run under the repo's global happy-dom, and the separate file means the ~13 existing happy-dom specs are never touched. The queue is "does this target have an a11y spec file yet?" — a plain file-existence check, no numeric baseline.

**Tech Stack:** Vue 3 + Vite + TypeScript, Vitest 2 + @testing-library/vue, `vitest-axe` + `axe-core` under a per-file `jsdom` environment, Node ESM detector scripts, pnpm.

## Global Constraints

> **Correction (2026-07-09, post-implementation).** This plan repeatedly states that axe
> "cannot run under happy-dom" / "silently returns zero violations" (e.g. the constraint below,
> Task 1's smoke comment, the SKILL body). That premise is **false for the pinned happy-dom
> v15.7.4**: verified empirically, axe runs 12 rules and detects a bare-input violation under
> happy-dom just as under jsdom (the `isConnected` bug that motivated it is long fixed). The
> jsdom pin per a11y spec is retained as **defense-in-depth** (deterministic axe env + insurance
> against a happy-dom downgrade), **not** because happy-dom is broken. Read every "cannot run
> under happy-dom" line below in that light; the shipped SKILL and design spec carry the
> corrected wording. The smoke tripwire proves axe executes in the chosen env — it does **not**,
> on its own, catch a forgotten docblock.

- **Detector output contract:** prints a page path relative to `src/` (e.g. `pages/LoginPage.vue`) or the literal `DONE`. Copied verbatim from `next-coverage-target.mjs`'s `console.log(next ?? 'DONE')`.
- **Guard = file existence.** A target is "done" when a sibling `<Base>.a11y.spec.ts` exists. No content grep, no sentinel comment.
- **Every a11y spec's first line is `// @vitest-environment jsdom`.** Non-negotiable — omitting it runs axe under happy-dom, which silently returns zero violations (false pass).
- **New devDependencies, exact specifiers:** `vitest-axe@pre`, `axe-core@^4.10`, `jsdom`.
- **Page-only blast radius.** The loop edits only the target `<page>.vue` and its a11y spec. A violation whose only fix is in a shared `B*` primitive → Gate 2 Blocked (draft PR + `needs-human`), never edit the primitive.
- **Branch:** `a11y/harden-pages` (off `main`). **Hard cap:** 8 commits. **Invocation:** `/loop /a11y-step`.
- **Never auto-merge.** Output is always a PR a human merges. `git push` is user-run (guard hook) — the SKILL documents the push+PR commands but a human executes the push.
- **Commit trailer** on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Never touch** `tokens.css`, `check-consistency.sh`, `.storybook/*`, `frontend.yml`, or the other two loops.
- All work happens under `frontend/`. `pnpm test` = `vitest run`; `pnpm typecheck` = `vue-tsc --noEmit -p tsconfig.app.json` (already includes `tests/**/*.ts`).

---

### Task 1: Accessibility toolchain (vitest-axe under jsdom)

Install the axe stack, register the matcher globally, add the TS augmentation, and prove axe genuinely runs under Vitest 2 + jsdom with a smoke test that asserts **both** a clean pass and a real violation (guards against the happy-dom silent-pass trap).

**Files:**
- Modify: `frontend/package.json` (devDependencies — via pnpm)
- Modify: `frontend/tests/unit/setup.ts`
- Create: `frontend/tests/unit/vitest-axe.d.ts`
- Test: `frontend/tests/unit/a11y-toolchain.smoke.spec.ts`

**Interfaces:**
- Produces: a working `import { axe } from 'vitest-axe'` + `expect(...).toHaveNoViolations()` matcher, usable by any spec whose first line is `// @vitest-environment jsdom`. Tasks 3 relies on this.

- [ ] **Step 1: Install the three devDependencies**

Run (from `frontend/`):
```bash
pnpm add -D vitest-axe@pre axe-core@^4.10 jsdom
```
Expected: `package.json` devDependencies gain `vitest-axe` (`1.0.0-pre.5` line), `axe-core` (`^4.10`), and `jsdom`; lockfile updates; install succeeds on Vitest 2.x (vitest-axe's peer is `vitest >=1`).

- [ ] **Step 2: Register the matcher globally in `setup.ts`**

Edit `frontend/tests/unit/setup.ts` — add the vitest-axe matcher registration below the existing jest-dom import, keeping the happy-dom pointer stubs untouched:
```ts
import '@testing-library/vue';
import '@testing-library/jest-dom/vitest';
import * as axeMatchers from 'vitest-axe/matchers';
import { expect } from 'vitest';

expect.extend(axeMatchers);

// happy-dom pointer-capture stubs for reka-ui
Element.prototype.hasPointerCapture = Element.prototype.hasPointerCapture ?? (() => false);
Element.prototype.setPointerCapture = Element.prototype.setPointerCapture ?? (() => {});
Element.prototype.releasePointerCapture = Element.prototype.releasePointerCapture ?? (() => {});
```
(Registering the matcher globally is harmless for happy-dom specs — it is only *invoked* inside jsdom-overridden a11y specs.)

- [ ] **Step 3: Add the TypeScript module augmentation**

Create `frontend/tests/unit/vitest-axe.d.ts`:
```ts
import type { AxeMatchers } from 'vitest-axe/matchers';

declare module 'vitest' {
  interface Assertion extends AxeMatchers {}
  interface AsymmetricMatchersContaining extends AxeMatchers {}
}
```
(`tsconfig.app.json` already includes `tests/**/*.ts`, so this is picked up by `pnpm typecheck`.)

- [ ] **Step 4: Write the failing smoke test**

Create `frontend/tests/unit/a11y-toolchain.smoke.spec.ts`:
```ts
// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { axe } from 'vitest-axe';

describe('vitest-axe toolchain (jsdom)', () => {
  it('reports NO violations for accessible markup', async () => {
    const el = document.createElement('div');
    el.innerHTML = '<button type="button">Save</button>';
    document.body.appendChild(el);
    const results = await axe(el);
    expect(results).toHaveNoViolations();
  });

  it('reports a violation for an input with no accessible name', async () => {
    const el = document.createElement('div');
    el.innerHTML = '<input type="text" />';
    document.body.appendChild(el);
    const results = await axe(el);
    // Proves axe's structural rules actually run under jsdom (they do NOT under happy-dom).
    expect(results.violations.length).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 5: Run the smoke test — expect it to PASS once deps are installed**

Run: `pnpm test -- a11y-toolchain.smoke`
Expected: 2/2 pass. The second test proving `violations.length > 0` is the critical signal — if it comes back `0`, the `// @vitest-environment jsdom` docblock is missing or axe is running under happy-dom. Fix the docblock, do not weaken the assertion.

- [ ] **Step 6: Verify the whole suite + types still green**

Run: `pnpm test && pnpm typecheck`
Expected: all existing specs pass (happy-dom untouched), the new smoke spec passes, `vue-tsc` clean (the `.d.ts` makes `toHaveNoViolations` typecheck).

- [ ] **Step 7: Commit**

```bash
git add frontend/package.json frontend/pnpm-lock.yaml frontend/tests/unit/setup.ts \
  frontend/tests/unit/vitest-axe.d.ts frontend/tests/unit/a11y-toolchain.smoke.spec.ts
git commit -m "$(cat <<'EOF'
test(frontend): add vitest-axe toolchain under jsdom

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Deterministic target detector

Add `next-a11y-target.mjs` (mirrors `next-coverage-target.mjs`) with a pure, unit-tested `pickNextA11y`. The CLI enumerates page `.vue` files that have a mount spec, plus `AppNav`, and prints the next one lacking an `<Base>.a11y.spec.ts`.

**Files:**
- Create: `frontend/scripts/next-a11y-target.mjs`
- Test: `frontend/tests/unit/scripts/next-a11y-target.spec.ts`
- Reuse (no change): `frontend/scripts/lib/walk.mjs`

**Interfaces:**
- Produces: `export function pickNextA11y(sources, guardedBasenames, priority)` → returns the highest-priority ungarded source path (string) or `null`. CLI prints that path or `DONE`. Task 4's SKILL invokes `node scripts/next-a11y-target.mjs`.
- Consumes: `walk(dir, exts)` from `scripts/lib/walk.mjs` (returns absolute paths recursively).

- [ ] **Step 1: Write the failing unit test**

Create `frontend/tests/unit/scripts/next-a11y-target.spec.ts`:
```ts
import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextA11y } from '../../../scripts/next-a11y-target.mjs';

const priority = ['LoginPage', 'RegisterPage', 'AppNav'];

describe('pickNextA11y', () => {
  it('returns the highest-priority unguarded target', () => {
    const sources = ['pages/RegisterPage.vue', 'pages/LoginPage.vue'];
    expect(pickNextA11y(sources, new Set(), priority)).toBe('pages/LoginPage.vue');
  });

  it('skips targets that already have an a11y guard', () => {
    const sources = ['pages/LoginPage.vue', 'pages/RegisterPage.vue'];
    expect(pickNextA11y(sources, new Set(['LoginPage']), priority)).toBe('pages/RegisterPage.vue');
  });

  it('orders non-priority targets after priority ones, alphabetically by path', () => {
    const sources = ['pages/CartPage.vue', 'pages/ActivatePage.vue', 'pages/LoginPage.vue'];
    expect(pickNextA11y(sources, new Set(), priority)).toBe('pages/LoginPage.vue');
    expect(pickNextA11y(sources, new Set(['LoginPage']), priority)).toBe('pages/ActivatePage.vue');
  });

  it('returns null when every target is guarded (stop condition)', () => {
    const sources = ['pages/LoginPage.vue', 'components/layout/AppNav.vue'];
    expect(pickNextA11y(sources, new Set(['LoginPage', 'AppNav']), priority)).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pnpm test -- next-a11y-target`
Expected: FAIL — `Cannot find module '../../../scripts/next-a11y-target.mjs'`.

- [ ] **Step 3: Write the detector**

Create `frontend/scripts/next-a11y-target.mjs`:
```js
// NOTE: unlike next-coverage-target.mjs, this detector does not use existsSync
// (it walks fixed dirs directly), so do not import it — an unused import fails
// `pnpm lint` in CI, and the pre-commit hook's lint-staged glob (*.{ts,vue})
// does not cover .mjs, so it will slip past the hook.
import { basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const stripVue = (p) => basename(p).replace(/\.vue$/, '');

// Highest-interaction surfaces first; the rest fall back to alphabetical by path.
const PRIORITY = [
  'LoginPage',
  'RegisterPage',
  'CheckoutPage',
  'CartPage',
  'ProductDetailPage',
  'ProfilePage',
  'OrdersPage',
  'OrderDetailPage',
  'PaymentResultPage',
  'ActivatePage',
  'ForgotPasswordPage',
  'HomePage',
  'AppNav',
];

export function pickNextA11y(sources, guardedBasenames, priority) {
  const rank = (p) => {
    const i = priority.indexOf(stripVue(p));
    return i === -1 ? priority.length : i;
  };
  const unguarded = sources
    .filter((p) => !guardedBasenames.has(stripVue(p)))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return unguarded[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const testsRoot = fileURLToPath(new URL('../tests/unit', import.meta.url));

  // Page targets = pages that have a mount spec (basename match), excluding a11y specs.
  const pageSpecBasenames = new Set(
    walk(`${testsRoot}/pages`, ['.spec.ts'])
      .filter((p) => !p.endsWith('.a11y.spec.ts'))
      .map((p) => basename(p).replace(/\.spec\.ts$/, '')),
  );
  const pageSources = walk(`${srcRoot}/pages`, ['.vue'])
    .map((p) => relative(srcRoot, p))
    .filter((p) => pageSpecBasenames.has(stripVue(p)));

  // AppNav is a fixed extra target (its mount spec lives under components/).
  const targets = [...pageSources, 'components/layout/AppNav.vue'];

  // Guarded = any *.a11y.spec.ts anywhere under tests/unit, keyed by basename.
  const guarded = new Set(
    walk(testsRoot, ['.a11y.spec.ts']).map((p) => basename(p).replace(/\.a11y\.spec\.ts$/, '')),
  );

  const next = pickNextA11y(targets, guarded, PRIORITY);
  console.log(next ?? 'DONE');
}
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `pnpm test -- next-a11y-target`
Expected: 4/4 pass.

- [ ] **Step 5: Smoke-run the CLI against the real repo**

Run (from `frontend/`): `node scripts/next-a11y-target.mjs`
Expected: prints `pages/LoginPage.vue` (top priority, no a11y spec exists yet). This confirms the target set + priority resolve against real files.

- [ ] **Step 6: Verify types**

Run: `pnpm typecheck`
Expected: clean (the spec uses `// @ts-expect-error` for the untyped `.mjs` import, matching `next-coverage-target.spec.ts`).

- [ ] **Step 7: Commit**

```bash
git add frontend/scripts/next-a11y-target.mjs frontend/tests/unit/scripts/next-a11y-target.spec.ts
git commit -m "$(cat <<'EOF'
feat(frontend): a11y-step target detector

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Dogfood one page (LoginPage) — the reference a11y spec

Prove the toolchain + detector recipe end-to-end on the top-priority target. Create `LoginPage.a11y.spec.ts` (jsdom, mount + axe + rubric), fix any real violation **page-only**, and land it green. This file doubles as the canonical example the SKILL points to, and it flips the detector's next target to `pages/RegisterPage.vue`.

**Files:**
- Create: `frontend/tests/unit/pages/LoginPage.a11y.spec.ts`
- Possibly modify (only if axe reports a real violation): `frontend/src/pages/LoginPage.vue` (page-only)

**Interfaces:**
- Consumes: `axe` + `toHaveNoViolations` from Task 1; the mount scaffold pattern from the sibling `LoginPage.spec.ts`.
- Produces: the first guarded target — after this, `node scripts/next-a11y-target.mjs` prints `pages/RegisterPage.vue`.

- [ ] **Step 1: Write the a11y spec (guard + rubric)**

Create `frontend/tests/unit/pages/LoginPage.a11y.spec.ts`:
```ts
// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import LoginPage from '@/pages/LoginPage.vue';

vi.mock('@/api/queries/auth', () => ({
  useLoginMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useRegisterMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  router.push('/login');
  await router.isReady();
});

function mount() {
  return render(LoginPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('LoginPage — accessibility', () => {
  it('has no axe violations in its default state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/log in/i);
  });

  it('labels every field and names the submit control (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    expect(screen.getByLabelText(/username/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /log in/i })).toBeInTheDocument();
    // Keyboard reachability: first Tab lands on the first field, no trap before it.
    await user.tab();
    expect(screen.getByLabelText(/username/i)).toHaveFocus();
  });
});
```

- [ ] **Step 2: Run it**

Run: `pnpm test -- LoginPage.a11y`
Expected outcomes:
- **Green** → LoginPage was already accessible (it uses `<main>`, `<h1>`, labeled `BInput`s, a named submit button); the guard simply locks that in. Proceed to Step 4.
- **axe violation** → read the reported rule/node, fix it **only in `src/pages/LoginPage.vue`** (add a missing label/`aria-label`, correct a role, dedupe an id, wrap stray content in the single `<main>`). Do not change behavior; do not edit any `B*` primitive. If the only fix lives in a primitive, this is Gate 2 territory — stop and flag it (in the real loop it becomes a draft PR; here, surface it to the human).
- **`toHaveFocus` fails** → the page's first tabbable control differs from the username field; adjust the assertion to the actual first interactive control (verify by reading `LoginPage.vue`), then re-run.

- [ ] **Step 3: (If the page was edited) re-run to confirm green**

Run: `pnpm test -- LoginPage.a11y`
Expected: 3/3 pass.

- [ ] **Step 4: Confirm the detector advanced + full suite green**

Run:
```bash
node scripts/next-a11y-target.mjs   # expect: pages/RegisterPage.vue
pnpm test && pnpm typecheck          # expect: all green
```

- [ ] **Step 5: Commit**

```bash
git add frontend/tests/unit/pages/LoginPage.a11y.spec.ts frontend/src/pages/LoginPage.vue
git commit -m "$(cat <<'EOF'
a11y(frontend): harden pages/LoginPage.vue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```
(If `LoginPage.vue` was not modified, drop it from the `git add`.)

---

### Task 4: Package the loop (SKILL + docs)

Author the `a11y-step` skill so `/loop /a11y-step` is invokable, and wire the docs so the loop is discoverable alongside the other two. The SKILL encodes the four-gate contract, the jsdom a11y-spec recipe, and the page-only blast-radius rule; it points at `LoginPage.a11y.spec.ts` (Task 3) as the worked example.

**Files:**
- Create: `.claude/skills/a11y-step/SKILL.md`
- Modify: `frontend/docs/enhance-loops.md`
- Modify: `frontend/CLAUDE.md` (the "Enhance loops" section)

**Interfaces:**
- Consumes: `node scripts/next-a11y-target.mjs` (Task 2), the jsdom a11y-spec shape proven in Task 3.

- [ ] **Step 1: Write the SKILL**

Create `.claude/skills/a11y-step/SKILL.md`:
````markdown
---
name: a11y-step
description: >
  Use to run ONE iteration of the accessibility-hardening sweep, then self-pace via /loop.
  Picks the next app page (or AppNav) lacking an axe guard, writes a jsdom vitest-axe spec
  under tests/unit/, fixes real violations page-only, verifies, and commits. Ends at one
  human-merged PR. Trigger phrases: "/a11y-step", "a11y sweep", "/loop /a11y-step".
---

# a11y-step — one iteration of the accessibility-hardening loop

**Announce at start:** "Running one a11y-step iteration."

Runs as `/loop /a11y-step` (no interval → self-paced). Durable state lives in git and the
test tree — a killed session resumes from there. The only in-session state is a transient
blocked-file counter (Gate 2), tracked across this run's wake-ups and reset safely on restart.
Harden EXACTLY ONE target per invocation, commit it, then stop or let /loop schedule the next wake-up.

## Why a separate jsdom spec file
`vitest-axe` cannot run under the repo's global `happy-dom` (its `Node.prototype.isConnected`
bug makes axe skip every rule → silent false pass). So each guard is a **separate** file
`tests/unit/<mirror>/<Base>.a11y.spec.ts` whose **first line** is `// @vitest-environment jsdom`.
This never touches the existing happy-dom specs. Reference example: `tests/unit/pages/LoginPage.a11y.spec.ts`.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — the detector prints `DONE`. If the branch has commits, open the PR
   (below) and STOP: do NOT schedule another wake-up. If it has none, report "every page is
   guarded" and STOP.
2. **Blocked stop** — track a blocked-file counter across this run's wake-ups; if 2 targets in a
   row cannot be brought green in-iteration (violation only fixable in a shared primitive, or
   test/typecheck stays red), open the escape-hatch draft PR (below) and STOP. The counter is
   in-run only — a restart resets it, which is safe.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 8, open the PR and STOP. This gate is
   wired as step 2 of the iteration below so it fires before any new work.
4. **User interrupt** — the user may stop /loop anytime; the last commit is safe; re-running
   resumes from git state.

## The iteration
1. `cd frontend`. Ensure on branch `a11y/harden-pages` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 8, open the Gate 1 PR and STOP
   before doing any work.
3. Run `node scripts/next-a11y-target.mjs`.
   - `DONE` → Gate 1.
   - Otherwise the output is `FILE` (a page path relative to `src`, e.g. `pages/CheckoutPage.vue`,
     or `components/layout/AppNav.vue`).
4. Create `tests/unit/<mirror>/<Base>.a11y.spec.ts` (pages → `tests/unit/pages/`, AppNav →
   `tests/unit/components/`). **First line must be** `// @vitest-environment jsdom`. Copy the
   sibling mount spec's provider setup + query-hook `vi.mock`s (Pinia via
   `setActivePinia(createPinia())`, router, `VueQueryPlugin`), mount the page's primary loaded
   state, and assert `expect(await axe(container)).toHaveNoViolations()` (axe is async).
5. Run it → **fix real violations in `src/<FILE>` only** (missing label/`aria-label`, wrong
   role/ARIA, no `<main>`, heading order, duplicate ids). **Page-only blast radius**: if the
   only fix is in a shared `B*` primitive, do NOT edit the primitive — fix at the page call-site
   if possible, else count this as a blocked file (Gate 2). Do NOT change behavior.
6. **Rubric pass** — add the testable judgment assertions to the same a11y spec: keyboard
   reachability (`await user.tab()` lands on the expected control, no trap), accessible names
   (`getByRole('button'|'link'|'textbox', { name })`), single `<main>` / heading order. Note any
   non-testable observation (screen-reader flow, visible focus) for the PR body.
7. Verify — both must pass: `pnpm test` && `pnpm typecheck`.
   - Green → `git add -A && git commit -m "a11y(frontend): harden <FILE>"` (with the Co-Authored-By trailer).
   - Un-fixable within blast radius → `git checkout -- .` and count this as a blocked file (Gate 2 on the 2nd).
8. Report: "hardened `<FILE>`; run the detector to see remaining." Let /loop schedule the next wake-up.

## Gate 1 PR
```bash
git push -u origin HEAD
gh pr create --base main --title "a11y(frontend): harden app pages" \
  --body "Adds passing axe guards + rubric checks to app pages/AppNav: <list>. Real violations fixed page-only. Per-file rubric notes: <notes>. pnpm test green."
```

## Gate 2 escape hatch
```bash
git add -A && git commit --allow-empty -m "wip(frontend): a11y-step blocked — needs human"
git push -u origin HEAD
gh pr create --draft --base main --title "wip: a11y-step needs human" \
  --body "<blocked files + the specific violation(s) needing a primitive-level or human decision>"
gh pr edit --add-label needs-human
```

## Hard rules
- ONE target per invocation. Never batch.
- Every a11y spec's first line is `// @vitest-environment jsdom`. No exceptions.
- Page-only blast radius — never edit a `B*` primitive inside this loop. Shared-primitive a11y
  fixes are a separate, human-reviewed design PR (Gate 2 surfaces them).
- Never touch `tokens.css`, `check-consistency.sh`, `.storybook/*`, CI, or component behavior.
- Never auto-merge. Output is always a PR a human merges.
````

- [ ] **Step 2: Add the loop to `enhance-loops.md`**

Edit `frontend/docs/enhance-loops.md` — change the intro count and append a third loop section. Replace the opening line:
```markdown
Two local, self-paced `/loop` runners. Each does ONE unit of work per wake-up, commits it,
```
with:
```markdown
Three local, self-paced `/loop` runners. Each does ONE unit of work per wake-up, commits it,
```
Then insert this section after the `/loop /coverage-step` section (before "## Four-gate stop contract (both loops)"), and rename that heading to "(all three loops)":
```markdown
## `/loop /a11y-step`

Adds a passing axe guard (a jsdom `vitest-axe` spec) + a keyboard/landmark rubric to each app
page and `AppNav`, fixing real violations page-only. Opens a PR on `a11y/harden-pages` when the
detector reports `DONE`.

- Next target: `cd frontend && node scripts/next-a11y-target.mjs`
- Skill: `.claude/skills/a11y-step/SKILL.md`
- Guards are separate `tests/unit/**/<Base>.a11y.spec.ts` files (jsdom docblock) — vitest-axe
  cannot run under the global happy-dom.
```
And update the hard-cap line to include the third cap:
```markdown
3. **Hard cap** — commits reach the cap (migrate: 10, coverage: 4, a11y: 8) → open the PR, stop.
```
And add the a11y design-spec pointer beside the existing one:
```markdown
Design specs: `docs/superpowers/specs/2026-07-08-frontend-enhance-loops-design.md`,
`docs/superpowers/specs/2026-07-09-frontend-a11y-step-loop-design.md`.
```

- [ ] **Step 3: Update `frontend/CLAUDE.md`**

Edit the "## Enhance loops" section of `frontend/CLAUDE.md`. Replace:
```markdown
Two self-paced `/loop` runners live in `.claude/skills/{migrate-sweep,coverage-step}/`. See
`frontend/docs/enhance-loops.md` for `/loop /migrate-sweep` (primitive migration) and
`/loop /coverage-step` (composable/store test coverage).
```
with:
```markdown
Three self-paced `/loop` runners live in `.claude/skills/{migrate-sweep,coverage-step,a11y-step}/`.
See `frontend/docs/enhance-loops.md` for `/loop /migrate-sweep` (primitive migration),
`/loop /coverage-step` (composable/store test coverage), and `/loop /a11y-step` (per-page axe
guards + keyboard/landmark rubric; guards are separate jsdom `vitest-axe` specs).
```

- [ ] **Step 4: Verify docs don't break anything**

Run: `pnpm test && pnpm typecheck`
Expected: still green (docs + SKILL are non-code; no regression). This is the guard that Task 4 didn't accidentally touch a spec.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/a11y-step/SKILL.md frontend/docs/enhance-loops.md frontend/CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(frontend): package /loop /a11y-step enhance loop

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (against `2026-07-09-frontend-a11y-step-loop-design.md`):
- Hybrid shape (axe drain + rubric) → Task 3 (rubric assertions) + SKILL step 6. ✅
- Queue = "spec has an axe guard?" via file existence → Task 2 detector. ✅
- Separate jsdom `.a11y.spec.ts` (happy-dom incompatibility) → Task 1 + Task 3 + SKILL "Why a separate jsdom spec file". ✅
- Scope = pages with a mount spec + AppNav → Task 2 CLI target set. ✅
- Page-only blast radius → Global Constraints + Task 3 Step 2 + SKILL hard rules. ✅
- Four gates, cap 8, branch `a11y/harden-pages`, invocation `/loop /a11y-step` → SKILL + Global Constraints. ✅
- New deps `vitest-axe@pre` + `axe-core@^4.10` + `jsdom` → Task 1. ✅
- Never touch tokens/consistency/storybook/CI/other loops → Global Constraints. ✅
- Packaging (SKILL + enhance-loops.md + CLAUDE.md) → Task 4. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step carries complete content. Task 3 Step 2 branches on axe's runtime result, but each branch names the concrete action (this is genuine per-page work the loop exists to do, not a plan placeholder).

**Type consistency:** `pickNextA11y(sources, guardedBasenames, priority)` signature is identical across Task 2's test, implementation, and the `stripVue` helper. Detector output contract (`path` or `DONE`) matches the SKILL's step-3 consumption. `.a11y.spec.ts` naming is consistent across the detector's guard-detection regex, Task 3's filename, and the SKILL recipe.
