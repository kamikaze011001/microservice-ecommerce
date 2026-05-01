# Storefront Frontend — Phase 1 (Foundation & Documentation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the `frontend/` Vue 3 + Vite + TS project, wire all conventions/tooling, write 10 documentation files and 7 ADRs — but **build no UI features yet**. End state: a placeholder "Issue Nº01" page renders using design tokens; CI is green; every convention is written down.

**Architecture:** Single subfolder `frontend/` in the existing monorepo. Tailwind v4 driven by CSS variables in `tokens.css`. Self-hosted fonts under `public/fonts/`. Vitest for unit tests. ESLint flat config + Prettier + TS strict. Pre-commit hook runs lint+typecheck on staged files. CI workflow runs typecheck + lint + test on PRs touching `frontend/**`. Documentation lives at `frontend/docs/` and codifies the conventions defined in the design spec.

**Tech Stack:** Vue 3.4+, Vite 5+, TypeScript 5.4+ strict, Tailwind v4, Vitest, ESLint flat config, Prettier, Husky + lint-staged, pnpm 9, Node 20+.

**Spec references:**
- Design: `docs/superpowers/specs/2026-05-01-storefront-frontend-design.md`
- Rollout: `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md`

**Definition of Done (from rollout spec, copied for the executor):**
- [ ] `pnpm install && pnpm typecheck && pnpm lint && pnpm test` all exit 0 on a clean clone
- [ ] `pnpm dev` starts Vite, browser shows the "Issue Nº01" placeholder using `--paper`, `--ink`, `--spot` tokens and the Bricolage display font
- [ ] All 10 documentation files exist and are non-empty
- [ ] ≥ 7 ADRs committed under `frontend/docs/adr/`
- [ ] CI workflow runs and is green on the foundation PR
- [ ] Pre-commit hook blocks a deliberate lint error in a staged file
- [ ] Lighthouse run on placeholder page shows no console errors and no 404s

---

## Pre-flight

Run from repo root: `/Users/sonanh/Documents/AIBLES/microservice-ecommerce`. All paths in this plan are relative to that root.

Required local tooling (verify before starting):

```bash
node --version    # expect: v20.x or higher
pnpm --version    # expect: 9.x — install with `corepack enable && corepack prepare pnpm@latest --activate` if missing
git --version
```

If pnpm is missing, install via `corepack enable && corepack prepare pnpm@9 --activate` (Node 20 ships with corepack).

---

## Task 1: Bootstrap Vite + Vue 3 + TS scaffold

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/index.html`
- Create: `frontend/tsconfig.json`
- Create: `frontend/tsconfig.node.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/src/main.ts`
- Create: `frontend/src/App.vue`
- Create: `frontend/src/vite-env.d.ts`
- Create: `frontend/.gitignore`
- Create: `frontend/.npmrc`

- [ ] **Step 1: Create `frontend/.gitignore`**

```gitignore
node_modules
dist
dist-ssr
*.local
.vite
coverage
.env.local
.env.*.local

# IDE
.vscode/*
!.vscode/extensions.json
.idea
*.swp
.DS_Store
```

- [ ] **Step 2: Create `frontend/.npmrc`**

```
auto-install-peers=true
strict-peer-dependencies=false
shamefully-hoist=false
```

- [ ] **Step 3: Create `frontend/package.json`**

```json
{
  "name": "frontend",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vue-tsc -b && vite build",
    "preview": "vite preview",
    "typecheck": "vue-tsc --noEmit",
    "lint": "eslint .",
    "lint:fix": "eslint . --fix",
    "format": "prettier --write .",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "vue": "^3.4.38"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^5.1.3",
    "@vue/tsconfig": "^0.5.1",
    "typescript": "^5.4.5",
    "vite": "^5.4.6",
    "vue-tsc": "^2.1.6"
  },
  "engines": {
    "node": ">=20",
    "pnpm": ">=9"
  }
}
```

- [ ] **Step 4: Create `frontend/tsconfig.json`**

```json
{
  "files": [],
  "references": [
    { "path": "./tsconfig.app.json" },
    { "path": "./tsconfig.node.json" }
  ]
}
```

- [ ] **Step 5: Create `frontend/tsconfig.app.json`**

```json
{
  "extends": "@vue/tsconfig/tsconfig.dom.json",
  "compilerOptions": {
    "composite": true,
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo",
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    },
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "useUnknownInCatchVariables": true,
    "exactOptionalPropertyTypes": false,
    "types": ["vite/client"]
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "src/**/*.vue", "tests/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 6: Create `frontend/tsconfig.node.json`**

```json
{
  "extends": "@vue/tsconfig/tsconfig.node.json",
  "compilerOptions": {
    "composite": true,
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.node.tsbuildinfo",
    "types": ["node"]
  },
  "include": ["vite.config.ts", "vitest.config.ts", "eslint.config.js"]
}
```

Wire `tsconfig.json` to also reference `tsconfig.app.json`:

```bash
# (already done in Step 4 — confirm by reading the file)
```

- [ ] **Step 7: Create `frontend/vite.config.ts`**

```ts
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
});
```

- [ ] **Step 8: Create `frontend/index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Issue Nº01 — Storefront</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
```

- [ ] **Step 9: Create `frontend/src/vite-env.d.ts`**

```ts
/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue';
  const component: DefineComponent<object, object, unknown>;
  export default component;
}
```

- [ ] **Step 10: Create `frontend/src/main.ts`**

```ts
import { createApp } from 'vue';
import App from './App.vue';

createApp(App).mount('#app');
```

- [ ] **Step 11: Create minimal `frontend/src/App.vue` (will be replaced by placeholder page in Task 9)**

```vue
<script setup lang="ts">
// Placeholder — gets replaced by the Issue Nº01 page in Task 9.
</script>

<template>
  <div>Issue Nº01 bootstrap</div>
</template>
```

- [ ] **Step 12: Create a tiny favicon at `frontend/public/favicon.svg`**

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#F4EFE6"/><text x="16" y="22" text-anchor="middle" font-family="monospace" font-size="14" font-weight="900" fill="#FF4F1C">01</text></svg>
```

- [ ] **Step 13: Install dependencies**

```bash
cd frontend && pnpm install
```

Expected: pnpm resolves and installs without errors. `node_modules/` created.

- [ ] **Step 14: Verify typecheck and dev server**

```bash
cd frontend && pnpm typecheck
```

Expected: exit code 0, no errors.

```bash
cd frontend && pnpm dev
```

Expected: Vite reports "Local: http://localhost:5173/". Stop with `Ctrl+C` after confirming.

- [ ] **Step 15: Commit**

```bash
git add frontend/.gitignore frontend/.npmrc frontend/package.json frontend/pnpm-lock.yaml frontend/index.html frontend/public/favicon.svg frontend/tsconfig.json frontend/tsconfig.app.json frontend/tsconfig.node.json frontend/vite.config.ts frontend/src/main.ts frontend/src/App.vue frontend/src/vite-env.d.ts
git commit -m "feat(frontend): bootstrap Vite + Vue 3 + TS scaffold"
```

---

## Task 2: ESLint flat config + Prettier + Vue strict rules

**Files:**
- Create: `frontend/eslint.config.js`
- Create: `frontend/.prettierrc.json`
- Create: `frontend/.prettierignore`
- Modify: `frontend/package.json` (add devDependencies)

- [ ] **Step 1: Add ESLint + Prettier devDeps**

Edit `frontend/package.json`, adding to `devDependencies` (alphabetised):

```json
"@vue/eslint-config-prettier": "^9.0.0",
"@vue/eslint-config-typescript": "^13.0.0",
"eslint": "^9.10.0",
"eslint-plugin-vue": "^9.28.0",
"globals": "^15.9.0",
"prettier": "^3.3.3",
"typescript-eslint": "^8.4.0"
```

Then:

```bash
cd frontend && pnpm install
```

- [ ] **Step 2: Create `frontend/eslint.config.js`** (flat config)

```js
import js from '@eslint/js';
import vue from 'eslint-plugin-vue';
import tseslint from 'typescript-eslint';
import prettier from '@vue/eslint-config-prettier';
import globals from 'globals';

export default [
  {
    ignores: ['dist', 'node_modules', 'coverage', '*.config.js', '*.config.ts', 'public'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...vue.configs['flat/recommended'],
  {
    files: ['**/*.{ts,vue}'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: { ...globals.browser },
      parserOptions: {
        parser: tseslint.parser,
      },
    },
    rules: {
      'vue/multi-word-component-names': 'off',
      'vue/component-name-in-template-casing': ['error', 'PascalCase'],
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
    },
  },
  prettier,
];
```

- [ ] **Step 3: Create `frontend/.prettierrc.json`**

```json
{
  "semi": true,
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "tabWidth": 2,
  "endOfLine": "lf",
  "arrowParens": "always",
  "vueIndentScriptAndStyle": false
}
```

- [ ] **Step 4: Create `frontend/.prettierignore`**

```
dist
node_modules
coverage
pnpm-lock.yaml
public/fonts
```

- [ ] **Step 5: Run lint to verify config loads**

```bash
cd frontend && pnpm lint
```

Expected: exit 0 with no errors (the placeholder `App.vue` is clean).

- [ ] **Step 6: Run format check**

```bash
cd frontend && pnpm exec prettier --check .
```

Expected: all matched files report `(unchanged)`. Run `pnpm format` once if anything is flagged.

- [ ] **Step 7: Commit**

```bash
git add frontend/package.json frontend/pnpm-lock.yaml frontend/eslint.config.js frontend/.prettierrc.json frontend/.prettierignore
git commit -m "feat(frontend): add ESLint flat config + Prettier"
```

---

## Task 3: Vitest + first sample test (proves the test runner works)

**Files:**
- Create: `frontend/vitest.config.ts`
- Create: `frontend/tests/unit/setup.ts`
- Create: `frontend/tests/unit/sanity.spec.ts`
- Modify: `frontend/package.json` (add devDependencies)

- [ ] **Step 1: Add Vitest + Testing Library devDeps**

Edit `frontend/package.json`, adding to `devDependencies`:

```json
"@testing-library/vue": "^8.1.0",
"@vitest/ui": "^2.0.5",
"happy-dom": "^15.7.4",
"vitest": "^2.0.5"
```

```bash
cd frontend && pnpm install
```

- [ ] **Step 2: Create `frontend/vitest.config.ts`**

```ts
import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'happy-dom',
      globals: true,
      setupFiles: ['./tests/unit/setup.ts'],
      include: ['tests/unit/**/*.spec.ts'],
      reporters: ['default'],
    },
  }),
);
```

- [ ] **Step 3: Create `frontend/tests/unit/setup.ts`**

```ts
import '@testing-library/vue';
```

- [ ] **Step 4: Write the failing sanity test**

Create `frontend/tests/unit/sanity.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';

describe('sanity', () => {
  it('runs vitest', () => {
    expect(1 + 1).toBe(2);
  });

  it('has happy-dom available', () => {
    const div = document.createElement('div');
    div.textContent = 'paper';
    expect(div.textContent).toBe('paper');
  });
});
```

- [ ] **Step 5: Run tests**

```bash
cd frontend && pnpm test
```

Expected: 2 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add frontend/package.json frontend/pnpm-lock.yaml frontend/vitest.config.ts frontend/tests/unit/setup.ts frontend/tests/unit/sanity.spec.ts
git commit -m "feat(frontend): wire Vitest + happy-dom"
```

---

## Task 4: Tailwind v4 install + integration

**Files:**
- Create: `frontend/postcss.config.js`
- Create: `frontend/src/styles/main.css`
- Modify: `frontend/src/main.ts` (import main.css)
- Modify: `frontend/package.json` (add devDependencies)

Tailwind v4 is CSS-first: configure with `@theme` blocks in CSS, no JS config required.

- [ ] **Step 1: Add Tailwind v4 devDeps**

Edit `frontend/package.json`, adding to `devDependencies`:

```json
"@tailwindcss/postcss": "^4.0.0-beta.1",
"autoprefixer": "^10.4.20",
"postcss": "^8.4.45",
"tailwindcss": "^4.0.0-beta.1"
```

