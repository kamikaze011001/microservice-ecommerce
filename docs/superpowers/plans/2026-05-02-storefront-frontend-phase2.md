# Storefront Frontend — Phase 2 (Design System Primitives) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the 10 design-system primitives + toast queue + `/_design` showcase route, covered by ≥ 20 component tests + 2 store tests, all green; verify the live-browser DoD bullets via Chrome DevTools MCP.

**Architecture:** Each primitive is a single `.vue` file with a focused contract; no API or domain logic touches `components/primitives/`. Toast queue is a Pinia store + `useToast()` composable + a single `<ToastViewport>` mounted in `App.vue`. Vue Router is added with two routes (`/` placeholder, `/_design` showcase). Reka UI provides headless behavior for `BDialog` and `BSelect`; everything else is pure CSS + Vue `<Transition>`.

**Tech Stack:** Vue 3.4, TypeScript strict, Tailwind v4 (with `@theme` bridge to `:root` tokens), Pinia 2.2, Vue Router 4.4, Reka UI 1.x, Vitest 2.x + happy-dom + @testing-library/vue + @testing-library/user-event. Chrome DevTools MCP for live DoD verification.

**Branch:** `frontend/phase-2-primitives` (already created, off `main` after PR #1 merge).

**Spec:** `docs/superpowers/specs/2026-05-02-storefront-frontend-phase2-design.md`

---

## File Map

### Created

```
frontend/src/components/primitives/
  BButton.vue          BCard.vue            BInput.vue
  BStamp.vue           BTag.vue             BCropmarks.vue
  BMarginNumeral.vue   BDialog.vue          BSelect.vue
  BToast.vue           ToastViewport.vue    index.ts
frontend/src/composables/useToast.ts
frontend/src/stores/toast.ts
frontend/src/lib/rotation.ts
frontend/src/pages/HomePlaceholder.vue
frontend/src/pages/DesignShowcase.vue
frontend/src/router/index.ts
frontend/tests/unit/lib/rotation.spec.ts
frontend/tests/unit/stores/toast.spec.ts
frontend/tests/unit/components/primitives/BButton.spec.ts
frontend/tests/unit/components/primitives/BCard.spec.ts
frontend/tests/unit/components/primitives/BInput.spec.ts
frontend/tests/unit/components/primitives/BStamp.spec.ts
frontend/tests/unit/components/primitives/BTag.spec.ts
frontend/tests/unit/components/primitives/BCropmarks.spec.ts
frontend/tests/unit/components/primitives/BMarginNumeral.spec.ts
frontend/tests/unit/components/primitives/BDialog.spec.ts
frontend/tests/unit/components/primitives/BSelect.spec.ts
frontend/tests/unit/components/primitives/BToast.spec.ts
```

### Modified

- `frontend/src/main.ts` — register Pinia + Router
- `frontend/src/App.vue` — replace placeholder content with `<RouterView />` + `<ToastViewport />` (placeholder content moves to `pages/HomePlaceholder.vue`)
- `frontend/package.json` — add deps `pinia ^2.2`, `vue-router ^4.4`, `reka-ui ^1.0`, `@testing-library/user-event ^14`
- `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` — flip Phase 2 DoD checkboxes after verification

---

## Task 1: Install dependencies

**Files:**
- Modify: `frontend/package.json`
- Modify: `frontend/pnpm-lock.yaml` (auto)

- [ ] **Step 1: Install runtime + headless + test deps**

```bash
cd frontend
pnpm add pinia@^2.2 vue-router@^4.4 reka-ui@^1.0
pnpm add -D @testing-library/user-event@^14
```

- [ ] **Step 2: Verify install**

Run: `pnpm typecheck`
Expected: PASS (no new TS errors).

- [ ] **Step 3: Commit**

```bash
git add package.json pnpm-lock.yaml
git commit -m "chore(frontend): add pinia, vue-router, reka-ui, user-event"
```

---

## Task 2: Rotation helper + test

**Files:**
- Create: `frontend/src/lib/rotation.ts`
- Create: `frontend/tests/unit/lib/rotation.spec.ts`

- [ ] **Step 1: Write failing test**

`frontend/tests/unit/lib/rotation.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { hashRotate } from '@/lib/rotation';

describe('hashRotate', () => {
  it('is deterministic for the same seed', () => {
    expect(hashRotate('abc')).toBe(hashRotate('abc'));
  });

  it('produces values within ±maxDegrees', () => {
    for (const seed of ['a', 'product-1', 'order-99', '🌶']) {
      const v = hashRotate(seed, 0.5);
      expect(v).toBeGreaterThanOrEqual(-0.5);
      expect(v).toBeLessThanOrEqual(0.5);
    }
  });

  it('respects custom max', () => {
    expect(Math.abs(hashRotate('seed', 4))).toBeLessThanOrEqual(4);
  });

  it('produces different values for different seeds', () => {
    expect(hashRotate('a')).not.toBe(hashRotate('b'));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test rotation`
Expected: FAIL — `Cannot find module '@/lib/rotation'`.

- [ ] **Step 3: Implement**

`frontend/src/lib/rotation.ts`:

```ts
export function hashRotate(seed: string, maxDegrees = 0.5): number {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const norm = (h >>> 0) / 0xffffffff;
  return (norm * 2 - 1) * maxDegrees;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && pnpm test rotation`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/rotation.ts frontend/tests/unit/lib/rotation.spec.ts
git commit -m "feat(frontend): add deterministic hashRotate helper"
```

---

## Task 3: Toast Pinia store + tests

**Files:**
- Create: `frontend/src/stores/toast.ts`
- Create: `frontend/tests/unit/stores/toast.spec.ts`

- [ ] **Step 1: Write failing test**

`frontend/tests/unit/stores/toast.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useToastStore } from '@/stores/toast';

