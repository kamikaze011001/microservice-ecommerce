# Storefront Frontend — Phase 2 (Design System Primitives) Design

**Date:** 2026-05-02
**Status:** Draft
**Phase:** 2 of 7 (per `2026-05-01-storefront-frontend-rollout.md`)
**Companion specs:**
- [`2026-05-01-storefront-frontend-design.md`](./2026-05-01-storefront-frontend-design.md) — overall product/visual design
- [`2026-05-01-storefront-frontend-rollout.md`](./2026-05-01-storefront-frontend-rollout.md) — phased plan (this phase = Phase 2)

## Goal

Implement every design-system primitive listed in the companion design spec, render them in an in-repo showcase route, and cover each primitive with isolated component tests. No domain components, no API code, no router beyond what's needed to mount the showcase.

## Locked-in decisions

| # | Decision | Reason |
|---|---|---|
| 1 | Toast queue lives in a Pinia store; `useToast()` composable pushes; one `<ToastViewport>` mounted in `App.vue` | Toasts must fire from non-component code (mutation `onSuccess`); singleton viewport prevents duplicated positioning logic |
| 2 | Pure CSS + Vue `<Transition>`/`<TransitionGroup>` for all motion. No JS animation library. | Risograph aesthetic is anti-fluid; `steps(2)` snap easing is trivial in CSS; avoids ~30KB and a JS-driven runtime that fights the "snap" intent |
| 3 | `BSelect` built on Reka UI `Select` parts now, with full keyboard nav | Rollout DoD requires "arrow keys verified on BSelect"; doing it twice (native then Reka) is waste |
| 4 | Rotation is deterministic — callers pass `rotate` explicitly. No `Math.random()` in components. | Cards must not re-rotate on re-render. Sticker feel comes from a hashed-id helper in `lib/rotation.ts` |
| 5 | `/_design` is always built, not linked from nav, reachable only by typing the URL | Cheap insurance for visual regressions; prod cost ≈ 15KB gzipped |
| 6 | Vue Router added now, with two routes: `/` (Phase 1 placeholder, extracted into a page) and `/_design` (showcase) | Router is needed for `/_design` mount; Phase 3 trivially extends it |
| 7 | `BInput` is form-agnostic in Phase 2 — exposes `error?: string` prop only. VeeValidate wiring lands in Phase 3. | Keeps primitives library decoupled from form library; Phase 3 adds an adapter |

## Scope

### In scope

- 10 primitives: `BButton`, `BCard`, `BInput`, `BStamp`, `BTag`, `BCropmarks`, `BMarginNumeral`, `BDialog`, `BSelect`, `BToast`
- Toast queue: `stores/toast.ts`, `composables/useToast.ts`, `ToastViewport.vue`
- Vue Router with two routes (`/`, `/_design`)
- `DesignShowcase.vue` page rendering every primitive + every variant
- Component tests: ≥ 2 per primitive (≥ 20 total) + 2 store tests
- New deps: `pinia ^2.2`, `reka-ui ^1.x`, `vue-router ^4.4`
- `lib/rotation.ts` deterministic-hash helper

### Out of scope (defer to later phases)

- Domain components (`ProductCard`, `CartLineItem`, etc.) — Phase 4+
- VeeValidate / Zod integration — Phase 3
- API client, auth store, query layer — Phase 3
- Playwright e2e — Phase 7
- Linking `/_design` from any user-facing nav

## File layout

```
frontend/src/
  components/primitives/
    BButton.vue
    BCard.vue
    BInput.vue
    BStamp.vue
    BTag.vue
    BCropmarks.vue
    BMarginNumeral.vue
    BDialog.vue
    BSelect.vue
    BToast.vue
    ToastViewport.vue
    index.ts                       # barrel export
  composables/
    useToast.ts
  stores/
    toast.ts                        # Pinia
  lib/
    rotation.ts                     # hashId(seed: string) -> number in [-0.5, 0.5]
  pages/
    HomePlaceholder.vue             # extracted from current App.vue
    DesignShowcase.vue              # /_design
  router/
    index.ts                        # createRouter, two routes
  App.vue                           # now hosts <RouterView /> + <ToastViewport />
  main.ts                           # registers router + Pinia
frontend/tests/
  components/primitives/
    BButton.test.ts
    BCard.test.ts
    BInput.test.ts
    BStamp.test.ts
    BTag.test.ts
    BCropmarks.test.ts
    BMarginNumeral.test.ts
    BDialog.test.ts
    BSelect.test.ts
    BToast.test.ts
  stores/
    toast.test.ts
```