> Note for the implementer: at the time of writing, Tailwind v4 is in beta. If the latest stable is GA when you run this, replace `^4.0.0-beta.1` with the GA version. The CSS-first integration below works for both.

```bash
cd frontend && pnpm install
```

- [ ] **Step 2: Create `frontend/postcss.config.js`**

```js
export default {
  plugins: {
    '@tailwindcss/postcss': {},
    autoprefixer: {},
  },
};
```

- [ ] **Step 3: Create `frontend/src/styles/main.css`**

```css
@import 'tailwindcss';

/* Tokens get imported in Task 6 (after tokens.css is created). */

html, body, #app {
  height: 100%;
}

body {
  margin: 0;
  font-family: 'Cabinet Grotesk', system-ui, sans-serif;
  background: #F4EFE6;
  color: #1C1C1C;
  -webkit-font-smoothing: antialiased;
}
```

- [ ] **Step 4: Wire CSS into `frontend/src/main.ts`**

Replace the file contents with:

```ts
import { createApp } from 'vue';
import App from './App.vue';
import './styles/main.css';

createApp(App).mount('#app');
```

- [ ] **Step 5: Verify dev server still runs**

```bash
cd frontend && pnpm dev
```

Expected: Vite starts, browser shows the placeholder div on warm `#F4EFE6` background. Stop with `Ctrl+C`.

- [ ] **Step 6: Commit**

```bash
git add frontend/package.json frontend/pnpm-lock.yaml frontend/postcss.config.js frontend/src/styles/main.css frontend/src/main.ts
git commit -m "feat(frontend): wire Tailwind v4 + base CSS"
```

---

## Task 5: Self-host fonts + @font-face

The design spec mandates **Bricolage Grotesque** (display), **Cabinet Grotesk** (body), **Departure Mono** (mono). All three are free and must be self-hosted (no Google Fonts CDN).

**Files:**
- Create: `frontend/public/fonts/bricolage-grotesque-variable.woff2`
- Create: `frontend/public/fonts/cabinet-grotesk-medium.woff2`
- Create: `frontend/public/fonts/cabinet-grotesk-regular.woff2`
- Create: `frontend/public/fonts/departure-mono-regular.woff2`
- Create: `frontend/public/fonts/LICENSES.md`
- Create: `frontend/src/styles/fonts.css`
- Modify: `frontend/src/styles/main.css`

- [ ] **Step 1: Create `frontend/public/fonts/` directory**

```bash
mkdir -p frontend/public/fonts
```

- [ ] **Step 2: Download the three font families** (manual one-time fetch)

```bash
cd frontend/public/fonts

# Bricolage Grotesque variable (Google Fonts via fonts.googleapis ZIP — manual or via curl from gh release)
curl -L -o bricolage-grotesque-variable.woff2 \
  "https://fonts.gstatic.com/s/bricolagegrotesque/v3/3y9U6as8bTXq_nANBjzKo3IeZx8z6up5BeSl5jBNz_19PpbpMXuECpwUxJBOyaOTQ7K-QyYRsaPnsy4MmwQbUw.woff2"

# Cabinet Grotesk (Fontshare — variable / static woff2 endpoints)
# If the direct URL no longer resolves, download from https://www.fontshare.com/fonts/cabinet-grotesk and copy the .woff2 files in.
curl -L -o cabinet-grotesk-medium.woff2 \
  "https://api.fontshare.com/v2/fonts/cabinet-grotesk/CabinetGrotesk-Medium.woff2"
curl -L -o cabinet-grotesk-regular.woff2 \
  "https://api.fontshare.com/v2/fonts/cabinet-grotesk/CabinetGrotesk-Regular.woff2"

# Departure Mono (helena.gd — direct download)
curl -L -o departure-mono-regular.woff2 \
  "https://departuremono.com/fonts/DepartureMono-Regular.woff2"

ls -la
```

> If any URL fails (CDNs change), download manually from the respective sources and place into `frontend/public/fonts/` with the exact filenames above. Do not check binary fonts into git history without confirming licenses (see Step 3).

Expected: 4 `.woff2` files in `frontend/public/fonts/`, each non-zero size.

- [ ] **Step 3: Create `frontend/public/fonts/LICENSES.md` documenting font licensing**

```markdown
# Font licenses

| File | Family | License | Source |
|---|---|---|---|
| `bricolage-grotesque-variable.woff2` | Bricolage Grotesque (Variable) | SIL Open Font License 1.1 | https://fonts.google.com/specimen/Bricolage+Grotesque |
| `cabinet-grotesk-medium.woff2` | Cabinet Grotesk Medium | Fontshare Free License | https://www.fontshare.com/fonts/cabinet-grotesk |
| `cabinet-grotesk-regular.woff2` | Cabinet Grotesk Regular | Fontshare Free License | https://www.fontshare.com/fonts/cabinet-grotesk |
| `departure-mono-regular.woff2` | Departure Mono Regular | SIL Open Font License 1.1 | https://departuremono.com |

All three families are free for commercial use under their respective licenses.
Update this file if a font is replaced or added.
```

- [ ] **Step 4: Create `frontend/src/styles/fonts.css`**

```css
@font-face {
  font-family: 'Bricolage Grotesque';
  src: url('/fonts/bricolage-grotesque-variable.woff2') format('woff2-variations');
  font-weight: 200 800;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Cabinet Grotesk';
  src: url('/fonts/cabinet-grotesk-regular.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Cabinet Grotesk';
  src: url('/fonts/cabinet-grotesk-medium.woff2') format('woff2');
  font-weight: 500;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Departure Mono';
  src: url('/fonts/departure-mono-regular.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
```

- [ ] **Step 5: Import `fonts.css` into `main.css`**

Edit `frontend/src/styles/main.css` — change the file to:

```css
@import 'tailwindcss';
@import './fonts.css';

/* Tokens get imported in Task 6 (after tokens.css is created). */

html, body, #app {
  height: 100%;
}

body {
  margin: 0;
  font-family: 'Cabinet Grotesk', system-ui, sans-serif;
  background: #F4EFE6;
  color: #1C1C1C;
  -webkit-font-smoothing: antialiased;
}
```

- [ ] **Step 6: Verify fonts load (manual)**

```bash
cd frontend && pnpm dev
```

Open `http://localhost:5173/` in a browser, open DevTools → Network → filter `font`. Refresh. All four `.woff2` requests should be `200`. Stop server.

- [ ] **Step 7: Commit**

```bash
git add frontend/public/fonts/ frontend/src/styles/fonts.css frontend/src/styles/main.css
git commit -m "feat(frontend): self-host Bricolage / Cabinet Grotesk / Departure Mono"
```

---

## Task 6: Design tokens (`tokens.css`) — single source of truth

The spec defines the full Issue Nº01 token system. This task transcribes it into CSS variables.

**Files:**
- Create: `frontend/src/styles/tokens.css`
- Modify: `frontend/src/styles/main.css`

- [ ] **Step 1: Create `frontend/src/styles/tokens.css`**

```css
/*
 * Issue Nº01 design tokens — single source of truth.
 * Mirrored in docs/02-design-tokens.md. Update both together.
 * Do not hard-code these values anywhere else.
 */

:root {
  /* ─── Palette ─── */
  --paper:          #F4EFE6;
  --paper-shade:    #E8DFD0;
  --ink:            #1C1C1C;
  --muted-ink:      #6B6256;
  --spot:           #FF4F1C;
  --stamp-red:      #C4302B;

  /* ─── Type ─── */
  --font-display:   'Bricolage Grotesque', 'Cabinet Grotesk', system-ui, sans-serif;
  --font-body:      'Cabinet Grotesk', system-ui, sans-serif;
  --font-mono:      'Departure Mono', ui-monospace, 'SFMono-Regular', monospace;

  --type-display:   clamp(2.5rem, 5vw + 1rem, 5rem);
  --type-h1:        clamp(2rem, 3vw + 1rem, 3.25rem);
  --type-h2:        clamp(1.5rem, 2vw + 0.75rem, 2.25rem);
  --type-body:      1rem;
  --type-small:     0.8125rem;
  --type-mono:      0.875rem;

  --leading-tight:  1.05;
  --leading-body:   1.45;

  /* ─── Borders ─── */
  --border-thin:    2px solid var(--ink);
  --border-thick:   3px solid var(--ink);

  /* ─── Shadows (hard offset, no blur) ─── */
  --shadow-sm:      3px 3px 0 var(--ink);
  --shadow-md:      6px 6px 0 var(--ink);
  --shadow-lg:      10px 10px 0 var(--ink);

  /* ─── Motion ─── */
  --press-translate: 4px;
  --transition-snap: 60ms steps(2);

  /* ─── Spacing rhythm ─── */
  --space-1:  0.25rem;
  --space-2:  0.5rem;
  --space-3:  0.75rem;
  --space-4:  1rem;
  --space-6:  1.5rem;
  --space-8:  2rem;
  --space-12: 3rem;
  --space-16: 4rem;

  /* ─── Layout ─── */
  --container-max: 1280px;
}

/*
 * Tailwind v4 @theme bridge — exposes tokens as Tailwind utilities
 * (e.g. bg-paper, text-spot). Keep keys aligned with the variables above.
 */
@theme {
  --color-paper:        #F4EFE6;
  --color-paper-shade:  #E8DFD0;
  --color-ink:          #1C1C1C;
  --color-muted-ink:    #6B6256;
  --color-spot:         #FF4F1C;
  --color-stamp-red:    #C4302B;

  --font-display:       'Bricolage Grotesque', 'Cabinet Grotesk', system-ui, sans-serif;
  --font-body:          'Cabinet Grotesk', system-ui, sans-serif;
  --font-mono:          'Departure Mono', ui-monospace, monospace;
}
```

- [ ] **Step 2: Import tokens into `main.css`**

Edit `frontend/src/styles/main.css` — change to:

```css
@import 'tailwindcss';
@import './fonts.css';
@import './tokens.css';

html, body, #app {
  height: 100%;
}

body {
  margin: 0;
  font-family: var(--font-body);
  background: var(--paper);
  color: var(--ink);
  font-size: var(--type-body);
  line-height: var(--leading-body);
  -webkit-font-smoothing: antialiased;
}

/* Paper grain — subtle SVG noise overlay at ~4% opacity */
body::after {
  content: '';
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 1;
  opacity: 0.04;
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/></filter><rect width='100%25' height='100%25' filter='url(%23n)' opacity='0.5'/></svg>");
  mix-blend-mode: multiply;
}

::selection {
  background: var(--spot);
  color: var(--paper);
}
```

- [ ] **Step 3: Add a unit test that verifies tokens.css is importable + parses**

Create `frontend/tests/unit/tokens.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

describe('tokens.css', () => {
  const css = readFileSync(resolve(__dirname, '../../src/styles/tokens.css'), 'utf-8');

  it('declares the Issue Nº01 palette', () => {
    expect(css).toMatch(/--paper:\s*#F4EFE6/);
    expect(css).toMatch(/--ink:\s*#1C1C1C/);
    expect(css).toMatch(/--spot:\s*#FF4F1C/);
    expect(css).toMatch(/--stamp-red:\s*#C4302B/);
  });

  it('declares the type stack', () => {
    expect(css).toMatch(/--font-display:.*Bricolage Grotesque/);
    expect(css).toMatch(/--font-body:.*Cabinet Grotesk/);
    expect(css).toMatch(/--font-mono:.*Departure Mono/);
  });

  it('declares mechanical motion tokens', () => {
    expect(css).toMatch(/--press-translate:\s*4px/);
    expect(css).toMatch(/--transition-snap:\s*60ms\s+steps\(2\)/);
  });
});
```

- [ ] **Step 4: Run tests**

```bash
cd frontend && pnpm test
```

