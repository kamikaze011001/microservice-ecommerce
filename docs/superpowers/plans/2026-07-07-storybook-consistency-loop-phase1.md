# App↔Storybook Consistency Loop — Phase 1 (the hard gate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the deterministic verification substrate — `frontend/scripts/check-consistency.sh` — that turns the design-system SSOT rules into a machine pass/fail for token/rule violations, story-coverage gaps, and behavior/render drift, and wire it into CI.

**Architecture:** Three fast, pure Node ESM check functions (story coverage, hard-coded hex, primitive-reuse-with-baseline) each TDD-tested via Vitest, composed by a `check-consistency.sh` orchestrator exposed as `pnpm check:consistency`. Existing raw-element violations are grandfathered via a per-file **count baseline** (ratchet), so the gate is green on today's tree and fails only on *new* drift. A slower Storybook **test-runner** check (render + a11y) is added as a separate CI-only Layer-2 job.

**Tech Stack:** Node 20 ESM (`.mjs`), Vitest (existing), Bash, `@storybook/test-runner` + Playwright (Task 6 only), GitHub Actions.

## Global Constraints

- **Runtime:** Node **20+**, pnpm **9+**. Package is ESM (`"type": "module"`), so scripts are `.mjs` and use `import`.
- **Green on the current tree:** every check MUST exit 0 against the repo as it stands today. Hex = 0 violations, story-coverage = 0 missing, primitive-reuse = grandfathered to the baseline below.
- **Fast gate:** the three checks in `check-consistency.sh` must complete in seconds (no browser, no build) — they are the per-turn gate. The Storybook test-runner (Task 6) is explicitly NOT in this fast gate.
- **No component markup changes:** do not refactor the 13 existing raw elements. Grandfather them via the baseline.
- **Baseline (per-file raw-element counts, relative to `frontend/src/`), verified 2026-07-07:**
  `components/domain/AddressForm.vue`: 7 · `pages/CheckoutPage.vue`: 2 · `pages/CartPage.vue`: 1 · `pages/PaymentResultPage.vue`: 2 · `pages/ProductDetailPage.vue`: 1.
- **Restricted raw elements:** `button`, `input`, `select` (in `.vue` templates, outside `src/components/primitives/`).
- Test files live under `frontend/tests/unit/scripts/` (matches the existing Vitest `include: tests/unit/**/*.spec.ts`). Vitest transpiles `.mjs` imports at runtime; `pnpm typecheck` (vue-tsc over `src`) does not cover these, so no `.d.ts` is needed.

**Planning refinements of the spec (resolving its Open Questions):**
- The hex/font ban is implemented as a **Node regex scanner** (`check-tokens.mjs`), not stylelint — YAGNI: it catches 100% of hard-coded hex anywhere with zero new heavy dependency. Stylelint remains a deferred enhancement. **Font-literal** detection is deferred (high false-positive risk against Tailwind utilities); Phase 1 bans **hex only**.
- Primitive-reuse uses a **per-file count baseline** in a plain script (robust to line moves), not an eslint rule with 13 inline disables (which would touch component markup).

---

## File Structure

- `frontend/scripts/lib/walk.mjs` — shared recursive file walker (used by all three checks).
- `frontend/scripts/check-story-coverage.mjs` — Drift #2: every `*.vue` under `src/components` needs a sibling `*.stories.ts`.
- `frontend/scripts/check-tokens.mjs` — Drift #1a: no hard-coded hex in `.vue`/`.ts`.
- `frontend/scripts/check-primitive-reuse.mjs` — Drift #1b: no *new* raw `button`/`input`/`select` outside primitives.
- `frontend/scripts/consistency-baseline.json` — grandfathered per-file raw-element counts.
- `frontend/scripts/check-consistency.sh` — orchestrator; runs all three, aggregates, exit code.
- `frontend/tests/unit/scripts/*.spec.ts` — one Vitest spec per check.
- `frontend/package.json` — add `check:consistency` script (Tasks 4) and test-runner deps/script (Task 6).
- `.github/workflows/frontend.yml` — add the consistency gate step (Task 5) and test-runner job (Task 6).

---

## Task 1: Shared walker + story-coverage check

**Files:**
- Create: `frontend/scripts/lib/walk.mjs`
- Create: `frontend/scripts/check-story-coverage.mjs`
- Test: `frontend/tests/unit/scripts/check-story-coverage.spec.ts`