## Component contracts

Defaults shown in **bold**. All components are typed via `defineProps<…>()` with explicit interfaces; no runtime prop validators.

| Component | Props | Slots | Emits |
|---|---|---|---|
| `BButton` | `variant: 'spot' \| 'ink' \| 'ghost' \| 'danger' = **'ink'**`, `type: 'button' \| 'submit' \| 'reset' = **'button'**`, `disabled = **false**`, `loading = **false**` | default | `click(event: MouseEvent)` |
| `BCard` | `rotate?: number` (degrees, e.g. `0.5`), `hoverMisregister = **false**`, `as = **'article'**` | default, `header`, `footer` | — |
| `BInput` | `modelValue: string`, `type = **'text'**`, `label?: string`, `error?: string`, `id?: string` (auto-generated if omitted), `placeholder?` | — | `update:modelValue(value: string)`, `blur(event: FocusEvent)` |
| `BStamp` | `tone: 'red' \| 'ink' \| 'spot' = **'red'**`, `rotate?: number`, `size: 'sm' \| 'md' \| 'lg' = **'md'**` | default (label) | — |
| `BTag` | `tone: 'ink' \| 'spot' \| 'paper' = **'ink'**`, `rotate?: number` | default | — |
| `BCropmarks` | `inset: string = **'1rem'**` | — | — |
| `BMarginNumeral` | `numeral: string` (e.g. `'01'`), `side: 'left' \| 'right' = **'left'**` | — | — |
| `BDialog` | `open: boolean`, `title: string`, `description?: string` | default, `footer` | `update:open(value: boolean)` |
| `BSelect` | `modelValue: string`, `options: { value: string; label: string }[]`, `placeholder?: string`, `error?: string`, `disabled = **false**` | — | `update:modelValue(value: string)` |
| `BToast` | `tone: 'info' \| 'success' \| 'error' = **'info'**`, `title: string`, `body?: string` | — | `dismiss()` |

`BToast` is presentation-only. Auto-dismiss timer lives in the toast store, not the component.

## Toast architecture

```
useToast()
  └─ toast.success/info/error(title, body?, opts?) ─push─▶ stores/toast.ts (Pinia)
                                                             └─ items: ToastItem[]  ◀──── reactive
                                                                                              ▼
                                                                             <ToastViewport> in App.vue
                                                                                renders <BToast> per item
```

### `stores/toast.ts`

Defined as `defineStore('toast', () => { … })` (Composition API style). Importable via `useToastStore()`.

```ts
type ToastTone = 'info' | 'success' | 'error';
interface ToastItem {
  id: string;
  tone: ToastTone;
  title: string;
  body?: string;
  duration: number;
}

// state
items: Ref<ToastItem[]>

// actions
push(input: { tone?: ToastTone; title: string; body?: string; duration?: number }): string
dismiss(id: string): void
clear(): void
```

`push` generates an id (`crypto.randomUUID()`), appends to `items`, schedules `setTimeout(() => dismiss(id), duration)` (default 4000 ms), and stores the timer handle in a `Map<id, NodeJS.Timeout>` private to the store. `dismiss` clears the timer and removes the item.

### `composables/useToast.ts`

Thin wrapper:

```ts
export function useToast() {
  const store = useToastStore();
  return {
    success: (title: string, body?: string, opts?: { duration?: number }) =>
      store.push({ tone: 'success', title, body, ...opts }),
    info:    (title: string, body?: string, opts?: { duration?: number }) =>
      store.push({ tone: 'info',    title, body, ...opts }),
    error:   (title: string, body?: string, opts?: { duration?: number }) =>
      store.push({ tone: 'error',   title, body, ...opts }),
    dismiss: store.dismiss,
  };
}
```

Importable from any component, composable, or plain TS module (e.g. mutation `onSuccess` callbacks in Phase 3+).

### `ToastViewport.vue`

Mounted exactly once in `App.vue`. Fixed position top-right (16px inset). Renders `<TransitionGroup tag="ol" name="toast">` over `store.items`, mapping each to `<BToast>` with a `@dismiss="store.dismiss(item.id)"` listener.