Expected: all tests pass (sanity 2 + tokens 3 = 5 total).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/styles/tokens.css frontend/src/styles/main.css frontend/tests/unit/tokens.spec.ts
git commit -m "feat(frontend): add Issue Nº01 design tokens + paper grain overlay"
```

---

## Task 7: Folder skeleton with `.gitkeep`

The full src tree must exist (so later phases drop files in without "where does this go?" debate), but each empty folder needs a `.gitkeep` so git tracks it.

**Files (all `.gitkeep` placeholders):**
- Create: `frontend/src/api/queries/.gitkeep`
- Create: `frontend/src/components/primitives/.gitkeep`
- Create: `frontend/src/components/domain/.gitkeep`
- Create: `frontend/src/composables/.gitkeep`
- Create: `frontend/src/pages/.gitkeep`
- Create: `frontend/src/router/.gitkeep`
- Create: `frontend/src/stores/.gitkeep`
- Create: `frontend/src/lib/.gitkeep`
- Create: `frontend/tests/e2e/.gitkeep`
- Create: `frontend/tests/fixtures/.gitkeep`

- [ ] **Step 1: Create the skeleton**

```bash
cd frontend
mkdir -p src/api/queries src/components/primitives src/components/domain src/composables src/pages src/router src/stores src/lib tests/e2e tests/fixtures
touch \
  src/api/queries/.gitkeep \
  src/components/primitives/.gitkeep \
  src/components/domain/.gitkeep \
  src/composables/.gitkeep \
  src/pages/.gitkeep \
  src/router/.gitkeep \
  src/stores/.gitkeep \
  src/lib/.gitkeep \
  tests/e2e/.gitkeep \
  tests/fixtures/.gitkeep
```

- [ ] **Step 2: Verify**

```bash
cd frontend && find src tests -name .gitkeep | sort
```

Expected: 10 lines.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/api frontend/src/components frontend/src/composables frontend/src/pages frontend/src/router frontend/src/stores frontend/src/lib frontend/tests/e2e frontend/tests/fixtures
git commit -m "chore(frontend): add folder skeleton with .gitkeep"
```

---

## Task 8: "Issue Nº01" placeholder page (the visual proof of the foundation)

Replaces the bootstrap `App.vue`. Must use `--paper`, `--ink`, `--spot` tokens and the Bricolage display font, per the rollout DoD.

**Files:**
- Modify: `frontend/src/App.vue`

- [ ] **Step 1: Write the placeholder page**

Replace `frontend/src/App.vue` contents with:

```vue
<script setup lang="ts">
const buildVersion = '0.0.0';
const buildDate = new Date().toISOString().slice(0, 10);
</script>

<template>
  <main class="page">
    <header class="masthead">
      <span class="numeral">01</span>
      <p class="kicker">Issue Nº01 — Storefront</p>
    </header>

    <section class="hero">
      <h1 class="title">FOUNDATION<br />LAID.</h1>
      <p class="lede">
        Tokens render. Fonts load. The press is warm.<br />
        Phase 2 starts here.
      </p>
      <div class="stamp">PHASE 1 ✓</div>
    </section>

    <footer class="colophon">
      <span>v{{ buildVersion }}</span>
      <span>{{ buildDate }}</span>
      <span>aibles ecommerce</span>
    </footer>
  </main>
</template>

<style scoped>
.page {
  position: relative;
  z-index: 2;
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  min-height: 100vh;
  display: grid;
  grid-template-rows: auto 1fr auto;
  gap: var(--space-8);
}

.masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
}

.numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}

.kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}

.hero {
  align-self: center;
  display: grid;
  gap: var(--space-6);
  position: relative;
}

.title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: var(--leading-tight);
  letter-spacing: -0.02em;
  margin: 0;
  text-transform: uppercase;
  text-shadow: 4px 4px 0 var(--spot);
}

.lede {
  font-family: var(--font-body);
  font-size: var(--type-h2);
  line-height: var(--leading-body);
  max-width: 32ch;
  margin: 0;
}

.stamp {
  justify-self: start;
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--stamp-red);
  border: 3px double var(--stamp-red);
  padding: var(--space-2) var(--space-4);
  transform: rotate(-3deg);
}

.colophon {
  display: flex;
  justify-content: space-between;
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  border-top: var(--border-thin);
  padding-top: var(--space-3);
}
</style>
```

- [ ] **Step 2: Run dev server, verify visually**

```bash
cd frontend && pnpm dev
```

Open `http://localhost:5173/` in a browser. Confirm:
- Page background is paper-cream `#F4EFE6`
- Title "FOUNDATION LAID." renders in Bricolage 900 with an orange offset shadow
- Hollow outlined "01" numeral in the masthead
- Departure Mono kicker text and colophon
- Browser console (DevTools) is clean — no errors, no 404s
- Network tab — all 4 `.woff2` files return 200

Stop the dev server.

- [ ] **Step 3: Run typecheck + lint + tests**

```bash
cd frontend && pnpm typecheck && pnpm lint && pnpm test
```

Expected: all three exit 0.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/App.vue
git commit -m "feat(frontend): Issue Nº01 placeholder page using design tokens"
```

---

## Task 9: Husky pre-commit hook (lint-staged)

Pre-commit hook must block staged files that fail lint (DoD bullet: "Pre-commit hook blocks a deliberate lint error in a staged file"). Runs at the **repo root** so it covers commits made from anywhere.

**Files:**
- Create: `.husky/pre-commit`
- Modify: `frontend/package.json` (add `lint-staged` devDep + `lint-staged` config field)
- Modify: repo-root `package.json` if it exists, else create one (root needs husky)

- [ ] **Step 1: Check whether the repo has a root `package.json`**

```bash
ls -la package.json
```

If a root `package.json` already exists, skip Step 2 (treat the existing file as the husky host). Otherwise, create one in Step 2.

- [ ] **Step 2: Create a minimal root `package.json` if missing**

Only run this step if `package.json` is absent at the repo root.

```json
{
  "name": "microservice-ecommerce-root",
  "private": true,
  "version": "0.0.0",
  "scripts": {
    "prepare": "husky"
  },
  "devDependencies": {
    "husky": "^9.1.5"
  }
}
```

```bash
pnpm install
```

- [ ] **Step 3: Add husky to the existing root `package.json`** (only if Step 2 was skipped)

Edit the existing root `package.json`:
- Add `"prepare": "husky"` to its `scripts`
- Add `"husky": "^9.1.5"` to its `devDependencies`

Then:

```bash
pnpm install
```

- [ ] **Step 4: Add `lint-staged` to `frontend/package.json`**

Add to `frontend/package.json` `devDependencies`:

```json
"lint-staged": "^15.2.10"
```

Add a top-level field:

```json
"lint-staged": {
  "*.{ts,vue}": ["eslint --fix"],
  "*.{ts,vue,css,md,json}": ["prettier --write"]
}
```

```bash
cd frontend && pnpm install
```

- [ ] **Step 5: Initialize husky**

```bash
pnpm exec husky init
```

This creates `.husky/pre-commit` with a sample `pnpm test` line.

- [ ] **Step 6: Replace `.husky/pre-commit` contents**

```sh
#!/usr/bin/env sh