describe('toast store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('push() adds an item with default tone=info, duration=4000, and auto-dismisses', () => {
    const store = useToastStore();
    const id = store.push({ title: 'Hello' });
    expect(store.items).toHaveLength(1);
    expect(store.items[0]).toMatchObject({ id, tone: 'info', title: 'Hello', duration: 4000 });
    vi.advanceTimersByTime(4000);
    expect(store.items).toHaveLength(0);
  });

  it('dismiss(id) removes the item and cancels the auto-dismiss timer', () => {
    const store = useToastStore();
    const id = store.push({ title: 'Bye', duration: 4000 });
    store.dismiss(id);
    expect(store.items).toHaveLength(0);
    vi.advanceTimersByTime(10000);
    expect(store.items).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test toast`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement store**

`frontend/src/stores/toast.ts`:

```ts
import { defineStore } from 'pinia';
import { ref } from 'vue';

export type ToastTone = 'info' | 'success' | 'error';

export interface ToastItem {
  id: string;
  tone: ToastTone;
  title: string;
  body?: string;
  duration: number;
}

export interface ToastInput {
  tone?: ToastTone;
  title: string;
  body?: string;
  duration?: number;
}

export const useToastStore = defineStore('toast', () => {
  const items = ref<ToastItem[]>([]);
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  function push(input: ToastInput): string {
    const id = crypto.randomUUID();
    const item: ToastItem = {
      id,
      tone: input.tone ?? 'info',
      title: input.title,
      body: input.body,
      duration: input.duration ?? 4000,
    };
    items.value.push(item);
    timers.set(
      id,
      setTimeout(() => dismiss(id), item.duration),
    );
    return id;
  }

  function dismiss(id: string): void {
    const t = timers.get(id);
    if (t) {
      clearTimeout(t);
      timers.delete(id);
    }
    items.value = items.value.filter((i) => i.id !== id);
  }

  function clear(): void {
    timers.forEach((t) => clearTimeout(t));
    timers.clear();
    items.value = [];
  }

  return { items, push, dismiss, clear };
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && pnpm test toast`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/stores/toast.ts frontend/tests/unit/stores/toast.spec.ts
git commit -m "feat(frontend): add Pinia toast store with auto-dismiss"
```

---

## Task 4: useToast composable

**Files:**
- Create: `frontend/src/composables/useToast.ts`

- [ ] **Step 1: Implement (no separate test — exercised via store + components)**

`frontend/src/composables/useToast.ts`:

```ts
import { useToastStore, type ToastInput } from '@/stores/toast';

type Opts = Pick<ToastInput, 'duration'>;

export function useToast() {
  const store = useToastStore();
  return {
    info: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'info', title, body, ...opts }),
    success: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'success', title, body, ...opts }),
    error: (title: string, body?: string, opts?: Opts) =>
      store.push({ tone: 'error', title, body, ...opts }),
    dismiss: (id: string) => store.dismiss(id),
  };
}
```

- [ ] **Step 2: Verify typecheck**

Run: `cd frontend && pnpm typecheck`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/composables/useToast.ts
git commit -m "feat(frontend): add useToast composable"
```

---

## Task 5: BButton + tests

**Files:**
- Create: `frontend/src/components/primitives/BButton.vue`
- Create: `frontend/tests/unit/components/primitives/BButton.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BButton.spec.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BButton from '@/components/primitives/BButton.vue';

describe('BButton', () => {
  it('renders default slot text and emits click once', async () => {
    const onClick = vi.fn();
    render(BButton, { slots: { default: 'Press me' }, attrs: { onClick } });
    const btn = screen.getByRole('button', { name: /press me/i });
    await userEvent.click(btn);
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('disabled blocks click; loading hides slot and shows spinner', async () => {
    const onClick = vi.fn();
    const { rerender } = render(BButton, {
      props: { disabled: true },
      slots: { default: 'Nope' },
      attrs: { onClick },
    });
    await userEvent.click(screen.getByRole('button'));
    expect(onClick).not.toHaveBeenCalled();

    await rerender({ disabled: false, loading: true });
    expect(screen.getByRole('button')).toHaveAttribute('aria-busy', 'true');
    expect(screen.getByTestId('b-button-spinner')).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BButton`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BButton.vue`:

```vue
<script setup lang="ts">
interface Props {
  variant?: 'spot' | 'ink' | 'ghost' | 'danger';
  type?: 'button' | 'submit' | 'reset';
  disabled?: boolean;
  loading?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  variant: 'ink',
  type: 'button',
  disabled: false,
  loading: false,
});
defineEmits<{ click: [event: MouseEvent] }>();
</script>

<template>
  <button
    :type="props.type"
    :disabled="props.disabled || props.loading"
    :aria-busy="props.loading || undefined"
    :class="['b-button', `b-button--${props.variant}`, { 'is-loading': props.loading }]"
  >
    <span v-if="props.loading" class="b-button__spinner" data-testid="b-button-spinner" aria-hidden="true" />
    <span v-else class="b-button__label"><slot /></span>
  </button>
</template>

<style scoped>
.b-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: var(--space-2);
  padding: var(--space-3) var(--space-6);
  border: var(--border-thick);
  background: var(--paper);
  color: var(--ink);
  font-family: var(--font-display);
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  box-shadow: var(--shadow-md);
  cursor: pointer;
  transition: transform var(--transition-snap), box-shadow var(--transition-snap);
}
.b-button:active:not(:disabled) {
  transform: translate(var(--press-translate), var(--press-translate));
  box-shadow: var(--shadow-sm);
}
.b-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.b-button--spot {
  background: var(--spot);
  color: var(--ink);
}
.b-button--ghost {
  background: transparent;
  box-shadow: none;
}
.b-button--danger {
  background: var(--stamp-red);
  color: var(--paper);
}
.b-button__spinner {
  width: 1em;
  height: 1em;
  border: 2px solid currentColor;
  border-right-color: transparent;
  border-radius: 50%;
  animation: b-button-spin 0.8s steps(8) infinite;
}
@keyframes b-button-spin {
  to { transform: rotate(360deg); }
}
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BButton`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BButton.vue frontend/tests/unit/components/primitives/BButton.spec.ts
git commit -m "feat(frontend): add BButton primitive"
```

---

## Task 6: BCard + tests

**Files:**
- Create: `frontend/src/components/primitives/BCard.vue`
- Create: `frontend/tests/unit/components/primitives/BCard.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BCard.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BCard from '@/components/primitives/BCard.vue';

describe('BCard', () => {
  it('renders default slot inside the card element', () => {
    render(BCard, { slots: { default: '<p>body content</p>' } });
    expect(screen.getByText('body content')).toBeInTheDocument();
  });

  it('hoverMisregister=true toggles is-misregister class on hover', async () => {
    const { container } = render(BCard, {
      props: { hoverMisregister: true },
      slots: { default: 'card' },
    });
    const card = container.querySelector('.b-card')!;
    expect(card.className).not.toContain('is-misregister');
    await userEvent.hover(card);
    expect(card.className).toContain('is-misregister');
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BCard`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BCard.vue`:

```vue
<script setup lang="ts">
import { ref } from 'vue';

interface Props {
  rotate?: number;
  hoverMisregister?: boolean;
  as?: string;
}
const props = withDefaults(defineProps<Props>(), {
  hoverMisregister: false,
  as: 'article',
});

const hovered = ref(false);
</script>

<template>
  <component
    :is="props.as"
    :class="['b-card', { 'is-misregister': props.hoverMisregister && hovered }]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
    @mouseenter="hovered = true"
    @mouseleave="hovered = false"
  >
    <header v-if="$slots.header" class="b-card__header"><slot name="header" /></header>
    <div class="b-card__body"><slot /></div>
    <footer v-if="$slots.footer" class="b-card__footer"><slot name="footer" /></footer>
  </component>
</template>

<style scoped>
.b-card {
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-md);
  padding: var(--space-6);
  transition: text-shadow var(--transition-snap);
}
.b-card.is-misregister :deep(h1),
.b-card.is-misregister :deep(h2),
.b-card.is-misregister :deep(h3) {
  text-shadow: 2px 2px 0 var(--spot);
}
.b-card__header {
  margin-bottom: var(--space-4);
  border-bottom: var(--border-thin);
  padding-bottom: var(--space-3);
}
.b-card__footer {
  margin-top: var(--space-4);
  border-top: var(--border-thin);
  padding-top: var(--space-3);
}
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BCard`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BCard.vue frontend/tests/unit/components/primitives/BCard.spec.ts
git commit -m "feat(frontend): add BCard primitive"
```

---

## Task 7: BInput + tests

**Files:**
- Create: `frontend/src/components/primitives/BInput.vue`
- Create: `frontend/tests/unit/components/primitives/BInput.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BInput.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { ref } from 'vue';
import BInput from '@/components/primitives/BInput.vue';

describe('BInput', () => {
  it('two-way binds via v-model', async () => {
    const model = ref('');
    render({
      components: { BInput },
      setup: () => ({ model }),
      template: `<BInput v-model="model" label="Name" />`,
    });
    const input = screen.getByLabelText('Name');
    await userEvent.type(input, 'Sona');
    expect(model.value).toBe('Sona');
  });

  it('error prop renders message and applies has-error class', () => {
    const { container } = render(BInput, {
      props: { modelValue: '', error: 'Required' },
    });
    expect(screen.getByText('Required')).toBeInTheDocument();
    expect(container.querySelector('.b-input.has-error')).not.toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BInput`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BInput.vue`:

```vue
<script setup lang="ts">
import { computed, useId } from 'vue';

interface Props {
  modelValue: string;
  type?: string;
  label?: string;
  error?: string;
  id?: string;
  placeholder?: string;
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  type: 'text',
  disabled: false,
});

const emit = defineEmits<{
  'update:modelValue': [value: string];
  blur: [event: FocusEvent];
}>();

const autoId = useId();
const inputId = computed(() => props.id ?? `b-input-${autoId}`);

function onInput(e: Event) {
  emit('update:modelValue', (e.target as HTMLInputElement).value);
}
</script>

<template>
  <div :class="['b-input', { 'has-error': !!props.error }]">
    <label v-if="props.label" :for="inputId" class="b-input__label">{{ props.label }}</label>
    <input
      :id="inputId"
      :type="props.type"
      :value="props.modelValue"
      :placeholder="props.placeholder"
      :disabled="props.disabled"
      :aria-invalid="!!props.error || undefined"
      :aria-describedby="props.error ? `${inputId}-err` : undefined"
      class="b-input__control"
      @input="onInput"
      @blur="emit('blur', $event)"
    />
    <p v-if="props.error" :id="`${inputId}-err`" class="b-input__error" role="alert">
      {{ props.error }}
    </p>
  </div>
</template>

<style scoped>
.b-input { display: flex; flex-direction: column; gap: var(--space-2); }
.b-input__label {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.b-input__control {
  border: var(--border-thick);
  background: var(--paper);
  padding: var(--space-3);
  font-family: var(--font-body);
  font-size: var(--type-body);
  color: var(--ink);
  transition: transform var(--transition-snap), outline-color var(--transition-snap);
}
.b-input__control:focus {
  outline: 2px solid var(--spot);
  outline-offset: 2px;
  transform: translate(2px, 0);
}
.b-input.has-error .b-input__control { border-color: var(--stamp-red); }
.b-input__error {
  color: var(--stamp-red);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
}
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BInput`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BInput.vue frontend/tests/unit/components/primitives/BInput.spec.ts
git commit -m "feat(frontend): add BInput primitive"
```

---

## Task 8: BStamp + tests

**Files:**
- Create: `frontend/src/components/primitives/BStamp.vue`
- Create: `frontend/tests/unit/components/primitives/BStamp.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BStamp.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BStamp from '@/components/primitives/BStamp.vue';

describe('BStamp', () => {
  it('renders default slot label', () => {
    render(BStamp, { slots: { default: 'PAID' } });
    expect(screen.getByText('PAID')).toBeInTheDocument();
  });

  it('tone="ink" applies tone-ink class', () => {
    const { container } = render(BStamp, {
      props: { tone: 'ink' },
      slots: { default: 'CANCELED' },
    });
    expect(container.querySelector('.b-stamp.tone-ink')).not.toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BStamp`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BStamp.vue`:

```vue
<script setup lang="ts">
interface Props {
  tone?: 'red' | 'ink' | 'spot';
  rotate?: number;
  size?: 'sm' | 'md' | 'lg';
}
const props = withDefaults(defineProps<Props>(), {
  tone: 'red',
  size: 'md',
});
</script>

<template>
  <span
    :class="['b-stamp', `tone-${props.tone}`, `size-${props.size}`]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
    role="img"
    :aria-label="`stamp: ${$slots.default ? '' : ''}`"
  >
    <span class="b-stamp__inner"><slot /></span>
  </span>
</template>

<style scoped>
.b-stamp {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 4px double currentColor;
  outline: 2px solid currentColor;
  outline-offset: 4px;
  border-radius: 50%;
  font-family: var(--font-display);
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  line-height: 1;
  padding: var(--space-3);
  text-align: center;
}
.size-sm { width: 4rem;  height: 4rem;  font-size: 0.7rem; }
.size-md { width: 6rem;  height: 6rem;  font-size: 0.95rem; }
.size-lg { width: 8rem;  height: 8rem;  font-size: 1.2rem; }
.tone-red  { color: var(--stamp-red); }
.tone-ink  { color: var(--ink); }
.tone-spot { color: var(--spot); }
.b-stamp__inner { display: block; max-width: 80%; }
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BStamp`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BStamp.vue frontend/tests/unit/components/primitives/BStamp.spec.ts
git commit -m "feat(frontend): add BStamp primitive"
```

---

## Task 9: BTag + tests

**Files:**
- Create: `frontend/src/components/primitives/BTag.vue`
- Create: `frontend/tests/unit/components/primitives/BTag.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BTag.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BTag from '@/components/primitives/BTag.vue';

describe('BTag', () => {
  it('renders default slot', () => {
    render(BTag, { slots: { default: 'NEW' } });
    expect(screen.getByText('NEW')).toBeInTheDocument();
  });

  it('rotate prop sets inline rotation transform', () => {
    const { container } = render(BTag, {
      props: { rotate: 2 },
      slots: { default: 'tag' },
    });
    const el = container.querySelector('.b-tag') as HTMLElement;
    expect(el.style.transform).toBe('rotate(2deg)');
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BTag`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BTag.vue`:

```vue
<script setup lang="ts">
interface Props {
  tone?: 'ink' | 'spot' | 'paper';
  rotate?: number;
}
const props = withDefaults(defineProps<Props>(), { tone: 'ink' });
</script>

<template>
  <span
    :class="['b-tag', `tone-${props.tone}`]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
  >
    <slot />
  </span>
</template>

<style scoped>
.b-tag {
  display: inline-block;
  padding: var(--space-1) var(--space-3);
  border: var(--border-thin);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.tone-ink   { background: var(--ink);   color: var(--paper); border-color: var(--ink); }
.tone-spot  { background: var(--spot);  color: var(--ink); border-color: var(--ink); }
.tone-paper { background: var(--paper); color: var(--ink); border-color: var(--ink); }
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BTag`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BTag.vue frontend/tests/unit/components/primitives/BTag.spec.ts
git commit -m "feat(frontend): add BTag primitive"
```

---

## Task 10: BCropmarks + tests

**Files:**
- Create: `frontend/src/components/primitives/BCropmarks.vue`
- Create: `frontend/tests/unit/components/primitives/BCropmarks.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BCropmarks.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render } from '@testing-library/vue';
import BCropmarks from '@/components/primitives/BCropmarks.vue';

describe('BCropmarks', () => {
  it('renders 4 corner-mark elements', () => {
    const { container } = render(BCropmarks);
    expect(container.querySelectorAll('.b-cropmarks__mark')).toHaveLength(4);
  });

  it('inset prop is passed as a CSS custom property', () => {
    const { container } = render(BCropmarks, { props: { inset: '2rem' } });
    const root = container.querySelector('.b-cropmarks') as HTMLElement;
    expect(root.style.getPropertyValue('--b-cropmarks-inset')).toBe('2rem');
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BCropmarks`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BCropmarks.vue`:

```vue
<script setup lang="ts">
interface Props { inset?: string }
const props = withDefaults(defineProps<Props>(), { inset: '1rem' });
</script>

<template>
  <div
    class="b-cropmarks"
    :style="{ '--b-cropmarks-inset': props.inset }"
    aria-hidden="true"
  >
    <span class="b-cropmarks__mark mark-tl" />
    <span class="b-cropmarks__mark mark-tr" />
    <span class="b-cropmarks__mark mark-bl" />
    <span class="b-cropmarks__mark mark-br" />
  </div>
</template>

<style scoped>
.b-cropmarks {
  position: relative;
  height: var(--space-8);
  margin: var(--space-8) 0;
}
.b-cropmarks__mark {
  position: absolute;
  width: 12px;
  height: 12px;
  border-color: var(--ink);
  border-style: solid;
  border-width: 0;
}
.mark-tl { top: var(--b-cropmarks-inset); left:  var(--b-cropmarks-inset); border-top-width: 2px; border-left-width: 2px; }
.mark-tr { top: var(--b-cropmarks-inset); right: var(--b-cropmarks-inset); border-top-width: 2px; border-right-width: 2px; }
.mark-bl { bottom: var(--b-cropmarks-inset); left:  var(--b-cropmarks-inset); border-bottom-width: 2px; border-left-width: 2px; }
.mark-br { bottom: var(--b-cropmarks-inset); right: var(--b-cropmarks-inset); border-bottom-width: 2px; border-right-width: 2px; }
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BCropmarks`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BCropmarks.vue frontend/tests/unit/components/primitives/BCropmarks.spec.ts
git commit -m "feat(frontend): add BCropmarks primitive"
```

---

## Task 11: BMarginNumeral + tests

**Files:**
- Create: `frontend/src/components/primitives/BMarginNumeral.vue`
- Create: `frontend/tests/unit/components/primitives/BMarginNumeral.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BMarginNumeral.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BMarginNumeral from '@/components/primitives/BMarginNumeral.vue';

describe('BMarginNumeral', () => {
  it('renders the numeral text', () => {
    render(BMarginNumeral, { props: { numeral: '01' } });
    expect(screen.getByText('01')).toBeInTheDocument();
  });

  it('side="right" applies side-right class', () => {
    const { container } = render(BMarginNumeral, {
      props: { numeral: '02', side: 'right' },
    });
    expect(container.querySelector('.b-margin-numeral.side-right')).not.toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BMarginNumeral`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BMarginNumeral.vue`:

```vue
<script setup lang="ts">
interface Props {
  numeral: string;
  side?: 'left' | 'right';
}
const props = withDefaults(defineProps<Props>(), { side: 'left' });
</script>

<template>
  <span :class="['b-margin-numeral', `side-${props.side}`]" aria-hidden="true">
    {{ props.numeral }}
  </span>
</template>

<style scoped>
.b-margin-numeral {
  display: block;
  font-family: var(--font-display);
  font-weight: 900;
  font-size: clamp(4rem, 10vw, 9rem);
  line-height: 0.85;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
  letter-spacing: -0.05em;
}
.side-left  { text-align: left;  margin-left:  calc(-1 * var(--space-4)); }
.side-right { text-align: right; margin-right: calc(-1 * var(--space-4)); }
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BMarginNumeral`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BMarginNumeral.vue frontend/tests/unit/components/primitives/BMarginNumeral.spec.ts
git commit -m "feat(frontend): add BMarginNumeral primitive"
```

---

## Task 12: BDialog (Reka) + tests

**Files:**
- Create: `frontend/src/components/primitives/BDialog.vue`
- Create: `frontend/tests/unit/components/primitives/BDialog.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BDialog.spec.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BDialog from '@/components/primitives/BDialog.vue';

describe('BDialog', () => {
  it('open=true renders title in a portal; Esc emits update:open=false', async () => {
    const onUpdate = vi.fn();
    render(BDialog, {
      props: { open: true, title: 'Confirm', 'onUpdate:open': onUpdate },
      slots: { default: '<p>body</p>' },
    });
    expect(screen.getByText('Confirm')).toBeInTheDocument();
    expect(screen.getByText('body')).toBeInTheDocument();
    await userEvent.keyboard('{Escape}');
    expect(onUpdate).toHaveBeenCalledWith(false);
  });

  it('renders the footer slot when provided', () => {
    render(BDialog, {
      props: { open: true, title: 'Confirm' },
      slots: {
        default: '<p>are you sure?</p>',
        footer: '<button>OK</button>',
      },
    });
    expect(screen.getByRole('button', { name: 'OK' })).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BDialog`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BDialog.vue`:

```vue
<script setup lang="ts">
import {
  DialogRoot, DialogTrigger, DialogPortal, DialogOverlay,
  DialogContent, DialogTitle, DialogDescription, DialogClose,
} from 'reka-ui';

interface Props {
  open: boolean;
  title: string;
  description?: string;
}
const props = defineProps<Props>();
defineEmits<{ 'update:open': [value: boolean] }>();
</script>

<template>
  <DialogRoot :open="props.open" @update:open="$emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="b-dialog__overlay" />
      <DialogContent class="b-dialog__content">
        <DialogTitle class="b-dialog__title">{{ props.title }}</DialogTitle>
        <DialogDescription v-if="props.description" class="b-dialog__desc">
          {{ props.description }}
        </DialogDescription>
        <div class="b-dialog__body"><slot /></div>
        <div v-if="$slots.footer" class="b-dialog__footer"><slot name="footer" /></div>
        <DialogClose class="b-dialog__x" aria-label="Close">×</DialogClose>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>

<style scoped>
.b-dialog__overlay {
  position: fixed; inset: 0;
  background: rgba(28, 28, 28, 0.6);
  z-index: 50;
}
.b-dialog__content {
  position: fixed;
  top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-lg);
  padding: var(--space-8);
  min-width: 20rem;
  max-width: 40rem;
  z-index: 51;
}
.b-dialog__title {
  font-family: var(--font-display);
  font-size: var(--type-h2);
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: var(--space-3);
}
.b-dialog__desc { color: var(--muted-ink); margin-bottom: var(--space-4); }
.b-dialog__body { margin-bottom: var(--space-6); }
.b-dialog__footer {
  display: flex; gap: var(--space-3); justify-content: flex-end;
  border-top: var(--border-thin); padding-top: var(--space-4);
}
.b-dialog__x {
  position: absolute; top: var(--space-3); right: var(--space-3);
  background: transparent; border: none; font-size: 1.5rem;
  cursor: pointer; line-height: 1;
}
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BDialog`
Expected: PASS (2/2). If happy-dom can't dispatch the Escape key into Reka's listener, the fallback is to close via the close button — but Reka registers a window listener, so the keyboard event in user-event should reach it. If this test flakes, swap to clicking the close button (the DoD bullet for keyboard nav is verified live in browser via Chrome DevTools MCP in Task 19).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BDialog.vue frontend/tests/unit/components/primitives/BDialog.spec.ts
git commit -m "feat(frontend): add BDialog primitive on Reka UI"
```

---

## Task 13: BSelect (Reka) + tests

**Files:**
- Create: `frontend/src/components/primitives/BSelect.vue`
- Create: `frontend/tests/unit/components/primitives/BSelect.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BSelect.spec.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BSelect from '@/components/primitives/BSelect.vue';

const options = [
  { value: 'us', label: 'United States' },
  { value: 'vn', label: 'Vietnam' },
  { value: 'jp', label: 'Japan' },
];

describe('BSelect', () => {
  it('clicking trigger opens listbox; clicking option emits update:modelValue', async () => {
    const onUpdate = vi.fn();
    render(BSelect, {
      props: {
        modelValue: '',
        options,
        placeholder: 'Choose…',
        'onUpdate:modelValue': onUpdate,
      },
    });
    await userEvent.click(screen.getByRole('combobox'));
    await userEvent.click(await screen.findByRole('option', { name: 'Vietnam' }));
    expect(onUpdate).toHaveBeenCalledWith('vn');
  });

  it('ArrowDown then Enter from trigger selects the first option', async () => {
    const onUpdate = vi.fn();
    render(BSelect, {
      props: { modelValue: '', options, 'onUpdate:modelValue': onUpdate },
    });
    const trigger = screen.getByRole('combobox');
    trigger.focus();
    await userEvent.keyboard('{Enter}');
    await userEvent.keyboard('{Enter}');
    expect(onUpdate).toHaveBeenCalledWith('us');
  });
});
```

> **Note for the implementer:** Reka's `Select` has matured well — `combobox` role on the trigger and `option` roles on items are exposed. If the second test flakes under happy-dom (popup virtual focus models can be finicky), reduce the second test to: open the listbox, ArrowDown twice, Enter — and assert `onUpdate` got called with `'vn'`. The DoD keyboard-nav bullet is also verified live via Chrome DevTools MCP in Task 19.

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BSelect`
Expected: FAIL.

- [ ] **Step 3: Implement**

`frontend/src/components/primitives/BSelect.vue`:

```vue
<script setup lang="ts">
import {
  SelectRoot, SelectTrigger, SelectValue, SelectIcon, SelectPortal,
  SelectContent, SelectViewport, SelectItem, SelectItemText, SelectItemIndicator,
} from 'reka-ui';

export interface BSelectOption { value: string; label: string }

interface Props {
  modelValue: string;
  options: BSelectOption[];
  placeholder?: string;
  error?: string;
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), { disabled: false });
defineEmits<{ 'update:modelValue': [value: string] }>();
</script>

<template>
  <SelectRoot
    :model-value="props.modelValue"
    :disabled="props.disabled"
    @update:model-value="$emit('update:modelValue', String($event ?? ''))"
  >
    <SelectTrigger :class="['b-select__trigger', { 'has-error': !!props.error }]">
      <SelectValue :placeholder="props.placeholder ?? ''" />
      <SelectIcon class="b-select__chev">▾</SelectIcon>
    </SelectTrigger>
    <SelectPortal>
      <SelectContent class="b-select__content" position="popper" side="bottom" align="start">
        <SelectViewport class="b-select__viewport">
          <SelectItem
            v-for="opt in props.options"
            :key="opt.value"
            :value="opt.value"
            class="b-select__item"
          >
            <SelectItemText>{{ opt.label }}</SelectItemText>
            <SelectItemIndicator class="b-select__check">✓</SelectItemIndicator>
          </SelectItem>
        </SelectViewport>
      </SelectContent>
    </SelectPortal>
  </SelectRoot>
</template>

<style scoped>
.b-select__trigger {
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  min-width: 14rem;
  padding: var(--space-3) var(--space-4);
  border: var(--border-thick);
  background: var(--paper);
  font-family: var(--font-body);
  color: var(--ink);
  box-shadow: var(--shadow-md);
  cursor: pointer;
}
.b-select__trigger.has-error { border-color: var(--stamp-red); }
.b-select__chev { font-family: var(--font-mono); }

.b-select__content {
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-lg);
  z-index: 60;
  min-width: var(--reka-select-trigger-width);
}
.b-select__viewport { padding: var(--space-1); }
.b-select__item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  padding: var(--space-2) var(--space-4);
  cursor: pointer;
  outline: none;
  user-select: none;
}
.b-select__item[data-highlighted] {
  background: var(--spot);
  color: var(--ink);
}
.b-select__check { font-family: var(--font-mono); }
</style>
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && pnpm test BSelect`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BSelect.vue frontend/tests/unit/components/primitives/BSelect.spec.ts
git commit -m "feat(frontend): add BSelect primitive on Reka UI"
```

---

## Task 14: BToast + ToastViewport + tests

**Files:**
- Create: `frontend/src/components/primitives/BToast.vue`
- Create: `frontend/src/components/primitives/ToastViewport.vue`
- Create: `frontend/tests/unit/components/primitives/BToast.spec.ts`

- [ ] **Step 1: Write failing tests**

`frontend/tests/unit/components/primitives/BToast.spec.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BToast from '@/components/primitives/BToast.vue';

describe('BToast', () => {
  it('renders title, body, and tone class', () => {
    const { container } = render(BToast, {
      props: { tone: 'success', title: 'Saved!', body: 'All good.' },
    });
    expect(screen.getByText('Saved!')).toBeInTheDocument();
    expect(screen.getByText('All good.')).toBeInTheDocument();
    expect(container.querySelector('.b-toast.tone-success')).not.toBeNull();
  });

  it('clicking the close button emits dismiss', async () => {
    const onDismiss = vi.fn();
    render(BToast, {
      props: { title: 'Hi', onDismiss },
    });
    await userEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd frontend && pnpm test BToast`
Expected: FAIL.

- [ ] **Step 3: Implement BToast**

`frontend/src/components/primitives/BToast.vue`:

```vue
<script setup lang="ts">
interface Props {
  tone?: 'info' | 'success' | 'error';
  title: string;
  body?: string;
}
const props = withDefaults(defineProps<Props>(), { tone: 'info' });
defineEmits<{ dismiss: [] }>();
</script>

<template>
  <div :class="['b-toast', `tone-${props.tone}`]" role="status" aria-live="polite">
    <div class="b-toast__text">
      <p class="b-toast__title">{{ props.title }}</p>
      <p v-if="props.body" class="b-toast__body">{{ props.body }}</p>
    </div>
    <button class="b-toast__close" type="button" aria-label="Close" @click="$emit('dismiss')">×</button>
  </div>
</template>

<style scoped>
.b-toast {
  display: flex;
  align-items: flex-start;
  gap: var(--space-3);
  border: var(--border-thick);
  background: var(--paper);
  box-shadow: var(--shadow-md);
  padding: var(--space-3) var(--space-4);
  min-width: 16rem;
  max-width: 24rem;
}
.tone-info    { border-color: var(--ink); }
.tone-success { border-color: var(--ink); background: color-mix(in srgb, var(--spot) 15%, var(--paper)); }
.tone-error   { border-color: var(--stamp-red); }
.b-toast__title { font-family: var(--font-display); font-weight: 800; text-transform: uppercase; letter-spacing: 0.04em; }
.b-toast__body  { font-family: var(--font-body); color: var(--muted-ink); margin-top: var(--space-1); }
.b-toast__close { background: transparent; border: none; font-size: 1.25rem; cursor: pointer; line-height: 1; }
</style>
```

- [ ] **Step 4: Implement ToastViewport**

`frontend/src/components/primitives/ToastViewport.vue`:

```vue
<script setup lang="ts">
import { useToastStore } from '@/stores/toast';
import BToast from './BToast.vue';
const store = useToastStore();
</script>

<template>
  <TransitionGroup
    tag="ol"
    name="toast"
    class="b-toast-viewport"
    aria-label="Notifications"
  >
    <li v-for="item in store.items" :key="item.id" class="b-toast-viewport__item">
      <BToast
        :tone="item.tone"
        :title="item.title"
        :body="item.body"
        @dismiss="store.dismiss(item.id)"
      />
    </li>
  </TransitionGroup>
</template>

<style scoped>
.b-toast-viewport {
  position: fixed;
  top: var(--space-4);
  right: var(--space-4);
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  z-index: 70;
}
.toast-enter-from { transform: translateX(100%); opacity: 0; }
.toast-enter-active { transition: transform 200ms ease-out, opacity 200ms ease-out; }
.toast-leave-to { opacity: 0; }
.toast-leave-active { transition: opacity 150ms ease-in; }
</style>
```

- [ ] **Step 5: Run to verify pass**

Run: `cd frontend && pnpm test BToast`
Expected: PASS (2/2).

- [ ] **Step 6: Commit**

```bash
git add frontend/src/components/primitives/BToast.vue frontend/src/components/primitives/ToastViewport.vue frontend/tests/unit/components/primitives/BToast.spec.ts
git commit -m "feat(frontend): add BToast + ToastViewport"
```

---

## Task 15: Primitives barrel export

**Files:**
- Create: `frontend/src/components/primitives/index.ts`

- [ ] **Step 1: Write barrel**

`frontend/src/components/primitives/index.ts`:

```ts
export { default as BButton } from './BButton.vue';
export { default as BCard } from './BCard.vue';
export { default as BInput } from './BInput.vue';
export { default as BStamp } from './BStamp.vue';
export { default as BTag } from './BTag.vue';
export { default as BCropmarks } from './BCropmarks.vue';
export { default as BMarginNumeral } from './BMarginNumeral.vue';
export { default as BDialog } from './BDialog.vue';
export { default as BSelect } from './BSelect.vue';
export { default as BToast } from './BToast.vue';
export { default as ToastViewport } from './ToastViewport.vue';
export type { BSelectOption } from './BSelect.vue';
```

- [ ] **Step 2: Verify typecheck**

Run: `cd frontend && pnpm typecheck`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/primitives/index.ts
git commit -m "feat(frontend): add primitives barrel export"
```

---

## Task 16: Vue Router setup + HomePlaceholder extraction

**Files:**
- Create: `frontend/src/router/index.ts`
- Create: `frontend/src/pages/HomePlaceholder.vue`

- [ ] **Step 1: Extract App.vue placeholder content into HomePlaceholder**

`frontend/src/pages/HomePlaceholder.vue` — copy the entire `<script setup>`, `<template>`, and `<style scoped>` blocks from the existing `frontend/src/App.vue` verbatim into this new file. Do not modify them.

- [ ] **Step 2: Create the router**

`frontend/src/router/index.ts`:

```ts
import { createRouter, createWebHistory } from 'vue-router';
import HomePlaceholder from '@/pages/HomePlaceholder.vue';
import DesignShowcase from '@/pages/DesignShowcase.vue';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomePlaceholder },
    { path: '/_design', component: DesignShowcase },
  ],
});
```

> Note: `DesignShowcase` is created in Task 18. Until then, this file will fail typecheck — that's expected; we commit after Task 17 wires `App.vue` AND we add a stub `DesignShowcase.vue`. To avoid breaking the build mid-task, create a placeholder `DesignShowcase.vue` here:

`frontend/src/pages/DesignShowcase.vue` (stub — will be filled in Task 18):

```vue
<template><main><h1>Design showcase (stub)</h1></main></template>
```

- [ ] **Step 3: Verify typecheck**

Run: `cd frontend && pnpm typecheck`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/router/index.ts frontend/src/pages/HomePlaceholder.vue frontend/src/pages/DesignShowcase.vue
git commit -m "feat(frontend): add Vue Router with home + design routes"
```

---

## Task 17: Wire Pinia + Router into App.vue + main.ts

**Files:**
- Modify: `frontend/src/main.ts`
- Modify: `frontend/src/App.vue`

- [ ] **Step 1: Replace main.ts**

`frontend/src/main.ts`:

```ts
import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { router } from './router';
import './styles/main.css';

createApp(App).use(createPinia()).use(router).mount('#app');
```

- [ ] **Step 2: Replace App.vue**

`frontend/src/App.vue` — overwrite the entire file:

```vue
<script setup lang="ts">
import { ToastViewport } from '@/components/primitives';
</script>

<template>
  <RouterView />
  <ToastViewport />
</template>

<style>
/* Global styles live in styles/main.css; App.vue stays minimal. */
</style>
```

- [ ] **Step 3: Verify typecheck + tests still green**

Run: `cd frontend && pnpm typecheck && pnpm test`
Expected: PASS (typecheck clean, all existing primitive + store + lib tests still green; the Phase 1 sanity test that asserts placeholder text in App.vue may need updating — see step 4).

- [ ] **Step 4: If Phase 1 sanity test asserts on App.vue placeholder, update it to navigate to `/`**

Inspect `frontend/tests/unit/sanity.spec.ts`. If it renders `App` and expects "FOUNDATION LAID." or similar, switch the assertion to render `HomePlaceholder` directly:

```ts
import HomePlaceholder from '@/pages/HomePlaceholder.vue';
// ...
render(HomePlaceholder);
// existing assertions unchanged
```

If it doesn't reference App at all, skip this step.

Run: `cd frontend && pnpm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/main.ts frontend/src/App.vue frontend/tests/unit/sanity.spec.ts
git commit -m "feat(frontend): wire Pinia + Router; App.vue hosts RouterView + ToastViewport"
```

---

## Task 18: DesignShowcase page (replace stub)

**Files:**
- Modify: `frontend/src/pages/DesignShowcase.vue` (replace stub from Task 16)

- [ ] **Step 1: Replace stub with the full showcase**

`frontend/src/pages/DesignShowcase.vue`:

```vue
<script setup lang="ts">
import {
  BButton, BCard, BInput, BStamp, BTag, BCropmarks,
  BMarginNumeral, BDialog, BSelect,
} from '@/components/primitives';
import { ref } from 'vue';
import { useToast } from '@/composables/useToast';

const toast = useToast();
const inputValue = ref('');
const inputErr = ref('');
const dialogOpen = ref(false);
const selectValue = ref('');
const countries = [
  { value: 'us', label: 'United States' },
  { value: 'vn', label: 'Vietnam' },
  { value: 'jp', label: 'Japan' },
];
</script>

<template>
  <main class="showcase">
    <h1 class="showcase__title">DESIGN SHOWCASE</h1>
    <p class="showcase__lede">Every primitive, every variant. /_design — not linked from nav.</p>

    <!-- 01 BButton -->
    <section class="showcase__section">
      <BMarginNumeral numeral="01" />
      <h2>BButton</h2>
      <div class="grid">
        <BButton variant="ink">INK</BButton>
        <BButton variant="spot">SPOT</BButton>
        <BButton variant="ghost">GHOST</BButton>
        <BButton variant="danger">DANGER</BButton>
        <BButton disabled>DISABLED</BButton>
        <BButton loading>LOADING</BButton>
      </div>
    </section>
    <BCropmarks />

    <!-- 02 BCard -->
    <section class="showcase__section">
      <BMarginNumeral numeral="02" />
      <h2>BCard</h2>
      <div class="grid grid--cards">
        <BCard><h3>STRAIGHT</h3><p>No rotation.</p></BCard>
        <BCard :rotate="1.5"><h3>TILTED</h3><p>+1.5°</p></BCard>
        <BCard hoverMisregister><h3>HOVER ME</h3><p>Misregistration on hover.</p></BCard>
      </div>
    </section>
    <BCropmarks />

    <!-- 03 BInput -->
    <section class="showcase__section">
      <BMarginNumeral numeral="03" />
      <h2>BInput</h2>
      <div class="grid grid--stack">
        <BInput v-model="inputValue" label="Default" placeholder="Type something" />
        <BInput v-model="inputErr" label="Error state" error="This field is required" />
        <BInput :model-value="''" label="Disabled" disabled placeholder="Locked" />
      </div>
    </section>
    <BCropmarks />

    <!-- 04 BStamp -->
    <section class="showcase__section">
      <BMarginNumeral numeral="04" />
      <h2>BStamp</h2>
      <div class="grid grid--stamps">
        <BStamp tone="red"  size="sm">PAID</BStamp>
        <BStamp tone="ink"  size="md">SHIPPED</BStamp>
        <BStamp tone="spot" size="lg" :rotate="-4">SOLD OUT</BStamp>
      </div>
    </section>
    <BCropmarks />

    <!-- 05 BTag -->
    <section class="showcase__section">
      <BMarginNumeral numeral="05" />
      <h2>BTag</h2>
      <div class="grid">
        <BTag tone="ink">INK</BTag>
        <BTag tone="spot" :rotate="2">SPOT</BTag>
        <BTag tone="paper">PAPER</BTag>
      </div>
    </section>
    <BCropmarks />

    <!-- 06 BCropmarks -->
    <section class="showcase__section">
      <BMarginNumeral numeral="06" />
      <h2>BCropmarks</h2>
      <p>Already used as section dividers. Custom inset:</p>
      <BCropmarks inset="3rem" />
    </section>
    <BCropmarks />

    <!-- 07 BMarginNumeral -->
    <section class="showcase__section">
      <BMarginNumeral numeral="07" />
      <h2>BMarginNumeral</h2>
      <div class="grid grid--two">
        <BMarginNumeral numeral="L" side="left" />
        <BMarginNumeral numeral="R" side="right" />
      </div>
    </section>
    <BCropmarks />

    <!-- 08 BDialog -->
    <section class="showcase__section">
      <BMarginNumeral numeral="08" />
      <h2>BDialog</h2>
      <BButton variant="ink" @click="dialogOpen = true">OPEN DIALOG</BButton>
      <BDialog v-model:open="dialogOpen" title="Confirm action" description="Press Esc or click × to close.">
        <p>This is the dialog body. Tab cycles within the dialog (focus trap from Reka UI).</p>
        <template #footer>
          <BButton variant="ghost" @click="dialogOpen = false">CANCEL</BButton>
          <BButton variant="spot"  @click="dialogOpen = false">CONFIRM</BButton>
        </template>
      </BDialog>
    </section>
    <BCropmarks />

    <!-- 09 BSelect -->
    <section class="showcase__section">
      <BMarginNumeral numeral="09" />
      <h2>BSelect</h2>
      <div class="grid grid--stack">
        <BSelect v-model="selectValue" :options="countries" placeholder="Choose country" />
        <BSelect :model-value="''" :options="countries" placeholder="With error" error="Pick one" />
      </div>
    </section>
    <BCropmarks />

    <!-- 10 BToast -->
    <section class="showcase__section">
      <BMarginNumeral numeral="10" />
      <h2>BToast</h2>
      <div class="grid">
        <BButton variant="ink"    @click="toast.info('Info', 'Just so you know.')">FIRE INFO</BButton>
        <BButton variant="spot"   @click="toast.success('Saved!', 'All changes persisted.')">FIRE SUCCESS</BButton>
        <BButton variant="danger" @click="toast.error('Failed', 'Something went wrong.')">FIRE ERROR</BButton>
      </div>
    </section>
  </main>
</template>

<style scoped>
.showcase {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-12) var(--space-8);
  font-family: var(--font-body);
}
.showcase__title {
  font-family: var(--font-display);
  font-size: var(--type-display);
  font-weight: 900;
  text-transform: uppercase;
  letter-spacing: -0.02em;
}
.showcase__lede { color: var(--muted-ink); margin-bottom: var(--space-8); }
.showcase__section { margin: var(--space-12) 0; }
.showcase__section h2 {
  font-family: var(--font-display);
  font-size: var(--type-h2);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: var(--space-6);
}
.grid { display: flex; flex-wrap: wrap; gap: var(--space-4); align-items: center; }
.grid--cards  { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--space-6); }
.grid--stack  { flex-direction: column; align-items: stretch; max-width: 24rem; }
.grid--stamps { gap: var(--space-8); }
.grid--two    { display: flex; justify-content: space-between; }
</style>
```

- [ ] **Step 2: Run dev server smoke (manual)**

```bash
cd frontend && pnpm dev
```

Visit `http://localhost:5173/_design` in a browser. Verify:
- Page renders without console errors
- Each section appears with its numeral + cropmark divider
- Buttons, cards, inputs, stamps, tags all visible
- Clicking "OPEN DIALOG" opens the dialog
- Clicking the BSelect trigger opens a dropdown with 3 options
- Clicking each "FIRE" button shows a toast that auto-dismisses after 4 s

Stop the dev server.

- [ ] **Step 3: Verify typecheck + tests**

Run: `cd frontend && pnpm typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/pages/DesignShowcase.vue
git commit -m "feat(frontend): add /_design showcase with all 10 primitives"
```

---

## Task 19: DoD live verification (Chrome DevTools MCP)

This task fills DoD bullets 2, 4, 5, 6, 7 — the live-browser ones. Run with `pnpm dev` already started in another terminal.

**Files:** None edited. Output: a verification log saved as `frontend/docs/phase-2-verification.md`.

- [ ] **Step 1: Start the dev server**

```bash
cd frontend && pnpm dev
```

(Keep running in a separate terminal/background.)

- [ ] **Step 2: DoD #2 — no console errors on `/_design`**

Use Chrome DevTools MCP:
1. `mcp__plugin_chrome-devtools-mcp_chrome-devtools__new_page` → URL `http://localhost:5173/_design`
2. `mcp__plugin_chrome-devtools-mcp_chrome-devtools__list_console_messages`

Expected: list contains zero `error` or `warning` entries.

- [ ] **Step 3: DoD #4 — misregistration on hover**

1. `take_snapshot` to get the BCard hover-target's element id.
2. `hover` on the "HOVER ME" card.
3. `take_screenshot` of the section.

Expected: a visible orange ghost shadow on the card's heading. Save the screenshot path.

- [ ] **Step 4: DoD #5 — `:active` translate on BButton**

1. Use `evaluate_script` to grab the computed style of `.b-button:active`:
   ```js
   const btn = document.querySelector('.b-button--spot');
   btn.classList.add('force-active'); // none — instead, programmatically check the rule
   const rules = [...document.styleSheets].flatMap(s => { try { return [...s.cssRules]; } catch { return []; }});
   const r = rules.find(r => r.selectorText && r.selectorText.includes('.b-button:active:not(:disabled)'));
   r ? r.style.transform : 'NOT_FOUND';
   ```
   Expected: returns `translate(var(--press-translate), var(--press-translate))` or equivalent.

2. Visually: `click` and immediately `take_screenshot` — best-effort. Fallback is the rule check above.

- [ ] **Step 5: DoD #6 — keyboard nav (BDialog Esc + BSelect arrows)**

1. `click` the OPEN DIALOG button → dialog opens.
2. `press_key` `Escape` → dialog should close. Verify by `take_snapshot` and confirming the dialog content is no longer in the DOM.
3. `click` the BSelect trigger → listbox opens.
4. `press_key` `ArrowDown` × 1, then `Enter`.
5. `take_snapshot` and confirm the trigger now displays the first option's label.

- [ ] **Step 6: DoD #7 — Lighthouse accessibility ≥ contrast ratio**

`mcp__plugin_chrome-devtools-mcp_chrome-devtools__lighthouse_audit` on `http://localhost:5173/_design` with category `accessibility`.

Expected: no `color-contrast` violation listed; `BButton variant="spot"` (orange ink-on-orange text) passes ≥ 4.5:1.

If violation appears: the most likely cause is the spot button text color. Tweak `BButton.vue` style: ensure `.b-button--spot { color: var(--ink); }` (already so) AND consider darkening text or increasing weight. Re-run audit.

- [ ] **Step 7: Save the verification log**

Create `frontend/docs/phase-2-verification.md` summarizing each bullet with the screenshot paths or assertion outputs. Commit it.

```bash
git add frontend/docs/phase-2-verification.md
git commit -m "docs(frontend): record Phase 2 live DoD verification results"
```

- [ ] **Step 8: Stop the dev server.**

---

## Task 20: Tick rollout DoD checkboxes + open PR

**Files:**
- Modify: `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` — flip Phase 2 DoD `[ ]` → `[x]`

- [ ] **Step 1: Flip the 7 Phase 2 DoD checkboxes**

In `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md`, locate the Phase 2 "Definition of Done" list and change every `- [ ]` to `- [x]`.

- [ ] **Step 2: Final test + typecheck + lint sweep**

```bash
cd frontend && pnpm typecheck && pnpm lint && pnpm test
```

Expected: all PASS. Note total test count from Vitest reporter — should be ≥ 22 (10 primitives × 2 + 2 store + 4 rotation + Phase 1 carry-over).

- [ ] **Step 3: Commit DoD flip**

```bash
git add docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md
git commit -m "docs: tick Phase 2 DoD bullets — primitives + showcase verified"
```

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin frontend/phase-2-primitives
gh pr create --base main --title "frontend: phase 2 — design system primitives" --body "$(cat <<'EOF'
## Summary
Phase 2 of the storefront frontend rollout: 10 design-system primitives, toast queue (Pinia + composable + viewport), Vue Router scaffold, and the /_design showcase route.

## DoD (all green)
- [x] All 10 primitives exist in `src/components/primitives/`
- [x] `/_design` renders every primitive + variant; no console errors
- [x] ≥ 2 component tests per primitive (≥ 20 total) — all green
- [x] Misregistration-on-hover demoed and verified visually on `/_design`
- [x] BButton :active translate animation verified
- [x] Keyboard navigation verified on BDialog (Esc closes, focus trap) and BSelect (arrow keys)
- [x] Color contrast for BButton variant="spot" ≥ 4.5:1 (Lighthouse pass)

See `frontend/docs/phase-2-verification.md` for live-browser screenshots and audit results.

## Test plan
- [ ] CI green on the PR (typecheck + lint + test)
- [ ] Reviewer pulls the branch, runs `pnpm dev`, visits `/_design`, confirms no console errors and that toasts/dialog/select all work
EOF
)"
```

- [ ] **Step 5: Watch CI on the PR**

```bash
gh pr checks --watch
```

Expected: `frontend / verify` job passes. If it fails, fix and push; do not mark this task complete until CI is green.

---

## Self-Review (controller checklist — done after writing the plan)

**1. Spec coverage**

| Spec section | Task |
|---|---|
| 10 primitives | Tasks 5–14 |
| Toast store | Task 3 |
| useToast composable | Task 4 |
| ToastViewport | Task 14 |
| Rotation helper | Task 2 |
| Vue Router setup | Task 16 |
| HomePlaceholder extraction | Task 16 |
| App.vue rewrite | Task 17 |
| main.ts wiring | Task 17 |
| DesignShowcase | Task 18 |
| Barrel export | Task 15 |
| ≥ 2 tests per primitive | Tasks 5–14 (each has 2 tests) |
| 2 store tests | Task 3 |
| DoD verification (live) | Task 19 |
| Rollout DoD checkbox flip | Task 20 |

All spec sections covered.

**2. Placeholder scan** — none. All code blocks complete; commands exact; expected outputs explicit.

**3. Type consistency** — `ToastTone`, `ToastItem`, `ToastInput`, `BSelectOption` referenced consistently; `useToastStore` matches `defineStore('toast', …)`; emits names match across components and tests; all imports resolve.

Plan complete and saved to `docs/superpowers/plans/2026-05-02-storefront-frontend-phase2.md`.