CSS-only transitions:
- enter: translateX(100%) → 0 over 200ms ease-out
- leave: opacity 1 → 0 over 150ms ease-in

## BSelect on Reka UI

`BSelect.vue` wraps Reka's `Select` parts:

```vue
<SelectRoot v-model="model" :disabled>
  <SelectTrigger :class="['b-select-trigger', { 'has-error': error }]">
    <SelectValue :placeholder />
    <SelectIcon><!-- inline chevron SVG --></SelectIcon>
  </SelectTrigger>
  <SelectPortal>
    <SelectContent class="b-select-content" position="popper" side="bottom" align="start">
      <SelectViewport>
        <SelectItem
          v-for="opt in options"
          :key="opt.value"
          :value="opt.value"
          class="b-select-item"
        >
          <SelectItemText>{{ opt.label }}</SelectItemText>
        </SelectItem>
      </SelectViewport>
    </SelectContent>
  </SelectPortal>
</SelectRoot>
```

**Styling:**
- Trigger: thick ink border, `--shadow-md`, paper background, ink text. Error state flips border to `--stamp-red`.
- Content: paper card, thick ink border, `--shadow-lg`, no rounded corners.
- Item highlighted (`data-highlighted` Reka attribute, set by hover or keyboard focus): spot background + paper text.
- Item selected: bold weight + small inline checkmark.

**A11y comes from Reka:** ArrowUp/Down navigates, Home/End jump to ends, Enter/Space selects, Esc closes, type-ahead works, focus returns to trigger on close, all `aria-*` attributes wired correctly. We restyle, not rebuild.

## Rotation helper

`src/lib/rotation.ts`:

```ts
export function hashRotate(seed: string, maxDegrees = 0.5): number {
  // FNV-1a 32-bit hash → deterministic float in [-maxDegrees, maxDegrees]
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const norm = (h >>> 0) / 0xffffffff;     // 0..1
  return (norm * 2 - 1) * maxDegrees;       // -max..max
}
```

Domain components in later phases will pass `:rotate="hashRotate(product.id)"` to `<BCard>`. Phase 2 only ships the helper; the showcase demos it with hard-coded rotations like `1.5`, `-0.8`.

## `/_design` showcase route

`DesignShowcase.vue` is a single long page divided by `<BCropmarks>`. One section per primitive, in this order:

1. **BButton** — 4 variants × 5 states (`default`, `hover` annotated, `active` annotated, `disabled`, `loading`) = grid of 20 buttons
2. **BCard** — three cards: `rotate=0`, `rotate=1.5`, `hoverMisregister=true` (caption: "hover me")
3. **BInput** — three inputs: default, with label, with error message, disabled
4. **BStamp** — 3 tones × 3 sizes grid; one with `rotate=-4`
5. **BTag** — 3 tones in a row; one with `rotate=2`
6. **BCropmarks** — standalone block with custom inset
7. **BMarginNumeral** — two examples, `side="left"` and `side="right"`, demonstrating page-edge anchoring
8. **BDialog** — button "Open Dialog" → opens dialog with title, body, and footer slot containing Cancel + Confirm
9. **BSelect** — two selects: a 3-option demo, and an error-state version
10. **BToast** — three buttons: "Fire success", "Fire info", "Fire error" — call `useToast()` directly

Section headers use `<BMarginNumeral numeral="01" />` … `"10"`.

`DesignShowcase` does NOT register any user data, fetch any API, or use any store other than the toast store. It's pure component rendering.

## Router

`src/router/index.ts`:

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

`main.ts`:

```ts
import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { router } from './router';
import './styles/main.css';

createApp(App).use(createPinia()).use(router).mount('#app');
```

`App.vue`:

```vue
<template>
  <RouterView />
  <ToastViewport />
</template>
```

## Testing strategy

Vitest + happy-dom + `@testing-library/vue` + `@testing-library/jest-dom` (already configured in Phase 1).

### Per-primitive tests (≥ 2 each = ≥ 20 total)