cd frontend && pnpm exec lint-staged --concurrent false && pnpm typecheck
```

Make executable:

```bash
chmod +x .husky/pre-commit
```

- [ ] **Step 7: Smoke-test the hook (deliberate lint failure)**

Append a deliberate lint failure to `frontend/src/main.ts`:

```ts
// At the very end of the file:
const unused_var_for_lint_test = 'this triggers no-unused-vars';
```

Then:

```bash
git add frontend/src/main.ts
git commit -m "test: deliberate lint failure (should be blocked)"
```

Expected: commit is **rejected** with an ESLint error about the unused variable.

Now revert:

```bash
git restore --staged frontend/src/main.ts
git checkout frontend/src/main.ts
```

- [ ] **Step 8: Commit the hook setup**

```bash
git add .husky/pre-commit package.json frontend/package.json frontend/pnpm-lock.yaml pnpm-lock.yaml
git commit -m "chore: pre-commit hook (lint-staged + typecheck) for frontend/"
```

(Some files in the `git add` list may not exist depending on Step 1 — drop those from the command.)

---

## Task 10: GitHub Actions CI workflow

CI runs on PRs that touch `frontend/**` and runs typecheck + lint + test. Must be green for the foundation PR (DoD bullet).

**Files:**
- Create: `.github/workflows/frontend.yml`

- [ ] **Step 1: Create the workflow**

```yaml
name: frontend

on:
  pull_request:
    paths:
      - 'frontend/**'
      - '.github/workflows/frontend.yml'
  push:
    branches: [main]
    paths:
      - 'frontend/**'
      - '.github/workflows/frontend.yml'

defaults:
  run:
    working-directory: frontend

jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 10
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

      - name: Typecheck
        run: pnpm typecheck

      - name: Lint
        run: pnpm lint

      - name: Test
        run: pnpm test
```

- [ ] **Step 2: Lint the workflow file locally** (optional but cheap)

```bash
# If actionlint is installed:
actionlint .github/workflows/frontend.yml || true
```

If actionlint isn't installed, skip — GitHub will validate on push.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/frontend.yml
git commit -m "ci(frontend): add typecheck + lint + test workflow"
```

The workflow's first green run happens after the PR is opened — verified in Task 23 (DoD verification).

---

## Task 11: Doc 00 — README (`docs/00-readme.md`)

**Files:**
- Create: `frontend/docs/00-readme.md`

- [ ] **Step 1: Write the file**

```markdown
# Storefront Frontend

The Vue 3 + Vite + TS storefront for the aibles e-commerce backend.
Style: risograph-zine "Issue Nº01" — see [`02-design-tokens.md`](./02-design-tokens.md).
Architecture: see [`01-architecture.md`](./01-architecture.md).

## Prerequisites

- Node ≥ 20 (LTS)
- pnpm ≥ 9 (`corepack enable && corepack prepare pnpm@9 --activate`)
- Backend running locally — run `make up` from the repo root before `pnpm dev`.

## Commands

| Command | What it does |
|---|---|
| `pnpm install` | Install dependencies |
| `pnpm dev` | Start Vite dev server on `http://localhost:5173` |
| `pnpm build` | Production build to `dist/` |
| `pnpm preview` | Serve the production build |
| `pnpm typecheck` | `vue-tsc --noEmit` (TypeScript strict) |
| `pnpm lint` | ESLint flat config check |
| `pnpm lint:fix` | ESLint auto-fix |
| `pnpm format` | Prettier write |
| `pnpm test` | Vitest unit + component tests |
| `pnpm test:watch` | Vitest in watch mode |

## Folder map

```
frontend/
├── public/fonts/             self-hosted Bricolage / Cabinet / Departure
├── src/
│   ├── api/                  openapi-fetch client + queries layer
│   ├── components/{primitives,domain}/
│   ├── composables/
│   ├── lib/                  zod schemas, formatters
│   ├── pages/
│   ├── router/
│   ├── stores/               Pinia (auth + UI only)
│   └── styles/               tokens.css, fonts.css, main.css
├── tests/{unit,e2e,fixtures}/
└── docs/                     this folder
```

## Where to look

- Adding a primitive? Read [`03-component-conventions.md`](./03-component-conventions.md).
- Adding an API call? Read [`04-api-conventions.md`](./04-api-conventions.md).
- Adding a form? Read [`05-form-conventions.md`](./05-form-conventions.md).
- Adding a route? Read [`06-routing-auth.md`](./06-routing-auth.md).
- Writing a test? Read [`07-testing-conventions.md`](./07-testing-conventions.md).
- Writing copy? Read [`08-copy-and-voice.md`](./08-copy-and-voice.md).
- Accessibility? Read [`09-a11y-checklist.md`](./09-a11y-checklist.md).
- Why we picked X? Read [`adr/`](./adr/).

## Local dev gotchas

- The dev server proxies `/api/**` → `http://localhost:8080` (gateway). The backend must be `make up`.
- If fonts 404 on first load, confirm `frontend/public/fonts/` has the four `.woff2` files (download paths in `LICENSES.md`).
- Pre-commit hook runs `lint-staged` + `typecheck` on staged files. It will block bad commits.
- Vault-sealed backend = 503 on first API call. Re-run `make up`.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/00-readme.md
git commit -m "docs(frontend): add 00-readme — onboarding + commands"
```

---

## Task 12: Doc 01 — Architecture (`docs/01-architecture.md`)

**Files:**
- Create: `frontend/docs/01-architecture.md`

- [ ] **Step 1: Write the file**

```markdown
# Architecture

## Stack at a glance

| Concern | Pick |
|---|---|
| Framework | Vue 3 (Composition API) + Vite + TS strict |
| Server state | TanStack Vue Query |
| Client state | Pinia (auth + UI only — never server data) |
| API client | `openapi-typescript` (codegen) + `openapi-fetch` (~3 kB runtime) |
| Forms | VeeValidate + Zod (schemas reused for runtime API parsing) |
| Routing | Vue Router 4 + route guards |
| Styling | Tailwind v4 + custom tokens, hand-rolled primitives |
| Headless a11y | Reka UI (Dialog, Select, Popover) |
| Tests | Vitest + @testing-library/vue + MSW + Playwright |

Decision rationale lives in [`adr/`](./adr/).

## Folder structure

```
frontend/src/
├── api/
│   ├── schema.d.ts           # generated from gateway /v3/api-docs (Phase 3)
│   ├── client.ts             # openapi-fetch + auth interceptor
│   └── queries/              # vue-query wrappers per resource
├── components/
│   ├── primitives/           # B*: BButton, BCard, BInput, BStamp, ...
│   └── domain/               # ProductCard, CartLineItem, OrderRow, ...
├── composables/              # useAuth, useToast, useTelemetry, ...
├── pages/
├── router/
├── stores/                   # Pinia: auth + ui only
├── styles/                   # tokens.css, fonts.css, main.css
└── lib/                      # zod-schemas.ts, format.ts
```

## Layer boundaries

Three boundaries are strict. Violating them is a review-block.

### 1. The API boundary lives in `src/api/queries/`

- **No component, page, or composable calls `client.GET / .POST` directly.**
- Components consume `useProductsQuery()`, `useAddToCartMutation()`, etc. — exported only from `src/api/queries/`.
- Why: centralizes cache keys, error mapping, retry policy, invalidation rules. If the API changes, edits stay in one place.

### 2. Primitives know nothing about the API

- `src/components/primitives/B*` are styling-only. Props in, slots/emits out.
- They never import from `@/api`, `@/stores`, `@/composables/useAuth`.
- Why: primitives are reusable across pages and testable in isolation.

### 3. Zod schemas are the single source of truth for shape

- Every input shape and every API response shape is defined in `src/lib/zod-schemas.ts`.
- The same schema validates a form (via VeeValidate's `toTypedSchema`) and parses an API response in `src/api/queries/`.
- Why: drift between FE types and backend shapes fails fast, in one file.

## Data flow

```
User input
   ↓
Page component (uses primitives + queries)
   ↓
useXQuery / useXMutation       ← src/api/queries/
   ↓
openapi-fetch client           ← src/api/client.ts
   ↓
/api/** (Vite proxy in dev)
   ↓
http://localhost:8080 (gateway)
   ↓
microservice
```

Server data lives in TanStack Query's cache. Pinia holds **only** auth (token + identity) and UI state (toasts, modal stack). If you find yourself caching server data in Pinia, stop — use a query.

## Why so many small files

- A primitive per file. A page per file. A query module per resource.
- Smaller files are faster to reason about, faster to review, and produce cleaner diffs.
- Files that change together live together (e.g. `useCartQuery` and `useAddToCartMutation` share `api/queries/cart.ts`), but a module shouldn't grow past ~150 lines without a reason.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/01-architecture.md
git commit -m "docs(frontend): add 01-architecture — folders + boundaries + data flow"
```

---

## Task 13: Doc 02 — Design tokens (`docs/02-design-tokens.md`)

**Files:**
- Create: `frontend/docs/02-design-tokens.md`

- [ ] **Step 1: Write the file**

```markdown
# Design tokens — Issue Nº01

The Issue Nº01 risograph-zine identity. Tokens are defined in
[`src/styles/tokens.css`](../src/styles/tokens.css) — that file is the source of truth.
This doc is intent + usage. Update both together.

## Palette — risograph two-tone + one spot

| Token | Hex | Intent |
|---|---|---|
| `--paper`        | `#F4EFE6` | Warm off-white. Page background. |
| `--paper-shade`  | `#E8DFD0` | Card / surface contrast against paper. |
| `--ink`          | `#1C1C1C` | Warm charcoal. Text + borders. |
| `--muted-ink`    | `#6B6256` | Secondary text, hints, colophon. |
| `--spot`         | `#FF4F1C` | Fluorescent riso orange. **Every CTA, focus ring, alert.** Singular memorable thing. |
| `--stamp-red`    | `#C4302B` | Stamps + inspection marks only — `<BStamp>`, validation borders. Never a CTA. |

**Restraint matters.** Two-tone everywhere else makes orange punch.
Don't introduce a fourth or fifth colour without a token + ADR.

## Type stack — distinctive, free, self-hosted

| Role | Family | Where |
|---|---|---|
| Display | **Bricolage Grotesque** weight 900 | Hero titles, page numerals, big stamps |
| Body | **Cabinet Grotesk** Regular / Medium | Default body, buttons, cards |
| Mono | **Departure Mono** | SKUs, order IDs, prices, timestamps, kicker labels |

`--type-display`, `--type-h1`, `--type-h2`, `--type-body`, `--type-small`, `--type-mono` are scaled with `clamp()` for fluid type. Don't hard-code `font-size: 32px;` — pick the closest scale token.

**Banned:** Inter, Archivo Black, system-ui as primary, Roboto.

## Borders & shadows — thick + hard offset

| Token | Value | Use |
|---|---|---|
| `--border-thin`  | `2px solid var(--ink)` | Inputs, divider rules |
| `--border-thick` | `3px solid var(--ink)` | Cards, buttons, masthead |
| `--shadow-sm`    | `3px 3px 0 var(--ink)` | Hover state, small chips |
| `--shadow-md`    | `6px 6px 0 var(--ink)` | Default button + card shadow |
| `--shadow-lg`    | `10px 10px 0 var(--ink)` | Hero CTA, primary surfaces |

No blur, no opacity. Hard offset only. The shadow IS the depth language.

## Motion — mechanical, not smooth

```css
--press-translate: 4px;
--transition-snap: 60ms steps(2);
```

`steps(2)` is the signature. Buttons translate `4px 4px` down-right on `:active`, shadow shrinks to `--shadow-sm`. The two-step transition feels like a printing press impact, not Material's eased ripple.

Reduced-motion respect — see [`09-a11y-checklist.md`](./09-a11y-checklist.md).

## Spacing rhythm

`--space-1` (4 px) → `--space-16` (64 px). Page margin defaults to `--space-6` / `--space-8`. Don't introduce arbitrary `padding: 13px;` — pick the nearest step.

## Signature details (where tokens become identity)

These are codified in the design spec. Use them — they're what makes Issue Nº01 not generic neo-brutalism.

1. **Stamps, not badges** — `<BStamp>` for status (PROCESSING / PAID / CANCELED). Double-ring border, condensed mono, `--stamp-red`, slight rotation.
2. **Misregistration on hover** — product card titles get `text-shadow: 2px 2px 0 var(--spot)` on hover. Looks misprinted.
3. **Marginalia numerals** — `<BMarginNumeral>` renders huge outlined section numerals ("01", "02").
4. **Cropmark dividers** — `<BCropmarks>` instead of `<hr>`. Four small black corner marks.
5. **Sticker rotation** — product cards sit at ±0.5° random rotation. Pinned-to-wall, not grid.
6. **Paper grain** — body has SVG noise overlay at ~4% opacity (`body::after` in `main.css`).
7. **The CTA press** — `:active` translate + shadow shrink + `steps(2)` snap.

## Hard rules

- Never hard-code a hex outside `tokens.css`. Use `var(--…)` or the matching Tailwind utility (`text-spot`, `bg-paper-shade`, etc.).
- New colour or motion value? Add a token first, ADR if it's structurally new.
- Tailwind utilities are allowed for spacing / layout. Visual identity tokens win for colour, type, shadow, border.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/02-design-tokens.md
git commit -m "docs(frontend): add 02-design-tokens — palette, type, signature details"
```

---

## Task 14: Doc 03 — Component conventions (`docs/03-component-conventions.md`)

**Files:**
- Create: `frontend/docs/03-component-conventions.md`

- [ ] **Step 1: Write the file**

```markdown
# Component conventions

## Two layers, no exceptions

| Layer | Path | What | Example |
|---|---|---|---|
| Primitives | `src/components/primitives/B*` | Pure styling/behaviour, no API/auth/store knowledge | `BButton`, `BInput`, `BStamp` |
| Domain | `src/components/domain/` | Composes primitives + queries; embeds business meaning | `ProductCard`, `CartLineItem` |

A primitive that imports from `@/api`, `@/stores`, or `@/composables/useAuth` is in the wrong layer.

## Naming

- Primitives are prefixed `B` (Issue Nº01's "B" for Brutalism / Brand). Single word after: `BButton`, `BCard`, `BStamp`.
- Domain components are noun-cased: `ProductCard`, `OrderRow`, `CartLineItem`.
- Pages end in `Page`: `HomePage`, `CartPage`, `ProductDetailPage`.
- Files mirror the component name: `BButton.vue`, `ProductCard.vue`.

## Component shape

```vue
<script setup lang="ts">
// 1. Type imports first.
import type { ButtonHTMLAttributes } from 'vue';

// 2. Define props with TS types, not runtime declarations.
type Variant = 'spot' | 'ink' | 'ghost' | 'danger';

const props = withDefaults(
  defineProps<{
    variant?: Variant;
    type?: ButtonHTMLAttributes['type'];
    disabled?: boolean;
  }>(),
  { variant: 'spot', type: 'button', disabled: false },
);

// 3. Emits typed.
const emit = defineEmits<{
  click: [event: MouseEvent];
}>();
</script>

<template>
  <button
    :type="type"
    :disabled="disabled"
    :class="['b-button', `b-button--${variant}`]"
    @click="emit('click', $event)"
  >
    <slot />
  </button>
</template>

<style scoped>
.b-button {
  border: var(--border-thick);
  background: var(--paper);
  color: var(--ink);
  padding: var(--space-3) var(--space-6);
  font-family: var(--font-body);
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  box-shadow: var(--shadow-md);
  transition: transform var(--transition-snap), box-shadow var(--transition-snap);
}
.b-button:active {
  transform: translate(var(--press-translate), var(--press-translate));
  box-shadow: var(--shadow-sm);
}
.b-button--spot { background: var(--spot); color: var(--ink); }
.b-button--ink { background: var(--ink); color: var(--paper); }
.b-button--ghost { background: transparent; box-shadow: none; }
.b-button--danger { background: var(--stamp-red); color: var(--paper); }
.b-button:focus-visible { outline: 3px solid var(--spot); outline-offset: 2px; }
</style>
```

(That's the conventions sketch. The actual `BButton` ships in Phase 2.)

## Props / slots / emits

- **Props are typed via TS, not runtime `defineProps({ … })`.** Use `withDefaults` for defaults.
- **Variants are unions of string literals.** Not booleans. `variant="spot"` not `:isPrimary="true"`.
- **Slots over render props.** Default slot for content, named slots for `prefix` / `suffix` / `footer`.
- **Emits are typed tuple-style.** `defineEmits<{ click: [event: MouseEvent] }>()`.
- **No prop drilling more than one level.** If a primitive needs auth, that's domain — wrap it.

## Styling

- `<style scoped>` per component. No global classes from primitives.
- Use tokens (`var(--…)`) and Tailwind utilities. Never raw hex.
- BEM-ish class names within scoped styles (`.b-button`, `.b-button--spot`). Scoped CSS handles isolation; the BEM-ish prefix keeps DOM inspection readable.
- Don't author `<style lang="scss">`. Plain CSS + Tailwind v4.

## Composition over configuration

If a primitive's prop list grows past ~6 props, prefer composition (slots) over more props.

```vue
<!-- Bad: prop sprawl -->
<BCard
  :title="…"
  :subtitle="…"
  :media="…"
  :footer="…"
  :rotate="…"
  :clickable="true"
  :compact="true"
/>

<!-- Good: slots -->
<BCard rotate>
  <template #media><img …></template>
  <h3>{{ title }}</h3>
  <p>{{ subtitle }}</p>
  <template #footer><BButton variant="spot">BUY</BButton></template>
</BCard>
```

## What primitives must NOT do

- Make API calls
- Read `useAuthStore`
- Use `useRoute` / `useRouter`
- Render route-aware logic ("if `/cart` show X")
- Import from `src/api/`, `src/stores/`

If the requirement violates this list, lift it to a domain component that wraps the primitive.

## Tests

Every primitive has ≥ 2 component tests (happy path + variant/state). See [`07-testing-conventions.md`](./07-testing-conventions.md).
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/03-component-conventions.md
git commit -m "docs(frontend): add 03-component-conventions — primitives vs domain"
```

---

## Task 15: Doc 04 — API conventions (`docs/04-api-conventions.md`)

**Files:**
- Create: `frontend/docs/04-api-conventions.md`

- [ ] **Step 1: Write the file**

```markdown
# API conventions

The API boundary is `src/api/queries/`. Components, pages, and composables consume hooks from here, never the raw client.

## Generation pipeline (wired in Phase 3)

```
Backend gateway              FE codegen         FE runtime
/v3/api-docs (OpenAPI)  ───→  schema.d.ts  ───→ openapi-fetch <client>
                              (types only)       + auth interceptor
                                                 + error classifier
```

- `pnpm api:gen` → fetches `http://localhost:8080/v3/api-docs` and writes `src/api/schema.d.ts` via `openapi-typescript`.
- `src/api/client.ts` exports a singleton `client` from `openapi-fetch<paths>()`.
- The interceptor attaches `Authorization: Bearer <token>` and classifies errors.

Components never import `client` directly.

## Query / mutation hooks

### Naming

- Queries: `useXQuery`, `useXListQuery`, `useXByIdQuery`.
- Mutations: `useCreateXMutation`, `useUpdateXMutation`, `useDeleteXMutation`, `useXActionMutation` (e.g. `useCancelOrderMutation`).
- One file per resource: `src/api/queries/products.ts`, `cart.ts`, `orders.ts`, `auth.ts`, `payment.ts`.

### Cache key hierarchy

Hierarchical keys allow surgical invalidation.

| Key | Meaning |
|---|---|
| `["currentUser"]` | Logged-in user |
| `["products"]` | Product list (with filters as second segment) |
| `["products", { page, q }]` | List with params |
| `["products", id]` | Single product detail |
| `["cart"]` | Current user's cart |
| `["orders"]` | Order list |
| `["orders", id]` | Single order |
| `["payments", paymentId]` | Single payment |

`queryClient.invalidateQueries({ queryKey: ["products"] })` invalidates list AND detail.
`queryClient.invalidateQueries({ queryKey: ["products", id], exact: true })` hits one entry.

## Invalidation rules

| Mutation | Invalidates |
|---|---|
| Login / Register | `["currentUser"]` |
| Add / Update / Remove cart | `["cart"]` |
| Create order | `["cart"]`, `["orders"]` |
| Cancel order | `["orders"]`, `["orders", orderId]` |
| Logout | `queryClient.clear()` |

Document each new mutation here when added.

## Error taxonomy

The interceptor classifies every non-2xx response into one of six classes. UX defaults are codified.

| Class | Status | Default UX |
|---|---|---|
| `auth-required` | 401 | Clear auth store; redirect to `/login?next=<currentPath>` |
| `forbidden` | 403 | Toast "Not allowed"; stay on page |
| `not-found` | 404 | Route-level → 404 page; component-level → empty state |
| `validation` | 400 / 409 / 422 | **NO toast.** Surface inline (form field or page banner). 409 maps via `code` for tailored copy (e.g. `ORDER_ALREADY_CANCELED`). |
| `server` | 500-599 | Toast "Server error — try again". Queries auto-retry 3× exp-backoff. Mutations don't auto-retry. |
| `network` | fetch threw | Toast "Connection lost"; mutations show inline retry. |

Backend envelope: `BaseResponse { status, code, message, data }`. The interceptor unwraps `data` on 2xx; on error, throws a typed `ApiError { status, code, message }`.

## Retry policy

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error) => {
        if ((error as ApiError).status >= 500) return failureCount < 3;
        return false;
      },
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 8000),
      staleTime: 30_000,
    },
    mutations: { retry: false },
  },
});
```

Mutations never auto-retry — that's a bad default for state-changing calls.

## Optimistic mutation pattern

Used for: cancel order, qty stepper, remove cart item. Pattern:

```ts
useMutation({
  mutationFn: cancelOrder,
  onMutate: async (orderId) => {
    await queryClient.cancelQueries({ queryKey: ["orders"] });
    const prev = queryClient.getQueryData(["orders"]);
    queryClient.setQueryData(["orders"], (old) =>
      old.map(o => o.id === orderId ? { ...o, status: "CANCELED" } : o)
    );
    return { prev };
  },
  onError: (err, _id, ctx) => {
    queryClient.setQueryData(["orders"], ctx.prev);
    toast.error(err.code === "ORDER_ALREADY_CANCELED"
      ? "Already canceled — refreshed."
      : "Cancel failed");
  },
  onSettled: () => queryClient.invalidateQueries({ queryKey: ["orders"] }),
});
```

`onError` rolls back. `onSettled` always reconciles with server truth. The user sees instant feedback; conflicts auto-correct.

## Hard rules

- **Never** call `client.GET` / `client.POST` from a component, page, or store. Always go through `src/api/queries/`.
- **Never** cache server data in Pinia.
- **Never** swallow an `ApiError` — let it propagate and let the taxonomy decide UX.
- New endpoint → new test in `tests/unit/api/` (mocked via MSW) covering happy + one error class.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/04-api-conventions.md
git commit -m "docs(frontend): add 04-api-conventions — queries, cache keys, error taxonomy"
```

---

## Task 16: Doc 05 — Form conventions (`docs/05-form-conventions.md`)

**Files:**
- Create: `frontend/docs/05-form-conventions.md`

- [ ] **Step 1: Write the file**

```markdown
# Form conventions

VeeValidate + Zod. Schemas live in `src/lib/zod-schemas.ts` and are reused for **two** purposes:

1. Form validation (via `toTypedSchema`).
2. Runtime parsing of API responses in `src/api/queries/`.

If a schema only validates a form, you're missing half the value. Define once, use both places.

## Schema location and naming

`src/lib/zod-schemas.ts` exports schemas grouped by domain.

```ts
import { z } from 'zod';

// ─── Atoms (reused across forms + responses) ───
export const emailSchema = z.string().email('Enter a valid email');
export const passwordSchema = z
  .string()
  .min(8, 'Min 8 chars')
  .regex(/[A-Z]/, 'One uppercase')
  .regex(/[a-z]/, 'One lowercase')
  .regex(/\d/, 'One number');

// ─── Composites ───
export const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, 'Required'),
});
export type LoginInput = z.infer<typeof loginSchema>;

export const registerSchema = z
  .object({
    email: emailSchema,
    password: passwordSchema,
    confirmPassword: z.string(),
  })
  .refine((d) => d.password === d.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  });
export type RegisterInput = z.infer<typeof registerSchema>;

export const addressSchema = z.object({
  street: z.string().min(1, 'Required'),
  city: z.string().min(1, 'Required'),
  state: z.string().min(1, 'Required'),
  postcode: z.string().min(1, 'Required'),
  country: z.string().min(2, 'Required'),
  phone: z.string().min(7, 'Required'),
});
export type AddressInput = z.infer<typeof addressSchema>;
```

Password schema **must match** backend `@ValidPassword`. When the backend rule changes, this file changes too — that's the contract.

## Form component shape

```vue
<script setup lang="ts">
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { loginSchema } from '@/lib/zod-schemas';
import { useLoginMutation } from '@/api/queries/auth';

const { mutateAsync: login, isPending } = useLoginMutation();

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(loginSchema),
});

const [email, emailAttrs] = defineField('email');
const [password, passwordAttrs] = defineField('password');

const onSubmit = handleSubmit(async (values) => {
  try {
    await login(values);
    // navigation handled in the mutation onSuccess
  } catch (err) {
    // see "Server-error mapping" below
    if (err.code === 'INVALID_CREDENTIALS') {
      setErrors({ password: 'Wrong email or password' });
    }
  }
});
</script>

<template>
  <form novalidate @submit.prevent="onSubmit">
    <BInput v-model="email" v-bind="emailAttrs" :error="errors.email" label="Email" />
    <BInput v-model="password" v-bind="passwordAttrs" :error="errors.password" type="password" label="Password" />
    <BButton type="submit" variant="spot" :disabled="isPending">
      {{ isPending ? 'STAMPING…' : 'LOG IN' }}
    </BButton>
  </form>
</template>
```

## Server-error mapping

Server-side validation (`400`, `409`, `422`) maps to **inline form errors**, not toasts. The interceptor classifies these as `validation`. Forms catch the error and call `setErrors({ field: message })`.

| Backend code | Form field | Message |
|---|---|---|
| `INVALID_CREDENTIALS` | `password` | "Wrong email or password" |
| `EMAIL_TAKEN` | `email` | "Email already in use" |
| `ORDER_ALREADY_CANCELED` | (n/a — toast on Orders page) | "Already canceled — refreshed." |
| Generic `validation` with field details | per `field` | server-provided `message` |

Add new mappings here when a form ships.

## Hard rules

- **Schema lives in `src/lib/zod-schemas.ts`.** Never inline a `z.object` inside a form component.
- **Server validation → inline error.** No toasts for validation failures. Toasts are for `network` / `server` only.
- **Submit button shows loading copy.** "STAMPING…" while pending, voice from [`08-copy-and-voice.md`](./08-copy-and-voice.md).
- **Forms have `novalidate` on the `<form>` tag.** Browser native validation fights with our errors.
- **Empty success state still navigates.** `mutation.onSuccess` does router.push, not the form.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/05-form-conventions.md
git commit -m "docs(frontend): add 05-form-conventions — Zod sharing + server-error mapping"
```

---

## Task 17: Doc 06 — Routing & auth (`docs/06-routing-auth.md`)

**Files:**
- Create: `frontend/docs/06-routing-auth.md`

- [ ] **Step 1: Write the file**

```markdown
# Routing & auth

## Route table

| Path | Page | Auth |
|---|---|---|
| `/` | `HomePage` | public |
| `/products/:id` | `ProductDetailPage` | public |
| `/login` | `LoginPage` | guest-only (logged-in → `/`) |
| `/register` | `RegisterPage` | guest-only |
| `/cart` | `CartPage` | required |
| `/checkout` | `CheckoutPage` | required |
| `/orders` | `OrdersPage` | required (`?selected=ORD123` opens detail panel) |
| `/payment/success` | `PaymentResultPage` | public (PayPal lands here, `?orderId=…`) |
| `/payment/cancel` | `PaymentResultPage` | public (`?orderId=…`) |

## Guards

Two route-level meta flags. Defined on the route record, enforced in a global `beforeEach`.

```ts
// src/router/index.ts (lands in Phase 3)
const routes = [
  { path: '/', component: HomePage },
  { path: '/cart', component: CartPage, meta: { requiresAuth: true } },
  { path: '/login', component: LoginPage, meta: { guestOnly: true } },
  // …
];

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return { path: '/login', query: { next: to.fullPath } };
  }
  if (to.meta.guestOnly && auth.isLoggedIn) {
    return { path: '/' };
  }
});
```

## `?next=` preservation

Login-gated CTAs must round-trip the user back to where they were.

- Guest hits `LOGIN TO BUY` on `/products/abc123` → `router.push({ path: '/login', query: { next: '/products/abc123' } })`.
- After successful login → `router.push(route.query.next ?? '/')`.
- Same after register.

The `next` value is always a path, never an absolute URL — defend against open-redirect on `next` (allow only paths starting with `/`).

## Login-gated cart (v1 design)

The backend `/order-service/v1/shopping-carts` requires `AUTHORIZED`. **No guest cart in v1.**

- Anonymous users see "LOGIN TO BUY" on PDP, never an "ADD TO CART" button.
- Cart route `/cart` redirects guests to `/login?next=/cart`.
- Trade-off: simpler code, fewer states, fewer edge cases. Revisit if conversion data demands.

## 401 handling

Two levels of defence:

1. **Route guard** — read `useAuthStore.isLoggedIn` synchronously. Cheap pre-check.
2. **Interceptor** — every API call passes through `src/api/client.ts`. On 401, the interceptor:
   - Clears `useAuthStore` (and `localStorage`).
   - Calls `router.replace({ path: '/login', query: { next: route.fullPath } })`.

Why both? The guard handles "stale tab where token expired hours ago". The interceptor catches "token revoked server-side mid-session".

## No refresh-token rotation in v1

The current design treats 401 as terminal: clear store, redirect to login. This is acceptable if the backend issues hour-plus access tokens. If tokens are short-lived (<15 min), users will be kicked mid-session — escalate to v1.5 for refresh-token flow.

## Multi-tab logout sync

Pinia subscribes to `window`'s `storage` event. If `aibles.auth` is removed in tab A, tab B clears its store immediately. Tab B's next API call gets 401 (or the in-memory clear already redirected) → login.

```ts
// src/stores/auth.ts (lands in Phase 3)
window.addEventListener('storage', (e) => {
  if (e.key === 'aibles.auth' && e.newValue === null) {
    useAuthStore().clear();
  }
});
```

## PayPal redirect

PayPal sends users to FE URLs after approval/cancel:

- `http://localhost:5173/payment/success?orderId=…`
- `http://localhost:5173/payment/cancel?orderId=…`

`PaymentResultPage` is **public** — at the moment of redirect the user has just left a third-party domain and may not have an active session in this tab. The page polls `useOrderQuery(orderId)` until `status === "PAID"` (or 10 attempts).

Backend coordination — see Open Follow-up #1 in the design spec for the PayPal config change required.

## Hard rules

- **Never** read auth state by parsing the JWT in business code. The store is the source of truth (it parses once at login).
- **Never** put `requiresAuth` logic inside a component (`if (!auth.isLoggedIn) router.push(…)`). Use route meta.
- `next` must be a path. Strip absolute URLs.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/06-routing-auth.md
git commit -m "docs(frontend): add 06-routing-auth — guards, ?next, login-gated cart"
```

---

## Task 18: Doc 07 — Testing conventions (`docs/07-testing-conventions.md`)

**Files:**
- Create: `frontend/docs/07-testing-conventions.md`

- [ ] **Step 1: Write the file**

```markdown
# Testing conventions

No coverage % gate. **Test what matters**: every Zod schema (happy + sad), every page (happy render), every optimistic mutation (rollback path), every error class (mapping).

## Layers

| Layer | Tool | Lives in | What it tests |
|---|---|---|---|
| Unit | Vitest | `tests/unit/` | Pure functions: Zod schemas, format helpers, `apiError` classifier, store reducers |
| Component | @testing-library/vue + Vitest | `tests/unit/` (colocated by topic) | Primitives + domain components — render, props, events, a11y semantics |
| Page | @testing-library/vue + MSW + Vitest | `tests/unit/pages/` | Page renders + key flows (login error path, optimistic cancel rollback, debounced search) |
| E2E | Playwright | `tests/e2e/` | 2 golden paths: public browse → PDP; register → cart → checkout (PayPal stubbed) → orders → cancel |

## What goes where

- **Don't** unit-test things that have no logic (a tagless presentational primitive's "renders slot content" test is noise — instead test the variant prop changes the class).
- **Do** unit-test every Zod schema with valid + invalid inputs.
- **Do** test every optimistic mutation's rollback (mock 409, assert UI flips back).
- **Do** test the API error classifier's full taxonomy mapping (one test per class).
- E2E: only the two named golden paths. More e2e = slow CI = flaky.

## File naming

```
tests/unit/sanity.spec.ts
tests/unit/lib/zod-schemas.spec.ts
tests/unit/api/error-classifier.spec.ts
tests/unit/components/primitives/BButton.spec.ts
tests/unit/pages/LoginPage.spec.ts
tests/e2e/browse.spec.ts
tests/e2e/buy.spec.ts
```

`*.spec.ts` for tests. Mirror `src/` paths under `tests/unit/`.

## MSW — request mocking

MSW handlers live in `tests/handlers/` (one file per resource, mirroring `src/api/queries/`). Imported by both unit/page tests and CI-mode Playwright.

```ts
// tests/handlers/products.ts (lands in Phase 4)
import { http, HttpResponse } from 'msw';
import { productListFixture } from '../fixtures/products';

export const productsHandlers = [
  http.get('/api/bff-service/v1/products', () =>
    HttpResponse.json({ status: 'OK', code: '200', message: '', data: productListFixture }),
  ),
];
```

## Fixtures

Fixtures in `tests/fixtures/` are **parsed through Zod schemas at construction**. Drift between FE types and backend shapes fails the fixture parse fast.

```ts
// tests/fixtures/products.ts (lands in Phase 4)
import { productSchema } from '@/lib/zod-schemas';
export const productListFixture = [
  productSchema.parse({ id: 'abc', name: 'Issue Nº01 Tote', price: 39, /* … */ }),
];
```

If you change the schema, fixtures break — that's the point.

## Component test shape

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BButton from '@/components/primitives/BButton.vue';

describe('BButton', () => {
  it('renders default slot', () => {
    render(BButton, { slots: { default: 'BUY NOW' } });
    expect(screen.getByRole('button')).toHaveTextContent('BUY NOW');
  });

  it('applies variant class', () => {
    render(BButton, { props: { variant: 'spot' }, slots: { default: 'X' } });
    expect(screen.getByRole('button').className).toContain('b-button--spot');
  });
});
```

