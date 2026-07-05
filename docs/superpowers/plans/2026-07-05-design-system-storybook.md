# Design System SSOT — Storybook Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate the frontend's fragmented design-system docs into Storybook 9 as the single source of truth, keeping the Issue Nº01 aesthetic and `tokens.css` unchanged, plus a project-scoped `/design-system` skill so agents query it from source.

**Architecture:** Storybook (`@storybook/vue3-vite`) becomes the one content home — Foundations (`.mdx` rendered from `tokens.css`), Primitive/Pattern stories (`.stories.ts`), and Guides (`.mdx`, the build playbook migrated from `docs/00-09`). `tokens.css` stays the machine token source and stories/foundations render *from* it so they can't drift. A committed `.claude/skills/design-system/` skill points agents at the story/MDX/token source — no MCP, no server. The built app is **not** re-skinned.

**Tech Stack:** Vue 3 (Composition API) · Vite 5.4 · Tailwind 4 (`@tailwindcss/postcss`) · TypeScript 5.8 · Storybook 9 (`@storybook/vue3-vite`) · reka-ui · Pinia · pnpm 9 · Node 20.

## Global Constraints

- **Package manager:** `pnpm` only (v9+). Never `npm`/`yarn`. Node ≥ 20.
- **Branch:** all work on `feat/design-system-storybook` (already created).
- **Aesthetic frozen:** do NOT edit any file under `frontend/src/components/**`, `frontend/src/styles/**`, or app pages. This project documents them; it never restyles them. The only exception is adding NEW `*.stories.ts` files beside components.
- **Token discipline:** never hard-code a hex or font in a story/MDX. Reference the running identity by importing the app CSS in the Storybook preview; name tokens as `var(--…)`.
- **MDX home:** Foundations and Guides live in `frontend/src/design-system/{foundations,guides}/*.mdx` (Storybook's default `src/**` glob picks them up; content lives with the app; the skill reads from this stable path).
- **Stories co-locate:** `X.vue` → `X.stories.ts` in the same directory.
- **Verification gate (this project's "test"):** `pnpm typecheck` (vue-tsc typechecks stories under `src/`) **and** `pnpm build-storybook` (compiles every story + MDX; a broken import/story fails the build). Both must pass before every commit. Where a story renders a component that needs Pinia, the story MUST install it (see Task 5).
- **Lint:** `eslint .` and the pre-commit `lint-staged` hook run on staged `.ts`/`.vue`. Stories must pass ESLint + Prettier.
- **Do NOT** add an MCP server, a hosted platform, or migrate tokens to DTCG JSON. Out of scope.

## File Structure

**Created:**
- `frontend/.storybook/main.ts` — Storybook config: framework, stories globs, addons, `@` alias.
- `frontend/.storybook/preview.ts` — global decorators + imports `tokens.css`/`fonts.css`/`main.css` so stories render in Issue Nº01.
- `frontend/src/components/primitives/*.stories.ts` — one per `B*` primitive (11).
- `frontend/src/components/**/*.stories.ts` — pattern stories for domain/layout components.
- `frontend/src/design-system/foundations/*.mdx` — Identity, Color, Typography, Spacing, BordersShadows, Motion, SignatureDetails.
- `frontend/src/design-system/guides/*.mdx` — Architecture, RoutingAuth, Api, Forms, Testing, CopyVoice, A11y.
- `.claude/skills/design-system/SKILL.md` — project-scoped query skill.
- `.claude/skills/design-system/scripts/list-stories.sh` — grep-based story/token lister (no build needed).

**Modified:**
- `frontend/package.json` — add Storybook devDeps + `storybook` / `build-storybook` scripts.
- `frontend/eslint.config.js` — add `eslint-plugin-storybook` flat config + ignore `storybook-static/`.
- `frontend/.gitignore` — ignore `storybook-static/`.
- `frontend/CLAUDE.md` — rewrite "Conventions"/"Where to look" to point at Storybook SSOT + the skill.

**Deleted (final task, after content migrated):**
- `frontend/docs/00-readme.md` … `frontend/docs/09-a11y-checklist.md` (10 files). `frontend/docs/adr/` is **kept** and linked from a Guide.

---

### Task 1: Install & configure Storybook 9, wired to Tailwind 4 + Issue Nº01

**Files:**
- Create: `frontend/.storybook/main.ts`, `frontend/.storybook/preview.ts`
- Modify: `frontend/package.json`, `frontend/eslint.config.js`, `frontend/.gitignore`
- Create (smoke): `frontend/src/components/primitives/BButton.stories.ts`

**Interfaces:**
- Produces: a working `pnpm storybook` (dev) and `pnpm build-storybook` (static). Preview globally imports `@/styles/tokens.css`, `@/styles/fonts.css`, `@/styles/main.css`. The `@` → `src` alias resolves inside stories.

- [ ] **Step 1: Install Storybook via its initializer**

Run (from `frontend/`):
```bash
pnpm dlx storybook@latest init --builder vite --type vue3 --package-manager pnpm --yes
```
This auto-detects Vue 3 + Vite, adds `@storybook/vue3-vite` + core addons to `devDependencies`, writes a starter `.storybook/main.ts` + `.storybook/preview.ts`, adds `storybook` / `build-storybook` scripts, and drops sample stories under `src/stories/`.

- [ ] **Step 2: Delete the generated sample stories**

Run:
```bash
rm -rf frontend/src/stories
```
Expected: the `src/stories/` sample folder (Button/Header/Page demos) is gone. We document real components, not the samples.

- [ ] **Step 3: Replace `.storybook/main.ts` with our config**

```ts
import type { StorybookConfig } from '@storybook/vue3-vite';
import { fileURLToPath, URL } from 'node:url';

const config: StorybookConfig = {
  stories: [
    '../src/**/*.mdx',
    '../src/**/*.stories.@(ts|tsx)',
  ],
  addons: [
    '@storybook/addon-docs',
    '@storybook/addon-a11y',
  ],
  framework: {
    name: '@storybook/vue3-vite',
    options: {},
  },
  viteFinal: async (cfg) => {
    cfg.resolve ??= {};
    cfg.resolve.alias = {
      ...(cfg.resolve.alias ?? {}),
      '@': fileURLToPath(new URL('../src', import.meta.url)),
    };
    return cfg;
  },
};

export default config;
```
Note: keep whatever addon package names the initializer actually installed — if it added `@storybook/addon-essentials` (which bundles docs) instead of `@storybook/addon-docs`, list that instead. Verify against `package.json` after Step 1.

- [ ] **Step 4: Replace `.storybook/preview.ts` to load the Issue Nº01 identity**

```ts
import type { Preview } from '@storybook/vue3';
import '@/styles/tokens.css';
import '@/styles/fonts.css';
import '@/styles/main.css';

const preview: Preview = {
  parameters: {
    backgrounds: {
      default: 'paper',
      values: [
        { name: 'paper', value: '#F4EFE6' },
        { name: 'ink', value: '#1C1C1C' },
      ],
    },
    controls: { expanded: true },
    a11y: { test: 'error' },
  },
};

export default preview;
```

- [ ] **Step 5: Write a smoke story for BButton**

`frontend/src/components/primitives/BButton.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BButton from './BButton.vue';

const meta = {
  title: 'Primitives/BButton',
  component: BButton,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['spot', 'ink', 'ghost', 'danger'] },
    type: { control: 'select', options: ['button', 'submit', 'reset'] },
    disabled: { control: 'boolean' },
    loading: { control: 'boolean' },
  },
  args: { variant: 'ink', disabled: false, loading: false },
  render: (args) => ({
    components: { BButton },
    setup: () => ({ args }),
    template: `<BButton v-bind="args">Add to cart</BButton>`,
  }),
} satisfies Meta<typeof BButton>;
export default meta;

type Story = StoryObj<typeof meta>;

export const Ink: Story = {};
export const Spot: Story = { args: { variant: 'spot' } };
export const Ghost: Story = { args: { variant: 'ghost' } };
export const Danger: Story = { args: { variant: 'danger' } };
export const Loading: Story = { args: { loading: true } };
```

- [ ] **Step 6: Add ESLint + gitignore for Storybook**

In `frontend/eslint.config.js`, add the Storybook plugin's flat config to the exported array (import at top: `import storybook from 'eslint-plugin-storybook';`) and spread `...storybook.configs['flat/recommended']`. Install it: `pnpm add -D eslint-plugin-storybook`. Add `storybook-static` to the ESLint `ignores` and to `frontend/.gitignore`.

- [ ] **Step 7: Verify build + typecheck + lint**

Run (from `frontend/`):
```bash
pnpm typecheck && pnpm build-storybook && pnpm lint
```
Expected: typecheck PASS, `build-storybook` writes `storybook-static/` with no errors, lint PASS. Then run `pnpm storybook` and confirm in the browser that **Primitives/BButton** renders with the riso-orange spot variant, hard offset shadow, and the press-snap on `:active` (i.e. `tokens.css` is loaded).

- [ ] **Step 8: Commit**

```bash
git add frontend/.storybook frontend/package.json frontend/pnpm-lock.yaml frontend/eslint.config.js frontend/.gitignore frontend/src/components/primitives/BButton.stories.ts
git commit -m "feat(design-system): stand up Storybook 9 wired to Issue Nº01 tokens"
```

---

### Task 2: Identity primitive stories — BStamp, BTag, BCard, BCropmarks, BMarginNumeral

**Files:**
- Create: `BStamp.stories.ts`, `BTag.stories.ts`, `BCard.stories.ts`, `BCropmarks.stories.ts`, `BMarginNumeral.stories.ts` (all in `frontend/src/components/primitives/`)

**Interfaces:**
- Consumes: the CSF3 pattern + preview from Task 1.
- Produces: `Primitives/BStamp|BTag|BCard|BCropmarks|BMarginNumeral` in the sidebar. These are the identity-defining primitives (props taken verbatim from each component's `defineProps`).

- [ ] **Step 1: BStamp story** (props: `tone: 'red'|'ink'|'spot'`, `rotate?: number`, `size: 'sm'|'md'|'lg'`; default slot = label)

`BStamp.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BStamp from './BStamp.vue';

const meta = {
  title: 'Primitives/BStamp',
  component: BStamp,
  tags: ['autodocs'],
  argTypes: {
    tone: { control: 'select', options: ['red', 'ink', 'spot'] },
    size: { control: 'select', options: ['sm', 'md', 'lg'] },
    rotate: { control: { type: 'number', min: -15, max: 15 } },
  },
  args: { tone: 'red', size: 'md', rotate: -6 },
  render: (args) => ({
    components: { BStamp },
    setup: () => ({ args }),
    template: `<BStamp v-bind="args">PAID</BStamp>`,
  }),
} satisfies Meta<typeof BStamp>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Paid: Story = {};
export const Processing: Story = {
  args: { tone: 'ink' },
  render: (args) => ({ components: { BStamp }, setup: () => ({ args }), template: `<BStamp v-bind="args">PROCESSING</BStamp>` }),
};
export const Canceled: Story = {
  args: { tone: 'red', rotate: 8 },
  render: (args) => ({ components: { BStamp }, setup: () => ({ args }), template: `<BStamp v-bind="args">CANCELED</BStamp>` }),
};
```

- [ ] **Step 2: BTag story** (props: `tone: 'ink'|'spot'|'paper'`, `rotate?: number`; default slot)

`BTag.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BTag from './BTag.vue';

const meta = {
  title: 'Primitives/BTag',
  component: BTag,
  tags: ['autodocs'],
  argTypes: {
    tone: { control: 'select', options: ['ink', 'spot', 'paper'] },
    rotate: { control: { type: 'number', min: -10, max: 10 } },
  },
  args: { tone: 'ink' },
  render: (args) => ({
    components: { BTag },
    setup: () => ({ args }),
    template: `<BTag v-bind="args">SKU-0042</BTag>`,
  }),
} satisfies Meta<typeof BTag>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Ink: Story = {};
export const Spot: Story = { args: { tone: 'spot' } };
export const Paper: Story = { args: { tone: 'paper' } };
```

- [ ] **Step 3: BCard story** (props: `rotate?: number`, `hoverMisregister?: boolean`, `as?: string`; default slot)

`BCard.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BCard from './BCard.vue';

const meta = {
  title: 'Primitives/BCard',
  component: BCard,
  tags: ['autodocs'],
  argTypes: {
    rotate: { control: { type: 'number', min: -2, max: 2, step: 0.5 } },
    hoverMisregister: { control: 'boolean' },
    as: { control: 'text' },
  },
  args: { hoverMisregister: true, rotate: 0.5 },
  render: (args) => ({
    components: { BCard },
    setup: () => ({ args }),
    template: `<BCard v-bind="args" style="max-width:20rem;padding:var(--space-6)"><h3>Riso Print Nº01</h3><p>Hover me — the title misregisters.</p></BCard>`,
  }),
} satisfies Meta<typeof BCard>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Straight: Story = { args: { rotate: 0, hoverMisregister: false } };
```

- [ ] **Step 4: BCropmarks story** (props: `inset?: string`; wraps slotted content with corner marks)

`BCropmarks.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BCropmarks from './BCropmarks.vue';

const meta = {
  title: 'Primitives/BCropmarks',
  component: BCropmarks,
  tags: ['autodocs'],
  argTypes: { inset: { control: 'text' } },
  args: { inset: '1rem' },
  render: (args) => ({
    components: { BCropmarks },
    setup: () => ({ args }),
    template: `<div style="padding:2rem"><BCropmarks v-bind="args"><div style="padding:var(--space-6)">Content framed by crop marks</div></BCropmarks></div>`,
  }),
} satisfies Meta<typeof BCropmarks>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
```

- [ ] **Step 5: BMarginNumeral story** (props: `numeral: string`, `side?: 'left'|'right'`)

`BMarginNumeral.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BMarginNumeral from './BMarginNumeral.vue';

const meta = {
  title: 'Primitives/BMarginNumeral',
  component: BMarginNumeral,
  tags: ['autodocs'],
  argTypes: { side: { control: 'inline-radio', options: ['left', 'right'] } },
  args: { numeral: '01', side: 'left' },
} satisfies Meta<typeof BMarginNumeral>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Left: Story = {};
export const Right: Story = { args: { numeral: '02', side: 'right' } };
```

- [ ] **Step 6: Verify + commit**

Run: `pnpm typecheck && pnpm build-storybook`
Expected: PASS; five new entries under **Primitives**. Spot-check in `pnpm storybook` that BStamp shows the double-ring rotated stamp and BCard's title misregisters (spot text-shadow) on hover.
```bash
git add frontend/src/components/primitives/BStamp.stories.ts frontend/src/components/primitives/BTag.stories.ts frontend/src/components/primitives/BCard.stories.ts frontend/src/components/primitives/BCropmarks.stories.ts frontend/src/components/primitives/BMarginNumeral.stories.ts
git commit -m "feat(design-system): stories for identity primitives (stamp, tag, card, cropmarks, numeral)"
```

---

### Task 3: Form primitive stories — BInput, BSelect

**Files:**
- Create: `frontend/src/components/primitives/BInput.stories.ts`, `frontend/src/components/primitives/BSelect.stories.ts`

**Interfaces:**
- Consumes: CSF3 pattern from Task 1. Both are `v-model` components — stories wire a local `ref` so the control is interactive.
- Produces: `Primitives/BInput`, `Primitives/BSelect`.

- [ ] **Step 1: BInput story** (props: `modelValue: string`, `type?`, `label?`, `error?`, `id?`, `placeholder?`, `disabled?`; emits `update:modelValue`, `blur`)

`BInput.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import { ref } from 'vue';
import BInput from './BInput.vue';

const meta = {
  title: 'Primitives/BInput',
  component: BInput,
  tags: ['autodocs'],
  argTypes: {
    type: { control: 'text' },
    disabled: { control: 'boolean' },
  },
  args: { label: 'Email', placeholder: 'you@example.com', modelValue: '', type: 'email' },
  render: (args) => ({
    components: { BInput },
    setup() {
      const model = ref(args.modelValue);
      return { args, model };
    },
    template: `<div style="max-width:22rem"><BInput v-bind="args" v-model="model" /></div>`,
  }),
} satisfies Meta<typeof BInput>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const WithError: Story = { args: { error: 'Enter a valid email address.' } };
export const Disabled: Story = { args: { disabled: true, modelValue: 'locked@example.com' } };
```

- [ ] **Step 2: BSelect story** (props: `modelValue: string`, `options: BSelectOption[]`, `placeholder?`, `error?`, `disabled?`; emits `update:modelValue`)

`BSelect.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import { ref } from 'vue';
import BSelect from './BSelect.vue';

const OPTIONS = [
  { value: 'standard', label: 'Standard shipping' },
  { value: 'express', label: 'Express (next day)' },
  { value: 'pickup', label: 'Store pickup' },
];

const meta = {
  title: 'Primitives/BSelect',
  component: BSelect,
  tags: ['autodocs'],
  args: { modelValue: '', options: OPTIONS, placeholder: 'Choose a method' },
  render: (args) => ({
    components: { BSelect },
    setup() {
      const model = ref(args.modelValue);
      return { args, model };
    },
    template: `<div style="max-width:22rem"><BSelect v-bind="args" v-model="model" /></div>`,
  }),
} satisfies Meta<typeof BSelect>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const WithError: Story = { args: { error: 'Select a shipping method.' } };
export const Disabled: Story = { args: { disabled: true } };
```

- [ ] **Step 3: Verify + commit**

Run: `pnpm typecheck && pnpm build-storybook`
Expected: PASS; typing in BInput and opening BSelect (reka-ui portal) both work.
```bash
git add frontend/src/components/primitives/BInput.stories.ts frontend/src/components/primitives/BSelect.stories.ts
git commit -m "feat(design-system): stories for form primitives (input, select)"
```

---

### Task 4: Overlay primitive stories — BDialog, BToast, ToastViewport

**Files:**
- Create: `frontend/src/components/primitives/BDialog.stories.ts`, `frontend/src/components/primitives/BToast.stories.ts`, `frontend/src/components/primitives/ToastViewport.stories.ts`

**Interfaces:**
- Consumes: CSF3 pattern from Task 1.
- Produces: `Primitives/BDialog`, `Primitives/BToast`, `Primitives/ToastViewport`.
- Note: `BDialog` (props `open: boolean`, `title: string`, `description?`; emits `update:open`) uses a reka-ui portal — drive `open` from a local ref + a trigger button. `ToastViewport` reads the Pinia `useToastStore` — its story MUST install Pinia via a decorator.

- [ ] **Step 1: BDialog story**

`BDialog.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import { ref } from 'vue';
import BDialog from './BDialog.vue';
import BButton from './BButton.vue';

const meta = {
  title: 'Primitives/BDialog',
  component: BDialog,
  tags: ['autodocs'],
  args: { open: false, title: 'Cancel this order?', description: 'This cannot be undone.' },
  render: (args) => ({
    components: { BDialog, BButton },
    setup() {
      const open = ref(args.open);
      return { args, open };
    },
    template: `
      <div>
        <BButton variant="danger" @click="open = true">Cancel order</BButton>
        <BDialog v-bind="args" :open="open" @update:open="(v) => (open = v)">
          <p>Order #A-0042 will be canceled and stock released.</p>
        </BDialog>
      </div>`,
  }),
} satisfies Meta<typeof BDialog>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
```

- [ ] **Step 2: BToast story** (props: `tone: 'info'|'success'|'error'`, `title: string`, `body?`; emits `dismiss`)

`BToast.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import BToast from './BToast.vue';

const meta = {
  title: 'Primitives/BToast',
  component: BToast,
  tags: ['autodocs'],
  argTypes: { tone: { control: 'inline-radio', options: ['info', 'success', 'error'] } },
  args: { tone: 'success', title: 'Added to cart', body: 'Riso Print Nº01 × 1' },
} satisfies Meta<typeof BToast>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Success: Story = {};
export const Info: Story = { args: { tone: 'info', title: 'Heads up', body: 'Your session expires soon.' } };
export const Error: Story = { args: { tone: 'error', title: 'Payment failed', body: 'Card was declined.' } };
```

- [ ] **Step 3: ToastViewport story (installs Pinia)**

`ToastViewport.stories.ts`:
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import { createPinia } from 'pinia';
import ToastViewport from './ToastViewport.vue';
import BButton from './BButton.vue';
import { useToastStore } from '@/stores/toast';

const meta = {
  title: 'Primitives/ToastViewport',
  component: ToastViewport,
  tags: ['autodocs'],
  decorators: [
    (story) => ({
      components: { story },
      setup() {
        // Install a fresh Pinia so useToastStore() resolves inside the story
        return {};
      },
      template: '<story />',
    }),
  ],
  render: () => ({
    components: { ToastViewport, BButton },
    setup() {
      const toasts = useToastStore();
      const fire = () => toasts.push({ tone: 'success', title: 'Added to cart', body: 'Riso Print Nº01' });
      return { fire };
    },
    template: `<div><BButton @click="fire">Fire toast</BButton><ToastViewport /></div>`,
  }),
} satisfies Meta<typeof ToastViewport>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
```
Then register Pinia globally in `.storybook/preview.ts` so any store-backed story works. Add to the top of `preview.ts`:
```ts
import { setup } from '@storybook/vue3';
import { createPinia } from 'pinia';
setup((app) => {
  app.use(createPinia());
});
```
(Place this above the `const preview` declaration. This is the canonical Storybook way to install a Vue plugin globally.)

Note: confirm the exact `useToastStore().push(...)` signature against `frontend/src/stores/toast.ts` before writing Step 3 — match its real action name and payload shape. If the action differs, adjust the `fire()` call to match; do not invent an API.

- [ ] **Step 4: Verify + commit**

Run: `pnpm typecheck && pnpm build-storybook`
Expected: PASS; dialog opens/closes, "Fire toast" shows a toast via the store.
```bash
git add frontend/src/components/primitives/BDialog.stories.ts frontend/src/components/primitives/BToast.stories.ts frontend/src/components/primitives/ToastViewport.stories.ts frontend/.storybook/preview.ts
git commit -m "feat(design-system): stories for overlay primitives (dialog, toast, viewport) + global Pinia"
```

---

### Task 5: Pattern stories — domain & layout components

**Files:**
- Create story files beside each of: `frontend/src/components/domain/OrderStatusStamp.vue`, `CartLineItem.vue`, `CartSummary.vue`, `OrderItemRow.vue`, `OrderReceiptRow.vue`, `AddressForm.vue`, and `frontend/src/components/ProductCard.vue`, `frontend/src/components/BImageFallback.vue`, `frontend/src/components/layout/AppNav.vue`.

**Interfaces:**
- Consumes: CSF3 pattern (Task 1), global Pinia (Task 4).
- Produces: a `Patterns/*` section. Each story titled `Patterns/<ComponentName>`.

- [ ] **Step 1: Read each component's `defineProps`/`defineEmits` before writing its story**

Run: `sed -n '1,40p' frontend/src/components/domain/OrderStatusStamp.vue` (repeat per component). Record the exact prop names/types — the story's `args` MUST match them. Router-dependent components (`AppNav`) need a router; if a component calls `useRouter()`/`RouterLink`, install a memory router in `preview.ts` the same way Pinia was installed:
```ts
import { createRouter, createMemoryHistory } from 'vue-router';
setup((app) => {
  app.use(createRouter({ history: createMemoryHistory(), routes: [{ path: '/', component: { template: '<div/>' } }] }));
});
```
Add this only if a pattern story needs it (check with the `sed` read first).

- [ ] **Step 2: Write one story per component**

Follow this exact shape, substituting the real props you read in Step 1 (example shown for `OrderStatusStamp`, which wraps `BStamp` with an order status):
```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import OrderStatusStamp from './OrderStatusStamp.vue';

const meta = {
  title: 'Patterns/OrderStatusStamp',
  component: OrderStatusStamp,
  tags: ['autodocs'],
  // argTypes/args: fill from the real defineProps read in Step 1
} satisfies Meta<typeof OrderStatusStamp>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Paid: Story = { args: { /* real props, e.g. status: 'PAID' */ } };
```
Provide at least one meaningful story per component (multiple named stories where the component has status/variant props). For form-ish components (`AddressForm`), render inside a `max-width:32rem` wrapper. For list rows (`CartLineItem`, `OrderItemRow`, `OrderReceiptRow`), pass a representative fixture object matching the prop type.

- [ ] **Step 3: Verify + commit**

Run: `pnpm typecheck && pnpm build-storybook`
Expected: PASS; a `Patterns` section lists all nine components, each rendering in the identity.
```bash
git add frontend/src/components/**/*.stories.ts frontend/.storybook/preview.ts
git commit -m "feat(design-system): pattern stories for domain & layout components"
```

---

### Task 6: Foundations MDX — Identity, Color, Typography, Spacing, Borders & Shadows, Motion

**Files:**
- Create: `frontend/src/design-system/foundations/Identity.mdx`, `Color.mdx`, `Typography.mdx`, `Spacing.mdx`, `BordersShadows.mdx`, `Motion.mdx`

**Interfaces:**
- Consumes: `tokens.css` (already imported globally in preview). Foundations render swatches/specimens using `var(--…)` so they reflect the live tokens.
- Produces: a `Foundations/*` section. Source of truth for the prose is `frontend/docs/02-design-tokens.md` (migrate its content faithfully).

- [ ] **Step 1: Identity.mdx** — the Issue Nº01 story + hard rules

```mdx
import { Meta } from '@storybook/blocks';

<Meta title="Foundations/Identity" />

# Issue Nº01

The risograph-zine identity. Two-tone paper + ink, one fluorescent spot, hard-offset
shadows, mechanical `steps(2)` motion. Restraint is the point — the orange only punches
because everything else is two-tone.

## Hard rules
- Never hard-code a hex or font outside `src/styles/tokens.css`. Use `var(--…)` or the
  matching Tailwind utility (`text-spot`, `bg-paper-shade`).
- A new colour or motion value needs a token first, and an ADR if it's structurally new.
- The shadow IS the depth language — hard offset only, never blur or opacity.

See **Color**, **Typography**, **Motion**, and **Signature Details** for the specifics.
```

- [ ] **Step 2: Color.mdx** — palette table rendered from tokens

Render one swatch per token by setting `background: var(--paper)` etc. on a box, with the token name + intent beside it. Cover: `--paper`, `--paper-shade`, `--ink`, `--muted-ink`, `--spot`, `--stamp-red`. Copy the intent column verbatim from `docs/02-design-tokens.md`. Include the rule: "`--spot` = every CTA/focus/alert; `--stamp-red` = stamps & inspection marks only, never a CTA."

- [ ] **Step 3: Typography.mdx** — the three families as live specimens

Show Bricolage Grotesque 900 (display), Cabinet Grotesk (body), Departure Mono (mono) using `font-family: var(--font-display|--font-mono)` etc., with the scale tokens (`--type-display/h1/h2/body/small/mono`) rendered at size. Include the **Banned** list: Inter, Archivo Black, system-ui as primary, Roboto.

- [ ] **Step 4: Spacing.mdx** — the `--space-1…16` rhythm

Render each step as a bar of width `var(--space-N)`. State the rule: pick the nearest step, never arbitrary `padding: 13px`.

- [ ] **Step 5: BordersShadows.mdx** — borders + hard-offset shadow ladder

Render boxes using `--border-thin`, `--border-thick`, and `--shadow-sm/md/lg`. State: no blur, no opacity, hard offset only.

- [ ] **Step 6: Motion.mdx** — the press-snap

Document `--press-translate` and `--transition-snap` (`60ms steps(2)`). Embed a live `BButton` (import it) and instruct the reader to press it. Explain why `steps(2)` reads as a printing-press impact, not a Material ripple. Link to the a11y reduced-motion rule (Guides/A11y).

- [ ] **Step 7: Verify + commit**

Run: `pnpm build-storybook`
Expected: PASS; a `Foundations` section with six pages, swatches/specimens reflecting `tokens.css`.
```bash
git add frontend/src/design-system/foundations
git commit -m "docs(design-system): foundations MDX (identity, color, type, spacing, shadows, motion)"
```

---

### Task 7: Foundations MDX — Signature Details (live, interactive)

**Files:**
- Create: `frontend/src/design-system/foundations/SignatureDetails.mdx`

**Interfaces:**
- Consumes: `BStamp`, `BCard`, `BCropmarks`, `BMarginNumeral` (import into the MDX), `tokens.css`, `main.css` (paper grain).
- Produces: `Foundations/Signature Details` — the seven signatures from `docs/02-design-tokens.md` §"Signature details", each shown running.

- [ ] **Step 1: Write SignatureDetails.mdx**

Document all seven, each with a live embed where possible:
1. **Stamps, not badges** — embed `<BStamp tone="red">PAID</BStamp>`.
2. **Misregistration on hover** — embed a `<BCard hoverMisregister>` and tell the reader to hover.
3. **Marginalia numerals** — embed `<BMarginNumeral numeral="01" />`.
4. **Cropmark dividers** — embed `<BCropmarks>` around a block.
5. **Sticker rotation** — show two `<BCard :rotate="0.5">` / `:rotate="-0.5">` side by side.
6. **Paper grain** — explain the `body::after` SVG noise (~4% opacity) from `main.css`; it's visible on the story background.
7. **The CTA press** — link to Foundations/Motion.

Use MDX component embedding:
```mdx
import { Meta } from '@storybook/blocks';
import BStamp from '@/components/primitives/BStamp.vue';
import BCard from '@/components/primitives/BCard.vue';
import BCropmarks from '@/components/primitives/BCropmarks.vue';
import BMarginNumeral from '@/components/primitives/BMarginNumeral.vue';

<Meta title="Foundations/Signature Details" />

# Signature Details

<BStamp tone="red" :rotate="-6">PAID</BStamp>
```
(Confirm Vue-component embedding renders in your Storybook docs version; if a raw import doesn't render in MDX, wrap each in a tiny `.stories.ts` and reference it with the `<Story>` block instead.)

- [ ] **Step 2: Verify + commit**

Run: `pnpm build-storybook` then `pnpm storybook` and confirm each signature renders/animates.
```bash
git add frontend/src/design-system/foundations/SignatureDetails.mdx
git commit -m "docs(design-system): signature-details foundation (live stamps, misregistration, cropmarks)"
```

---

### Task 8: Guides MDX — migrate the build playbook from docs/00-09

**Files:**
- Create: `frontend/src/design-system/guides/Architecture.mdx`, `RoutingAuth.mdx`, `Api.mdx`, `Forms.mdx`, `Testing.mdx`, `CopyVoice.mdx`, `A11y.mdx`

**Interfaces:**
- Consumes: prose from `frontend/docs/01,04,05,06,07,08,09`.
- Produces: a `Guides/*` section — the build playbook. Each guide is a faithful migration (not a rewrite) of one source doc, wrapped as MDX.

- [ ] **Step 1: Migrate each doc to a Guide**

Mapping (copy content faithfully; convert relative links to Storybook cross-links or repo paths):
- `docs/01-architecture.md` → `guides/Architecture.mdx` (title `Guides/Architecture`). At the end, link to `docs/adr/` as the decision record home (ADRs stay where they are).
- `docs/04-api-conventions.md` → `guides/Api.mdx`
- `docs/05-form-conventions.md` → `guides/Forms.mdx`
- `docs/06-routing-auth.md` → `guides/RoutingAuth.mdx`
- `docs/07-testing-conventions.md` → `guides/Testing.mdx`
- `docs/08-copy-and-voice.md` → `guides/CopyVoice.mdx`
- `docs/09-a11y-checklist.md` → `guides/A11y.mdx`

Each MDX starts with:
```mdx
import { Meta } from '@storybook/blocks';

<Meta title="Guides/Api" />
```
then the migrated markdown body.

- [ ] **Step 2: Verify + commit**

Run: `pnpm build-storybook`
Expected: PASS; `Guides` section shows all seven pages, content matching the originals.
```bash
git add frontend/src/design-system/guides
git commit -m "docs(design-system): migrate build playbook into Storybook Guides"
```

---

### Task 9: Project-scoped `/design-system` skill

**Files:**
- Create: `.claude/skills/design-system/SKILL.md`, `.claude/skills/design-system/scripts/list-stories.sh`

**Interfaces:**
- Consumes: the story/MDX/token source produced by Tasks 1–8 (paths are stable under `frontend/`).
- Produces: a committed skill that teaches an agent to answer design/build questions from source — no server, no build required.

- [ ] **Step 1: Write the lister script**

`.claude/skills/design-system/scripts/list-stories.sh`:
```bash
#!/usr/bin/env bash
# Enumerate the design-system SSOT from source — no Storybook build needed.
set -euo pipefail
root="$(git rev-parse --show-toplevel)/frontend"

echo "== Stories =="
grep -rh "title:" "$root/src" --include=*.stories.ts | sed 's/.*title:[[:space:]]*//; s/[",]//g' | sort

echo; echo "== Foundations & Guides (MDX) =="
grep -rhoE 'title="[^"]+"' "$root/src/design-system" 2>/dev/null | sed 's/title=//; s/"//g' | sort

echo; echo "== Tokens =="
grep -oE '^\s*--[a-z0-9-]+:' "$root/src/styles/tokens.css" | tr -d ' :' | sort -u
```
Make it executable: `chmod +x .claude/skills/design-system/scripts/list-stories.sh`

- [ ] **Step 2: Write SKILL.md**

```markdown
---
name: design-system
description: Use when building or reviewing any frontend UI in this repo — the single source of truth for the Issue Nº01 design system (tokens, components, build conventions). Query it from source before writing markup, choosing a color/font, adding a component, or building a form/route/API call.
---

# Design System — Issue Nº01 (Storybook SSOT)

The frontend design system lives in Storybook. You do NOT need a running server —
read the source directly.

## Where things are (all under `frontend/`)
- **Tokens (values):** `src/styles/tokens.css` — colours, type, spacing, shadows, motion.
- **Component specs:** `src/components/**/*.stories.ts` — every variant + its props/args.
- **Component source:** the `.vue` next to each story — the real `defineProps`.
- **Foundations (rationale, Do/Don't):** `src/design-system/foundations/*.mdx`.
- **Build playbook (routing/api/forms/testing/copy/a11y):** `src/design-system/guides/*.mdx`.

## How to answer a question
- *"What variants does X have?"* → read `X.stories.ts` (argTypes + named stories).
- *"What's the spot colour / a token value?"* → read `src/styles/tokens.css`.
- *"Why / Do & Don't / the identity"* → read `foundations/*.mdx`.
- *"How do I build a form / route / API call / test?"* → read `guides/*.mdx`.
- *"List everything"* → run `scripts/list-stories.sh`.

## Hard rules (enforce in any UI you write)
- Never hard-code a hex or font — use `var(--…)` or the Tailwind token utility.
- Reuse the `B*` primitives; don't hand-roll a button/input/stamp.
- Stamps for status (never badges); the shadow is hard-offset only (no blur/opacity).
- `--spot` for every CTA/focus/alert; `--stamp-red` for stamps only, never a CTA.
- To see it rendered: `cd frontend && pnpm storybook`.
```

- [ ] **Step 3: Verify + commit**

Run: `bash .claude/skills/design-system/scripts/list-stories.sh`
Expected: prints the story titles, foundation/guide titles, and token names — proving an agent can enumerate the SSOT from source with no build.
```bash
git add .claude/skills/design-system
git commit -m "feat(design-system): project-scoped /design-system skill (query SSOT from source)"
```

---

### Task 10: Retire docs/00-09 and repoint frontend/CLAUDE.md

**Files:**
- Delete: `frontend/docs/00-readme.md` … `frontend/docs/09-a11y-checklist.md` (all 10)
- Keep: `frontend/docs/adr/` (+ any verification pngs/mds — leave non-`0X-` files untouched)
- Modify: `frontend/CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1–9 (content now lives in Storybook + the skill).
- Produces: a single, non-duplicated SSOT. `CLAUDE.md` becomes a thin pointer.

- [ ] **Step 1: Confirm nothing references the old numbered docs**

Run: `grep -rn "docs/0[0-9]" frontend --include=*.md --include=*.vue --include=*.ts | grep -v node_modules`
Expected: only the `00-readme.md` "Where to look" list (which we're deleting) shows up. If a component or ADR links a numbered doc, update it to the Storybook path first.

- [ ] **Step 2: Delete the numbered docs**

```bash
git rm frontend/docs/0[0-9]-*.md
```
Expected: 10 files staged for deletion; `frontend/docs/adr/` and any `phase-*`/`*.png` files remain.

- [ ] **Step 3: Rewrite `frontend/CLAUDE.md` "Conventions"/"Where to look"**

Replace the "Where to look" list and design references with:
```markdown
## Design system — single source of truth

The Issue Nº01 design system lives in **Storybook** (`cd frontend && pnpm storybook`).
Agents: use the project `/design-system` skill — it reads the SSOT from source
(no server needed).

- **Tokens:** `src/styles/tokens.css`
- **Components:** `src/components/**/*.stories.ts` (+ the `.vue` beside each)
- **Foundations (rationale, Do/Don't):** `src/design-system/foundations/*.mdx`
- **Build playbook (routing/api/forms/testing/copy/a11y):** `src/design-system/guides/*.mdx`
- **Decisions:** `docs/adr/`

Never hard-code a hex/font; reuse the `B*` primitives; `--spot` for CTAs,
`--stamp-red` for stamps only.
```
Keep the existing Stack/Commands/API sections; only replace the design-doc pointers.

- [ ] **Step 4: Final full verification**

Run (from `frontend/`):
```bash
pnpm typecheck && pnpm lint && pnpm test && pnpm build-storybook
```
Expected: all PASS. Storybook contains Foundations + Primitives + Patterns + Guides; no orphaned links to deleted docs.

- [ ] **Step 5: Commit**

```bash
git add frontend/CLAUDE.md && git rm --cached --ignore-unmatch frontend/docs/0[0-9]-*.md
git commit -m "docs(design-system): retire docs/00-09, point CLAUDE.md at Storybook SSOT"
```

---

## Self-Review

**Spec coverage:**
- Storybook as single content home → Tasks 1–8. ✓
- Foundations (Identity, Color, Type, Spacing, Shadows, Motion, Signatures) → Tasks 6–7. ✓
- Primitives (11 `B*`) → Tasks 1–4 (BButton×1, identity×5, form×2, overlay×3 = 11). ✓
- Patterns (domain/layout) → Task 5. ✓
- Guides (playbook from docs/01,04–09) → Task 8. ✓
- `tokens.css` unchanged, renders foundations → Global Constraints + Task 6. ✓
- Project-scoped `/design-system` skill, no MCP → Task 9. ✓
- Migration + retire docs/00-09 + rewrite CLAUDE.md → Task 10. ✓
- ADR fate (keep + link) → resolved in Tasks 8 & 10. ✓
- MDX home (`src/design-system/`) → resolved in Global Constraints. ✓
- No app re-skin → Global Constraints (frozen aesthetic). ✓
- Success criteria (agent can answer 4 sample questions) → Task 9 skill covers all four. ✓

**Placeholder scan:** Story code is complete for all 11 primitives (real props). Task 5 (patterns) and parts of Tasks 6–8 intentionally require reading each source doc/component first — that content is authored *from an existing file*, so the "source of truth" is named exactly rather than pasted wholesale; the shape/template is fully specified. Two explicit "confirm against source" notes (toast store API in Task 4, MDX Vue embedding in Task 7) are verification instructions, not deferred work.

**Type consistency:** `Meta`/`StoryObj` from `@storybook/vue3` used uniformly; every story's `args` matches the component's real `defineProps` (verified against source). `useToastStore` flagged for signature confirmation. `@` alias defined in Task 1 `viteFinal` and used by later imports.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-05-design-system-storybook.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