| Primitive | Test 1 (happy path) | Test 2 (variant/state) |
|---|---|---|
| BButton | renders default-slot text; click emits `click` event once | `disabled=true` blocks click emission; `loading=true` renders a spinner element |
| BCard | renders default slot inside the wrapping element | `hoverMisregister=true` adds the `is-misregister` class on `:hover` (verified via `userEvent.hover`) |
| BInput | `v-model` two-way binding: typing emits `update:modelValue` with the new value | `error="Required"` renders the error text and applies the `has-error` class |
| BStamp | renders default-slot label | `tone="ink"` applies the `tone-ink` class |
| BTag | renders default slot | `rotate=2` sets `transform: rotate(2deg)` inline style |
| BCropmarks | renders 4 corner-mark elements | `inset="2rem"` propagates to a CSS custom property |
| BMarginNumeral | renders the `numeral` prop text | `side="right"` applies `side-right` class |
| BDialog | `open=true` renders content in a portal; pressing Esc emits `update:open` with `false` | focus trap: pressing Tab from the last focusable element wraps to the first |
| BSelect | clicking trigger opens the listbox; clicking an option emits `update:modelValue` with that option's value | ArrowDown then Enter from the trigger selects the first option (emits its value) |
| BToast | renders the `tone` prop's class; renders title and optional body | clicking the close button emits `dismiss` |

### Store tests (`stores/toast.test.ts`)

1. `push({ title })` adds an item with a uuid, `tone: 'info'`, `duration: 4000`. After 4000 ms (faked timers), the item is removed from `items`.
2. `dismiss(id)` removes the item immediately AND cancels the auto-dismiss timer (verified by advancing fake timers past 4000 ms and asserting no double-dismiss).

### What we do NOT test in Phase 2

- `DesignShowcase.vue` — the page IS the visual test; unit-testing it would duplicate primitive tests
- `ToastViewport.vue` — covered transitively by store + BToast tests
- Cross-primitive integration — Phase 4+ when domain components compose primitives
- Visual regression — Phase 7 polish

### DoD verification (Chrome DevTools MCP)

Three of the seven DoD bullets cannot be verified by `pnpm test` alone:

- **Misregistration on hover** → `navigate_page /_design` → `hover` on the BCard demo → `take_screenshot` → confirm offset visually
- **BButton :active translate** → `navigate_page` → press-and-hold via `evaluate_script` to set `:active`, OR rapid click + screenshot timing
- **Color contrast ≥ 4.5:1** → `lighthouse_audit` on `/_design`, accessibility category, assert no contrast violations on `BButton variant="spot"`
- **Keyboard nav** verified twice: in unit tests (BDialog Esc, BSelect ArrowDown+Enter) AND live in browser via `press_key` to catch regressions the unit-test environment misses (e.g., real focus management)

## Definition of Done (verbatim from rollout, with verification)

| # | Bullet | Verification |
|---|---|---|
| 1 | All 10 primitives exist in `src/components/primitives/` | `ls`; barrel `index.ts` exports each |
| 2 | `/_design` renders every primitive + variant; no console errors | Chrome DevTools MCP `list_console_messages` after `navigate_page` returns empty error list |
| 3 | ≥ 2 component tests per primitive (≥ 20 total), all green | `pnpm test` exit 0; test count from reporter |
| 4 | Misregistration-on-hover demoed and verified visually on `/_design` | DevTools `hover` + `take_screenshot` |
| 5 | `BButton :active` translate animation verified | DevTools click + screenshot |
| 6 | Keyboard navigation verified on BDialog (Esc closes, focus trap) and BSelect (arrow keys) | Unit tests + DevTools `press_key` smoke |
| 7 | Color contrast verified for `BButton variant="spot"` ink-on-orange text (AA, ≥ 4.5:1) | DevTools `lighthouse_audit` accessibility |

## Risks & open questions

- **Reka UI Vue API shape** may have changed since spec drafting; if the `Select` parts have renamed since `^1.x`, swap to actual exports during implementation. Plan task should pin the lockfile-installed version.
- **Focus trap test reliability** under happy-dom (no real layout/focus behavior) — if happy-dom can't faithfully test Tab cycling, mark that single sub-bullet as "verified live in browser" and keep the unit test for the Esc-closes path.
- **BButton `:active` mid-press screenshot timing** — fragile in headless. Acceptable fallback: assert via `getComputedStyle` in unit test that the `:active` rule sets `translate` correctly, then manual visual smoke in DevTools.

## Companion artifacts

After this spec is approved:
1. `docs/superpowers/plans/2026-05-02-storefront-frontend-phase2.md` — granular task plan, produced via `superpowers:writing-plans`
2. PR `frontend: phase 2 — design system primitives` against `main`, with all 7 DoD bullets in the description