## Page test shape

```ts
import { describe, expect, it } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { setupServer } from 'msw/node';
import { authHandlers } from '../../handlers/auth';
// … MSW setup, router stub, query client

describe('LoginPage', () => {
  it('shows inline error on invalid credentials', async () => {
    render(LoginPage, { /* … */ });
    await user.type(screen.getByLabelText(/email/i), 'no@one.com');
    await user.type(screen.getByLabelText(/password/i), 'wrong');
    await user.click(screen.getByRole('button', { name: /log in/i }));
    await waitFor(() => {
      expect(screen.getByText(/wrong email or password/i)).toBeInTheDocument();
    });
  });
});
```

## E2E run modes

- **Local**: `pnpm test:e2e` — hits real backend (`make up` required).
- **CI**: Playwright with MSW served in-page, no backend dependency. Runs on every PR.

## What's deferred

- Storybook + visual regression
- axe-core a11y suite (manual checklist in `09-a11y-checklist.md` for now)
- Coverage % gates
- Lighthouse budgets in CI

## Hard rules

- **TDD for non-trivial logic.** Schemas, classifiers, optimistic mutations get tests first.
- **Don't mock what you can fixture.** A real Zod-parsed fixture beats a `jest.fn()`.
- **Avoid testing implementation.** Test what the user sees: rendered text, role, behavior.
- **No snapshot tests.** They rot fast and don't enforce intent.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/07-testing-conventions.md
git commit -m "docs(frontend): add 07-testing-conventions — layers, MSW, fixtures"
```

---

## Task 19: Doc 08 — Copy & voice (`docs/08-copy-and-voice.md`)

**Files:**
- Create: `frontend/docs/08-copy-and-voice.md`

- [ ] **Step 1: Write the file**

```markdown
# Copy & voice — Issue Nº01