**Interfaces:**
- Produces: `walk(dir: string, exts: string[]) => string[]` (absolute paths); `findMissingStories(componentsDir: string, allowlist?: string[]) => string[]` (paths relative to `componentsDir`).
- Consumes: nothing.

- [ ] **Step 1: Write the shared walker**

Create `frontend/scripts/lib/walk.mjs`:

```js
import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** Recursively collect absolute file paths under `dir` whose name ends with one of `exts`. */
export function walk(dir, exts) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...walk(full, exts));
    } else if (exts.some((e) => name.endsWith(e))) {
      out.push(full);
    }
  }
  return out;
}
```

- [ ] **Step 2: Write the failing test**

Create `frontend/tests/unit/scripts/check-story-coverage.spec.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { findMissingStories } from '../../../scripts/check-story-coverage.mjs';

describe('findMissingStories', () => {
  let root: string;
  beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'cov-')); });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); });

  it('flags a component with no sibling story', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    expect(findMissingStories(root)).toEqual(['Foo.vue']);
  });

  it('passes a component that has a sibling story', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    writeFileSync(join(root, 'Foo.stories.ts'), '');
    expect(findMissingStories(root)).toEqual([]);
  });

  it('respects the allowlist', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    expect(findMissingStories(root, ['Foo.vue'])).toEqual([]);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd frontend && pnpm test -- check-story-coverage`
Expected: FAIL — cannot resolve `../../../scripts/check-story-coverage.mjs`.

- [ ] **Step 4: Write the check**

Create `frontend/scripts/check-story-coverage.mjs`:

```js
import { existsSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

/** Paths (relative to componentsDir) of *.vue with no sibling *.stories.ts, minus the allowlist. */
export function findMissingStories(componentsDir, allowlist = []) {
  const allow = new Set(allowlist);
  return walk(componentsDir, ['.vue'])
    .filter((vue) => !existsSync(vue.replace(/\.vue$/, '.stories.ts')))
    .map((vue) => relative(componentsDir, vue))
    .filter((rel) => !allow.has(rel));
}

// Components that legitimately have no story (none today; extend as needed).
const ALLOWLIST = [];

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = fileURLToPath(new URL('../src/components', import.meta.url));
  const missing = findMissingStories(dir, ALLOWLIST);
  if (missing.length) {
    console.error('✗ components missing a *.stories.ts:');
    for (const m of missing) console.error('  - ' + m);
    process.exit(1);
  }
  console.log('✓ story-coverage: every component has a story');
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd frontend && pnpm test -- check-story-coverage`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the check against the real tree**

Run: `cd frontend && node scripts/check-story-coverage.mjs`
Expected: prints `✓ story-coverage: every component has a story`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add frontend/scripts/lib/walk.mjs frontend/scripts/check-story-coverage.mjs frontend/tests/unit/scripts/check-story-coverage.spec.ts
git commit -m "feat(frontend): story-coverage consistency check"
```

---

## Task 2: Hard-coded hex check

**Files:**
- Create: `frontend/scripts/check-tokens.mjs`
- Test: `frontend/tests/unit/scripts/check-tokens.spec.ts`

**Interfaces:**
- Consumes: `walk` from `./lib/walk.mjs` (Task 1).
- Produces: `findHardcodedHex(rootDir: string, ignore?: string[]) => { file: string; line: number; text: string }[]`.

- [ ] **Step 1: Write the failing test**

Create `frontend/tests/unit/scripts/check-tokens.spec.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { findHardcodedHex } from '../../../scripts/check-tokens.mjs';