The storefront reads like a printed risograph zine catalog. Copy is the second-loudest expression of that identity (after type). Words count.

## Voice

- **Present tense, declarative.** "Loading." not "Just a moment, we're loading the products for you!"
- **Condensed and concrete.** "0 lots." beats "There are no products available at this time."
- **Title case for stamps and CTAs, sentence case for body.** Exception: page numerals and section headers are SCREAMING CAPS.
- **Mono font for IDs, prices, timestamps, kicker labels.** Body font for human prose.
- **Never sentimental.** No "Oops!", "Whoops!", "Looks like…", "We're sorry but…".
- **Print-shop voice over tech voice.** "Pressed" not "Submitted". "Out of stock" stamps as "SOLD OUT".

The voice is **printer-shop deadpan**. Like the kind of text you'd see on a packing slip from a small-batch zine maker.

## Copy bank

### Empty states

| Where | Copy |
|---|---|
| Empty product catalog | "Issue Nº01 coming soon." |
| Empty cart | "Your cart is empty. Browse the lots." |
| Empty orders | "No orders yet. Start at issue one." |
| Empty search results | "No matches for «{query}». Try another lot number." |

### Loading states

| Where | Copy |
|---|---|
| Skeleton card label (a11y only) | "Loading lot." |
| Submit-pending button | "STAMPING…" |
| Payment-verifying stamp | "VERIFYING…" |
| Saga/pollin'-for-paid | "AWAITING IMPRESSION…" |

No spinners. Skeleton cards or stamp animations only.

### Error states

Match the API error taxonomy in [`04-api-conventions.md`](./04-api-conventions.md).

| Class | Default copy |
|---|---|
| `auth-required` | (silent — redirect) |
| `forbidden` | "Not allowed." |
| `not-found` (route) | "404 — lot not found." |
| `not-found` (component) | "Nothing here." |
| `validation` (form, fallback) | server-provided message |
| `server` | "Server error. Try again." |
| `network` | "Connection lost. Retry?" |

### Status stamps

Order status renders as `<BStamp>`. Copy is uppercase, mono.

| Status | Stamp |
|---|---|
| PROCESSING | "PROCESSING" |
| PAID | "PAID" |
| SHIPPED | "SHIPPED" |
| DELIVERED | "DELIVERED" |
| CANCELED | "CANCELED" |
| FAILED | "FAILED" |

Inventory:

| Inventory | Stamp |
|---|---|
| > 10 | "IN STOCK" |
| 1–10 | "LOW STOCK" |
| 0 | "SOLD OUT" |

### CTAs

Always uppercase, present-tense imperative.

| Action | Copy |
|---|---|
| Add to cart (logged in) | "ADD TO CART" |
| Add to cart (guest) | "LOGIN TO BUY" |
| Place order | "PLACE ORDER" → "STAMPING…" |
| Retry payment | "RETRY PAYMENT" |
| Cancel order | "CANCEL ORDER" |
| Log in | "LOG IN" |
| Register | "REGISTER" |
| Log out | "LOG OUT" |
| View order | "VIEW ORDER" |

### Toasts

Toasts are short. One sentence, no period required.

| Trigger | Copy |
|---|---|
| Add-to-cart success | "Added to cart" |
| Cancel-order conflict 409 | "Already canceled — refreshed." |
| Server 5xx | "Server error — try again" |
| Network error | "Connection lost" |
| Logout in another tab (this tab notices) | "Signed out in another tab" |

## Hard rules

- New screen → add its empty / loading / error / CTA copy here before merging.
- Banned words: "Oops", "Whoops", "Sorry", "We", "Our team", "Please", "Just".
- ID-like strings (order IDs, SKUs, prices, timestamps) render in `var(--font-mono)`.
- If you find yourself writing a complete sentence inside a button, stop.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/08-copy-and-voice.md
git commit -m "docs(frontend): add 08-copy-and-voice — Issue Nº01 voice + copy bank"
```

---

## Task 20: Doc 09 — A11y checklist (`docs/09-a11y-checklist.md`)

**Files:**
- Create: `frontend/docs/09-a11y-checklist.md`

- [ ] **Step 1: Write the file**

```markdown
# Accessibility checklist

Issue Nº01 is loud, but accessibility is non-negotiable. The brutalist look already helps (high contrast, big type, hard focus rings). What follows is the full per-screen checklist. Run through it before merging any screen.

## Targets

| Concern | Target |
|---|---|
| Color contrast (text on background) | WCAG AA (≥ 4.5:1 normal, ≥ 3:1 large ≥ 18.66 px) |
| Color contrast (UI components, focus indicators) | WCAG AA (≥ 3:1) |
| Keyboard navigation | Every interactive element reachable + operable via keyboard |
| Focus visible | Always. `:focus-visible` outline, never `outline: none` without replacement |
| Reduced motion | Respect `prefers-reduced-motion: reduce` |
| Screen reader | Landmarks + labels + live regions |

## Per-screen checklist

For each screen, verify:

- [ ] **Tab order** flows top-to-bottom, left-to-right, no traps (except dialogs).
- [ ] **Focus indicator** is the orange `--spot` ring, never invisible.
- [ ] **Skip link** to main content (where header is heavy).
- [ ] **Headings** are semantic (`h1` once, `h2`/`h3` for sections — not styled `<div>`s).
- [ ] **Landmarks**: `<header>`, `<nav>`, `<main>`, `<footer>` present and unique.
- [ ] **Images** have `alt` (descriptive for product images, `alt=""` for decorative).
- [ ] **Form fields** have visible labels (not just placeholder).
- [ ] **Error messages** are `aria-live="polite"` or wired to the field's `aria-describedby`.
- [ ] **Buttons** have a discernible name (text or `aria-label`).
- [ ] **Status changes** (toast, stamp flips) announced to screen readers via `role="status"` or `aria-live`.

## Component-level rules

### `BButton`

- Native `<button>` element. Not a styled `<div>`.
- `:focus-visible` outline: 3px solid `--spot`, offset 2px. (Already in `tokens.css` recipe.)
- Disabled state: `aria-disabled="true"` + `disabled` attr; greyscale via `--muted-ink`.
- Variant `spot` text on orange — verified ≥ 4.5:1 against ink. (Yes — `#1C1C1C` on `#FF4F1C` ≈ 5.6:1.)

### `BInput`

- Pair with a `<label for>` — never label-by-placeholder.
- Error state: red border + `aria-invalid="true"` + error text linked via `aria-describedby`.
- Focus: orange ring + 2 px shift (the misregistration motif).

### `BDialog`

- Reka UI primitive — focus trap and Esc-to-close come for free.
- First focusable element receives focus on open.
- Returns focus to the trigger on close.
- `aria-labelledby` points at the dialog title.
- Backdrop click closes.

### `BSelect`

- Reka UI primitive — keyboard arrow navigation built in.
- Selected option visible, no ambiguous "click to expand" pattern.

### `BToast`

- `role="status"` (auto-dismiss, non-blocking) or `role="alert"` (errors).
- Auto-dismiss after 4 s for non-errors, 8 s for errors. User can dismiss earlier.
- Don't pile toasts — max 3 visible, queue extras.

### `BStamp`

- Decorative when paired with text (`aria-hidden="true"` on the stamp, status text in adjacent label).
- Standalone (e.g. order status without explicit text) → `role="img"` with `aria-label="Status: PAID"`.

## Color contrast cheat sheet

Pre-checked against `--ink` `#1C1C1C` (almost black).

| Background | Text | Ratio | Verdict |
|---|---|---|---|
| `--paper` `#F4EFE6` | `--ink` | 12.5:1 | AAA |
| `--paper-shade` `#E8DFD0` | `--ink` | 11.0:1 | AAA |
| `--spot` `#FF4F1C` | `--ink` | 5.6:1 | AA |
| `--spot` | `--paper` | 2.2:1 | **FAIL — never put paper text on orange** |
| `--ink` | `--paper` | 12.5:1 | AAA |
| `--stamp-red` `#C4302B` | `--paper` | 5.4:1 | AA |
| `--muted-ink` `#6B6256` | `--paper` | 5.0:1 | AA |
| `--muted-ink` | `--paper-shade` | 4.5:1 | AA (just) |