describe('findHardcodedHex', () => {
  let root: string;
  beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'tok-')); });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); });

  it('flags a hard-coded hex in a .vue', () => {
    writeFileSync(join(root, 'A.vue'), '<style>.x{color:#ff4f1c}</style>');
    expect(findHardcodedHex(root)).toHaveLength(1);
  });

  it('flags a hard-coded hex in a .ts', () => {
    writeFileSync(join(root, 'a.ts'), 'export const c = "#1c1c1c";');
    expect(findHardcodedHex(root)).toHaveLength(1);
  });

  it('ignores var(--token) usage', () => {
    writeFileSync(join(root, 'A.vue'), '<style>.x{color:var(--spot)}</style>');
    expect(findHardcodedHex(root)).toHaveLength(0);
  });

  it('honours the ignore list', () => {
    writeFileSync(join(root, 'skip.ts'), 'const c = "#abcdef";');
    expect(findHardcodedHex(root, ['skip.ts'])).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test -- check-tokens`
Expected: FAIL — cannot resolve `check-tokens.mjs`.

- [ ] **Step 3: Write the check**

Create `frontend/scripts/check-tokens.mjs`:

```js
import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

// 3/4/6/8-digit hex colours only (avoids matching 5/7-digit noise).
const HEX = /#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b/;

/** Hard-coded hex colours in .vue/.ts under rootDir. `ignore` = path substrings to skip. */
export function findHardcodedHex(rootDir, ignore = []) {
  const hits = [];
  for (const file of walk(rootDir, ['.vue', '.ts'])) {
    if (ignore.some((ig) => file.includes(ig))) continue;
    readFileSync(file, 'utf8').split('\n').forEach((text, i) => {
      if (HEX.test(text)) hits.push({ file: relative(rootDir, file), line: i + 1, text: text.trim() });
    });
  }
  return hits;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL('../src', import.meta.url));
  const hits = findHardcodedHex(root);
  if (hits.length) {
    console.error('✗ hard-coded hex colours found (use var(--token) from tokens.css):');
    for (const h of hits) console.error(`  - ${h.file}:${h.line}  ${h.text}`);
    process.exit(1);
  }
  console.log('✓ tokens: no hard-coded hex colours');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && pnpm test -- check-tokens`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the check against the real tree**

Run: `cd frontend && node scripts/check-tokens.mjs`
Expected: prints `✓ tokens: no hard-coded hex colours`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add frontend/scripts/check-tokens.mjs frontend/tests/unit/scripts/check-tokens.spec.ts
git commit -m "feat(frontend): hard-coded hex consistency check"
```

---

## Task 3: Primitive-reuse check with baseline

**Files:**
- Create: `frontend/scripts/check-primitive-reuse.mjs`
- Create: `frontend/scripts/consistency-baseline.json`
- Test: `frontend/tests/unit/scripts/check-primitive-reuse.spec.ts`

**Interfaces:**
- Consumes: `walk` from `./lib/walk.mjs` (Task 1).
- Produces: `countRawElements(rootDir: string, primitivesDir: string) => Record<string, number>`; `findNewRawElements(counts: Record<string, number>, baseline: Record<string, number>) => { file: string; count: number; allowed: number }[]`.

- [ ] **Step 1: Write the failing test**

Create `frontend/tests/unit/scripts/check-primitive-reuse.spec.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { countRawElements, findNewRawElements } from '../../../scripts/check-primitive-reuse.mjs';

describe('countRawElements', () => {
  let root: string;
  beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'prim-')); });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); });

  it('counts raw button/input/select in a .vue', () => {
    writeFileSync(join(root, 'A.vue'), '<template><button/><input><select></select></template>');
    expect(countRawElements(root, 'primitives')).toEqual({ 'A.vue': 3 });
  });

  it('skips files under the primitives dir', () => {
    mkdirSync(join(root, 'primitives'));
    writeFileSync(join(root, 'primitives', 'BButton.vue'), '<template><button/></template>');
    expect(countRawElements(root, 'primitives')).toEqual({});
  });
});

describe('findNewRawElements', () => {
  it('flags a file whose count exceeds its baseline', () => {
    expect(findNewRawElements({ 'A.vue': 3 }, { 'A.vue': 2 }))
      .toEqual([{ file: 'A.vue', count: 3, allowed: 2 }]);
  });

  it('passes a file at or below its baseline', () => {
    expect(findNewRawElements({ 'A.vue': 2 }, { 'A.vue': 2 })).toEqual([]);
  });

  it('flags a brand-new file not in the baseline', () => {
    expect(findNewRawElements({ 'New.vue': 1 }, {}))
      .toEqual([{ file: 'New.vue', count: 1, allowed: 0 }]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test -- check-primitive-reuse`
Expected: FAIL — cannot resolve `check-primitive-reuse.mjs`.

- [ ] **Step 3: Create the baseline file**

Create `frontend/scripts/consistency-baseline.json`:

```json
{
  "components/domain/AddressForm.vue": 7,
  "pages/CheckoutPage.vue": 2,
  "pages/CartPage.vue": 1,
  "pages/PaymentResultPage.vue": 2,
  "pages/ProductDetailPage.vue": 1
}
```

- [ ] **Step 4: Write the check**

Create `frontend/scripts/check-primitive-reuse.mjs`:

```js
import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const RAW = /<(?:button|input|select)[\s>/]/g;

/** Per-file count (relative to rootDir) of raw restricted elements, skipping files under primitivesDir. */
export function countRawElements(rootDir, primitivesDir) {
  const counts = {};
  for (const file of walk(rootDir, ['.vue'])) {
    if (file.includes(primitivesDir)) continue;
    const matches = readFileSync(file, 'utf8').match(RAW);
    if (matches) counts[relative(rootDir, file)] = matches.length;
  }
  return counts;
}

/** Files whose current count exceeds the grandfathered baseline (new drift). */
export function findNewRawElements(counts, baseline) {
  const violations = [];
  for (const [file, count] of Object.entries(counts)) {
    const allowed = baseline[file] ?? 0;
    if (count > allowed) violations.push({ file, count, allowed });
  }
  return violations;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const src = fileURLToPath(new URL('../src', import.meta.url));
  const baseline = JSON.parse(
    readFileSync(fileURLToPath(new URL('./consistency-baseline.json', import.meta.url)), 'utf8'),
  );
  const violations = findNewRawElements(countRawElements(src, 'components/primitives'), baseline);
  if (violations.length) {
    console.error('✗ new raw <button>/<input>/<select> outside primitives (reuse B* or update the baseline):');
    for (const v of violations) console.error(`  - ${v.file}: ${v.count} (baseline ${v.allowed})`);
    process.exit(1);
  }
  console.log('✓ primitive-reuse: no new raw elements beyond the baseline');
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd frontend && pnpm test -- check-primitive-reuse`
Expected: PASS (5 tests).

- [ ] **Step 6: Run the check against the real tree**

Run: `cd frontend && node scripts/check-primitive-reuse.mjs`
Expected: prints `✓ primitive-reuse: no new raw elements beyond the baseline`, exit 0.
(If it fails, the baseline counts drifted from the tree — re-measure with
`grep -rcE '<(button|input|select)[ >/]' src --include="*.vue" | grep -v '/primitives/' | grep -v ':0$'` and update `consistency-baseline.json`.)

- [ ] **Step 7: Commit**

```bash
git add frontend/scripts/check-primitive-reuse.mjs frontend/scripts/consistency-baseline.json frontend/tests/unit/scripts/check-primitive-reuse.spec.ts
git commit -m "feat(frontend): primitive-reuse consistency check with baseline"
```

---

## Task 4: The orchestrator + `pnpm check:consistency`

**Files:**
- Create: `frontend/scripts/check-consistency.sh`
- Modify: `frontend/package.json` (add one script line)

**Interfaces:**
- Consumes: the three `check-*.mjs` CLIs (Tasks 1–3).
- Produces: `pnpm check:consistency` → exit 0 (clean) / 1 (any check failed). This is the "hard gate" the rest of the loop reuses.

- [ ] **Step 1: Write the orchestrator**

Create `frontend/scripts/check-consistency.sh`:

```bash
#!/usr/bin/env bash
# App↔Storybook consistency hard gate. Runs every fast check, aggregates failures.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> frontend/

fail=0
echo "▶ story coverage";    node scripts/check-story-coverage.mjs  || fail=1
echo "▶ hard-coded hex";    node scripts/check-tokens.mjs          || fail=1
echo "▶ primitive reuse";   node scripts/check-primitive-reuse.mjs || fail=1

if [ "$fail" -ne 0 ]; then
  echo "✗ consistency gate FAILED"
  exit 1
fi
echo "✓ consistency gate passed"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x frontend/scripts/check-consistency.sh`

- [ ] **Step 3: Add the package.json script**

In `frontend/package.json`, add to the `"scripts"` block (after the `"test:watch"` line):

```json
    "check:consistency": "bash scripts/check-consistency.sh",
```

- [ ] **Step 4: Run the gate against the real tree**

Run: `cd frontend && pnpm check:consistency`
Expected: three `✓` lines then `✓ consistency gate passed`, exit 0.

- [ ] **Step 5: Prove it fails on planted drift**

Run:
```bash
cd frontend
printf '<template><button>x</button></template>' > src/pages/_DriftProbe.vue
pnpm check:consistency; echo "exit=$?"
rm src/pages/_DriftProbe.vue
```
Expected: fails on BOTH story-coverage (`_DriftProbe.vue` has no story) and primitive-reuse (new raw `<button>` in a file not in the baseline); prints `✗ consistency gate FAILED`, `exit=1`. After `rm`, re-running `pnpm check:consistency` is green again.

- [ ] **Step 6: Commit**

```bash
git add frontend/scripts/check-consistency.sh frontend/package.json
git commit -m "feat(frontend): check-consistency.sh hard gate + pnpm script"
```

---

## Task 5: Wire the fast gate into CI

**Files:**
- Modify: `.github/workflows/frontend.yml` (add one step after `Test`)

**Interfaces:**
- Consumes: `pnpm check:consistency` (Task 4).
- Produces: a blocking CI step so drift cannot merge to main.

- [ ] **Step 1: Add the step**

In `.github/workflows/frontend.yml`, add after the `Test` step (currently the last step, `run: pnpm test`):

```yaml
      - name: Consistency gate
        run: pnpm check:consistency
```

(The workflow already sets `defaults.run.working-directory: frontend`, so no `cd` is needed.)

- [ ] **Step 2: Verify locally the exact command CI runs**

Run: `cd frontend && pnpm check:consistency`
Expected: `✓ consistency gate passed`, exit 0 — so CI stays green on merge.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/frontend.yml
git commit -m "ci(frontend): run consistency gate on PR + push"
```

---

## Task 6: Storybook test-runner (Layer-2 behavior/render check, CI-only)

Catches Drift #4 (a story rendering a prop that no longer exists, broken `play()`, a11y regressions). This is **not** part of the fast gate — it needs a built Storybook + a browser, so it runs as its own CI job.

**Files:**
- Modify: `frontend/package.json` (devDeps + `test-storybook` script)
- Modify: `.github/workflows/frontend.yml` (new `storybook` job)

**Interfaces:**
- Consumes: existing stories (`src/**/*.stories.ts`) and `build-storybook`.
- Produces: `pnpm test-storybook` and a CI job that renders every story headless.

- [ ] **Step 1: Install the test-runner + browser**

Run:
```bash
cd frontend
pnpm add -D @storybook/test-runner concurrently http-server wait-on
pnpm exec playwright install --with-deps chromium
```

- [ ] **Step 2: Add package.json scripts**

In `frontend/package.json` `"scripts"`, add:

```json
    "test-storybook": "test-storybook --url http://127.0.0.1:6006",
    "test-storybook:ci": "concurrently -k -s first -n SB,TEST \"http-server storybook-static -p 6006 -a 127.0.0.1 --silent\" \"wait-on tcp:127.0.0.1:6006 && pnpm test-storybook\"",
```

- [ ] **Step 3: Build Storybook and run the test-runner locally**

Run:
```bash
cd frontend
pnpm build-storybook
pnpm test-storybook:ci
```
Expected: every story renders; the runner reports all stories passing (0 failures). This confirms the current stories are consistent with their components.

- [ ] **Step 4: Prove it fails on behavior drift**

Temporarily append a broken story to `src/components/primitives/BButton.stories.ts`:

```ts
export const Broken: Story = {
  render: () => ({ template: `<div>{{ missing.prop }}</div>` }), // throws at render
};
```

Then run:
```bash
cd frontend && pnpm build-storybook && pnpm test-storybook:ci
```
Expected: the runner fails on the `Broken` story (render error). **Revert the edit** (`git checkout src/components/primitives/BButton.stories.ts`) and re-run to confirm green.

- [ ] **Step 5: Add the CI job**

In `.github/workflows/frontend.yml`, add a second job under `jobs:` (sibling of `verify`):

```yaml
  storybook:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Set up pnpm
        uses: pnpm/action-setup@v4
        with:
          version: 9
      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'pnpm'
          cache-dependency-path: frontend/pnpm-lock.yaml
      - name: Install dependencies
        run: pnpm install --frozen-lockfile
      - name: Install Playwright chromium
        run: pnpm exec playwright install --with-deps chromium
      - name: Build Storybook
        run: pnpm build-storybook
      - name: Run Storybook test-runner
        run: pnpm test-storybook:ci
```

(This job inherits `defaults.run.working-directory: frontend`.)

- [ ] **Step 6: Commit**

```bash
git add frontend/package.json frontend/pnpm-lock.yaml .github/workflows/frontend.yml
git commit -m "test(frontend): Storybook test-runner render/a11y check in CI"
```

---

## Done criteria (Phase 1)

- `pnpm check:consistency` is green on the current tree and red on planted drift (missing story, new raw element, hard-coded hex).
- The three checks are TDD-covered by Vitest specs and complete in seconds.
- CI blocks drift: the `verify` job runs the fast gate; the `storybook` job renders every story.
- The 13 existing raw elements are grandfathered — no component markup changed.
- **Reused by later phases:** `check-consistency.sh` becomes the hard gate (②) that Phase 2's `/goal` evaluates against and the agent pipeline bounces the implementer off of.