If you introduce a new pairing, verify with a checker (e.g. https://contrastchecker.com).

## Reduced motion

Respect `prefers-reduced-motion: reduce`. The brutalist press is fun but not essential.

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

(Add to `main.css` when motion-rich primitives ship in Phase 2.)

## Manual sweep before merging

For each new screen, do a 60-second manual sweep:

1. Tab through every interactive element. Focus visible? Logical order?
2. Hit the screen with `prefers-reduced-motion: reduce`. Still usable?
3. Open DevTools → toggle "Emulate vision deficiencies" → protanopia. Still readable?
4. Resize to 320 px width. No horizontal scroll, no clipped content.
5. (When axe-core is wired) Run axe — zero violations.

## Hard rules

- **Never** `outline: none` without a replacement focus indicator.
- **Never** color alone for state (error red has icon/text, success green has check).
- **Never** label-by-placeholder.
- **Never** trap focus outside a dialog/modal.
- **Always** keyboard-first when designing — if you can't tab to it, it's broken.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/09-a11y-checklist.md
git commit -m "docs(frontend): add 09-a11y-checklist — keyboard, focus, contrast"
```

---

## Task 21: ADR 0001 — Vue 3 framework

**Files:**
- Create: `frontend/docs/adr/0000-template.md`
- Create: `frontend/docs/adr/0001-framework-vue3.md`

- [ ] **Step 1: Create the ADR template** (`frontend/docs/adr/0000-template.md`)

```markdown
# NNNN — Title

**Status:** Accepted | Proposed | Deprecated | Superseded by NNNN
**Date:** YYYY-MM-DD

## Context

What problem are we solving? What forces are at play?

## Decision

What did we pick? In one or two sentences.

## Alternatives considered

| Option | Why not |
|---|---|
| Option A | Reason |
| Option B | Reason |

## Consequences

Positive and negative trade-offs we accept.
```

- [ ] **Step 2: Create `frontend/docs/adr/0001-framework-vue3.md`**

```markdown
# 0001 — Framework: Vue 3 + Vite + TypeScript

**Status:** Accepted
**Date:** 2026-05-01

## Context

We need a frontend framework for a single-page storefront against an existing microservice backend. Constraints: learning project, single owner, type-safety required, fast dev loop, plays well with Tailwind.

## Decision

**Vue 3** (Composition API + `<script setup>`) with **Vite** and **TypeScript** strict mode.

## Alternatives considered

| Option | Why not |
|---|---|
| React + Vite | Bigger ecosystem, but ergonomics for this scope are heavier (more boilerplate, more decisions per component, JSX vs template religious wars). The owner has Vue background. |
| SvelteKit | Smaller bundle, lovely DX, but library breadth (forms, query, headless UI) is thinner than Vue's, and SSR is a Phase-N concern out of scope for v1. |
| Next.js / Nuxt | SSR is a non-goal (see design spec). Nuxt would be a strong v1.5 path; v1 stays SPA. |

## Consequences

- Native Vite integration. Fastest dev loop available.
- Strong-typed templates via `vue-tsc`.
- Single-file components keep CSS, template, and logic colocated — fits Issue Nº01's tight per-component aesthetics.
- Smaller library ecosystem than React for niche needs (e.g. Reka UI for headless a11y is younger than Radix).
- TanStack and Zod work first-class in Vue 3.
```

- [ ] **Step 3: Commit**

```bash
git add frontend/docs/adr/0000-template.md frontend/docs/adr/0001-framework-vue3.md
git commit -m "docs(frontend): ADR template + 0001 framework Vue 3"
```

---

## Task 22: ADR 0002 — TanStack Vue Query (server state)

**Files:**
- Create: `frontend/docs/adr/0002-server-state-tanstack-query.md`

- [ ] **Step 1: Create the file**

```markdown
# 0002 — Server state: TanStack Vue Query

**Status:** Accepted
**Date:** 2026-05-01

## Context

The app reads/writes against ~10 backend endpoints. We need: caching, background refetch, retry policy, optimistic mutations, stale-while-revalidate, request deduping, devtools. Building this on top of plain `fetch` + Pinia would mean reinventing every primitive of a query library.

## Decision

**`@tanstack/vue-query`** for all server state. Pinia is reserved for client state (auth + UI) only.

## Alternatives considered

| Option | Why not |
|---|---|
| Pinia + composables only | Reinvents caching, invalidation, dedup, retry. Months of bugs to recover what TanStack ships day-1. |
| SWR for Vue | Less mature, smaller community than TanStack. |
| Apollo Client | We don't have GraphQL. |

## Consequences

- Hierarchical cache keys give surgical invalidation (`["products"]` vs `["products", id]`).
- Optimistic mutations (cancel order, qty stepper) are first-class.
- Devtools in dev are fantastic.
- Bundle adds ~12 kB gzip — acceptable for the value.
- Clear boundary: server data flows through queries, never through Pinia. This is enforced in [`docs/04-api-conventions.md`](../04-api-conventions.md).
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0002-server-state-tanstack-query.md
git commit -m "docs(frontend): ADR 0002 server state TanStack Vue Query"
```

---

## Task 23: ADR 0003 — Pinia (client state)

**Files:**
- Create: `frontend/docs/adr/0003-client-state-pinia.md`

- [ ] **Step 1: Create the file**

```markdown
# 0003 — Client state: Pinia (auth + UI only)

**Status:** Accepted
**Date:** 2026-05-01

## Context

We have client-side state that isn't server data: auth token + decoded identity, toast queue, modal stack, UI theming knobs. We need a store with persistence (auth survives reload), devtools, and TS inference.

## Decision

**Pinia** for client state. Two stores: `useAuthStore` (token, user, role; persisted to `localStorage`) and `useUiStore` (toasts, modals).

**Server data does NOT live in Pinia.** That's TanStack Query's job (see ADR 0002).

## Alternatives considered

| Option | Why not |
|---|---|
| Vuex 4 | Officially superseded by Pinia. |
| Composables-only (`useAuth()` with `ref`s) | Loses `localStorage` persistence wiring + Vue DevTools integration. Possible, but reinventing what Pinia ships. |
| Zustand-style external store | Would work, but Pinia is the Vue-idiomatic answer with first-class DevTools. |

## Consequences

- Strong boundary: anything that came from the API → query. Anything else → Pinia. This boundary is enforced in [`docs/01-architecture.md`](../01-architecture.md).
- `localStorage` persistence is hand-wired (small, fits the auth use case). No `pinia-plugin-persistedstate` dependency.
- Multi-tab sync: Pinia subscribes to `storage` event for `aibles.auth` key.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0003-client-state-pinia.md
git commit -m "docs(frontend): ADR 0003 client state Pinia"
```

---

## Task 24: ADR 0004 — openapi-typescript + openapi-fetch

**Files:**
- Create: `frontend/docs/adr/0004-api-client-openapi-fetch.md`

- [ ] **Step 1: Create the file**

```markdown
# 0004 — API client: openapi-typescript + openapi-fetch

**Status:** Accepted
**Date:** 2026-05-01

## Context

The backend gateway aggregates Swagger from all microservices at `/v3/api-docs`. We want type-safe API calls without a heavyweight client generator (large bundle, maintenance burden, mismatch with our error envelope). The runtime client must be tiny (we're shipping a learning-scope SPA).

## Decision

- **`openapi-typescript`** for ahead-of-time type generation: `pnpm api:gen` produces `src/api/schema.d.ts`.
- **`openapi-fetch`** for the runtime client (~3 kB minzip). Uses the generated types for full request/response inference.

## Alternatives considered

| Option | Why not |
|---|---|
| `axios` + hand-written types | No type safety from the OpenAPI spec; types drift from backend. |
| `Orval` (codegen for queries + types) | Generates an entire client + react-query layer, but for Vue + our custom envelope it's awkward. Heavier output. |
| `tRPC` | Backend isn't tRPC. Out of scope. |
| Hand-rolled fetch wrapper | Loses type safety; reinvents what `openapi-fetch` does in 3 kB. |

## Consequences

- The `BaseResponse { status, code, message, data }` envelope is unwrapped in `src/api/client.ts` interceptor — so callers see `data` directly while still getting OpenAPI-derived types.
- `pnpm api:gen` must be run when backend OpenAPI changes. Can be wired into CI as a check (Phase 3+).
- Tiny runtime — no bundle bloat.
- Type errors surface at compile time when backend signatures drift.

## Generation pipeline

```
backend gateway /v3/api-docs ──→  openapi-typescript ──→  src/api/schema.d.ts
                                                            │
                                          ▲
                                          │ openapi-fetch<paths>()
                                          │
                                src/api/client.ts (singleton)
                                          │
                                src/api/queries/* (the boundary)
```

Defined in detail in [`docs/04-api-conventions.md`](../04-api-conventions.md).
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0004-api-client-openapi-fetch.md
git commit -m "docs(frontend): ADR 0004 API client openapi-fetch"
```

---

## Task 25: ADR 0005 — VeeValidate + Zod

**Files:**
- Create: `frontend/docs/adr/0005-forms-veevalidate-zod.md`

- [ ] **Step 1: Create the file**

```markdown
# 0005 — Forms: VeeValidate + Zod

**Status:** Accepted
**Date:** 2026-05-01

## Context

We need form validation (login, register, address at checkout). We also need to parse API responses safely (since OpenAPI types are compile-time and don't enforce shape at runtime). Defining schemas twice — once for the form, once for the API parser — is duplication waiting to drift.

## Decision

- **Zod** for schemas, defined once in `src/lib/zod-schemas.ts`.
- **VeeValidate** for form state, error tracking, and submission, with `@vee-validate/zod`'s `toTypedSchema` adapter.
- Same schemas validate forms AND parse API responses (in `src/api/queries/`).

## Alternatives considered

| Option | Why not |
|---|---|
| Vuelidate | Less idiomatic with Composition API; weaker TS inference; harder to share with API parsing. |
| FormKit | All-in-one (renders fields too) — too opinionated for a brutalist visual identity. |
| React-Hook-Form-style (manual + Zod resolver) | Possible but VeeValidate is the Vue-native answer with the same DX. |
| Yup | Less ergonomic in TS than Zod; no `z.infer` equivalent. |

## Consequences

- One source of truth for shape. Backend changes the password rule → one file changes → both forms and API parsers update.
- Server-side validation errors map to inline form errors via VeeValidate's `setErrors({ field })`. (Convention in [`docs/05-form-conventions.md`](../05-form-conventions.md).)
- Zod adds ~9 kB gzip — acceptable for the runtime safety it buys.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0005-forms-veevalidate-zod.md
git commit -m "docs(frontend): ADR 0005 forms VeeValidate + Zod"
```

---

## Task 26: ADR 0006 — Tailwind v4 + custom tokens

**Files:**
- Create: `frontend/docs/adr/0006-styling-tailwind-tokens.md`

- [ ] **Step 1: Create the file**

```markdown
# 0006 — Styling: Tailwind v4 + custom tokens, hand-rolled primitives

**Status:** Accepted
**Date:** 2026-05-01

## Context

The Issue Nº01 visual identity is opinionated: specific palette, specific type stack, hard-offset shadows, mechanical motion. Off-the-shelf component libraries (shadcn-vue, Naive UI, Element Plus) have generic aesthetics that we'd fight on every component. We also want speed — utilities for layout, spacing, responsive — without writing CSS for every gap.

## Decision

- **Tailwind v4** for layout, spacing, responsive utilities, colour utilities driven by token CSS vars (`@theme` block).
- **CSS custom properties** in `src/styles/tokens.css` as the single source of truth for palette, type, shadows, motion.
- **Hand-rolled primitives** (`B*` components) — no off-the-shelf component library for visuals. **Reka UI** (formerly Radix Vue) is used only for behaviour-heavy a11y primitives (Dialog, Select, Popover) — they're headless and don't fight our design.

## Alternatives considered

| Option | Why not |
|---|---|
| shadcn-vue | Beautiful default look, but defaults are exactly what we don't want — we'd override every Tailwind class. The component shapes don't match Issue Nº01 (badges aren't stamps, dialogs aren't paper). |
| Naive UI / Element Plus | Heavy CSS-in-JS theming, hard to bend to risograph aesthetics. |
| Pure CSS-Modules + no Tailwind | Slower iteration on layout/spacing. |
| Vanilla Extract | Adds a build step. |

## Consequences

- Every visual primitive is ours. Total control of feel and motion.
- Tailwind utilities cover 70 % of layout. Tokens + scoped CSS cover the brand.
- Reka UI gives us free focus traps + keyboard support for Dialog / Select / Popover.
- New colour or motion value? Add a token in `tokens.css`. Hard-coded hex outside that file is a review-block.
- Primitive count is bounded (10 — see design spec). When that list closes, no library would have served us better.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0006-styling-tailwind-tokens.md
git commit -m "docs(frontend): ADR 0006 styling Tailwind + tokens + hand-rolled primitives"
```

---

## Task 27: ADR 0007 — Vue Router

**Files:**
- Create: `frontend/docs/adr/0007-routing-vue-router.md`

- [ ] **Step 1: Create the file**

```markdown
# 0007 — Routing: Vue Router 4 with route guards

**Status:** Accepted
**Date:** 2026-05-01

## Context

SPA routing for ~9 paths, with auth-required and guest-only flavours, deep-link support (`/orders?selected=ORD123`), and PayPal redirect handling on `/payment/success` and `/payment/cancel`.

## Decision

**Vue Router 4** — the canonical Vue routing solution. Auth enforced via route `meta.requiresAuth` / `meta.guestOnly` flags + a global `beforeEach` guard. `?next=` query param round-trips users back through login. (Full conventions in [`docs/06-routing-auth.md`](../06-routing-auth.md).)

## Alternatives considered

| Option | Why not |
|---|---|
| Unplugin-vue-router (file-based) | Cool DX but adds a build-time generator and obscures the route table. Our route count is small enough for an explicit file. |
| Nuxt | SSR is a non-goal. |
| Custom hash routing | No history API integration, breaks deep-linking + share-ability. |

## Consequences

- Single explicit `routes` array makes auth audit simple — grep for `requiresAuth: true`.
- Route guards centralise the auth check; pages don't reimplement it (banned by convention).
- 401 handling is dual-layered (guard + interceptor) — see `docs/06-routing-auth.md`.
- `?next` is a path (not absolute URL); we strip absolute URLs to defend against open-redirect.
```

- [ ] **Step 2: Commit**

```bash
git add frontend/docs/adr/0007-routing-vue-router.md
git commit -m "docs(frontend): ADR 0007 routing Vue Router"
```

---

## Task 28: Final DoD verification + foundation PR

This task runs every DoD bullet from the rollout spec end-to-end. It's a final guard — nothing in Phase 1 is "done" until every box below is checked.

**Files:** none created. Verification only.

- [ ] **Step 1: Clean clone simulation — `pnpm install && pnpm typecheck && pnpm lint && pnpm test`**

```bash
cd frontend
rm -rf node_modules dist coverage
pnpm install
pnpm typecheck
pnpm lint
pnpm test
```

Expected: each command exits 0. No errors. Tests show 5 passed.

- [ ] **Step 2: Verify dev server + placeholder page renders**

```bash
cd frontend && pnpm dev
```

Open `http://localhost:5173/`. Manually verify:

- [ ] Background is `#F4EFE6` (paper)
- [ ] Title "FOUNDATION LAID." renders in Bricolage 900 with orange offset shadow (`#FF4F1C`)
- [ ] Outlined hollow "01" numeral visible
- [ ] Departure Mono visible in kicker + colophon
- [ ] DevTools console shows zero errors / warnings (excluding Vue's dev mode banner)
- [ ] DevTools Network tab shows all 4 `.woff2` files returning 200

Stop server.

- [ ] **Step 3: Verify all 10 docs exist and are non-empty**

```bash
for f in 00-readme 01-architecture 02-design-tokens 03-component-conventions 04-api-conventions 05-form-conventions 06-routing-auth 07-testing-conventions 08-copy-and-voice 09-a11y-checklist; do
  test -s "frontend/docs/$f.md" && echo "OK $f" || echo "MISSING $f"
done
```

Expected: 10 lines each saying "OK ...".

- [ ] **Step 4: Verify ≥ 7 ADRs exist**

```bash
ls frontend/docs/adr/*.md | grep -v 0000-template | wc -l
```

Expected: `7` (or higher).

- [ ] **Step 5: Verify pre-commit hook blocks a deliberate lint error**

Append a deliberate failure to `frontend/src/main.ts`:

```ts
const blocked_by_hook_test = 'this should be blocked';
```

```bash
git add frontend/src/main.ts
git commit -m "test: should be rejected by pre-commit"
```

Expected: commit is rejected by ESLint via lint-staged.

Revert:

```bash
git restore --staged frontend/src/main.ts
git checkout frontend/src/main.ts
```

- [ ] **Step 6: Run a Lighthouse audit on the placeholder page (manual)**

```bash
cd frontend && pnpm dev
```

In Chrome DevTools → Lighthouse → "Analyze page load" with default categories. Verify:

- [ ] Console errors: 0
- [ ] Network requests: 0 with status ≥ 400 (no 404s)

(Performance/A11y/Best Practices scores are not gated in Phase 1 — Phase 7 sets numeric targets. We just need a clean console.)

Stop server.

- [ ] **Step 7: Push branch + open PR + verify CI green**

```bash
# Assume work was done on a feature branch. If on main:
git switch -c feat/frontend-phase-1-foundation 2>/dev/null || true
git push -u origin feat/frontend-phase-1-foundation
gh pr create --title "frontend: phase 1 — Foundation & Documentation" --body "$(cat <<'EOF'
## Summary

Phase 1 of the storefront frontend rollout. Docs-first foundation — scaffold + 10 conventions docs + 7 ADRs + tooling. No UI features yet.

## Definition of Done

- [x] `pnpm install && pnpm typecheck && pnpm lint && pnpm test` exit 0
- [x] `pnpm dev` shows the Issue Nº01 placeholder using `--paper`, `--ink`, `--spot` and Bricolage display font
- [x] All 10 docs exist and non-empty under `frontend/docs/`
- [x] ≥ 7 ADRs under `frontend/docs/adr/`
- [x] Pre-commit hook blocks deliberate lint failure (verified locally)
- [x] Lighthouse audit on placeholder page: zero console errors, zero 404s
- [ ] CI workflow green (verified after this PR opens)

## What's NOT in this phase

No primitives, no pages with logic, no API integration, no auth flow. Those land in Phases 2-6 per the rollout spec.

## Refs

- Design: `docs/superpowers/specs/2026-05-01-storefront-frontend-design.md`
- Rollout: `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md`
- Plan: `docs/superpowers/plans/2026-05-01-storefront-frontend-phase1.md`
EOF
)"
```

Watch CI:

```bash
gh pr checks --watch
```

Expected: `frontend / verify` job passes (typecheck + lint + test all green).

- [ ] **Step 8: Tick the final DoD bullet in this plan + the rollout doc**

Once CI is green, edit `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` and tick the Phase 1 DoD bullets.

```bash
# Open the file and flip each `- [ ]` to `- [x]` under "Phase 1 — Foundation & Documentation › Definition of Done".
# Then commit + push:
git add docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md
git commit -m "docs: tick Phase 1 DoD bullets — foundation complete"
git push
```

Phase 1 is **done** only when every checkbox above is ticked and CI is green on the foundation PR. Phase 2 planning starts in a fresh session.

---

## Self-review notes

This plan was written against `docs/superpowers/specs/2026-05-01-storefront-frontend-design.md` and `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md`.

**Spec coverage check (Phase 1 scope from rollout spec):**

- [x] Vite + Vue 3 + TS + Tailwind v4 scaffold under `frontend/` → Tasks 1, 4
- [x] ESLint + Prettier + TS strict + Vitest config → Tasks 2, 3
- [x] Pre-commit hook (lint + typecheck on staged files) → Task 9
- [x] CI workflow `.github/workflows/frontend.yml` → Task 10
- [x] Folder skeleton with `.gitkeep` → Task 7
- [x] `tokens.css` with all design tokens → Task 6
- [x] Self-hosted fonts wired → Task 5
- [x] Single placeholder index page proving tokens render → Task 8
- [x] Documentation `00-readme` through `09-a11y-checklist` → Tasks 11-20
- [x] ≥ 7 ADRs → Tasks 21-27
- [x] DoD verification covered → Task 28

**Type-consistency check:** Token names, file paths, and convention names are referenced consistently across docs (e.g. `tokens.css`, `BButton`, `--spot`, `useAuthStore`, `src/api/queries/`).

**Placeholder scan:** No "TBD", "implement later", or "similar to" references. Each task is self-contained with concrete content.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-01-storefront-frontend-phase1.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec compliance, then code quality), fast iteration.
2. **Inline Execution** — execute tasks in this session via `superpowers:executing-plans`, batch with checkpoints.

Which approach?
