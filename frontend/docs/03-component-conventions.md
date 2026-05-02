# Component conventions

## Two layers, no exceptions

| Layer      | Path                           | What                                                   | Example                       |
| ---------- | ------------------------------ | ------------------------------------------------------ | ----------------------------- |
| Primitives | `src/components/primitives/B*` | Pure styling/behaviour, no API/auth/store knowledge    | `BButton`, `BInput`, `BStamp` |
| Domain     | `src/components/domain/`       | Composes primitives + queries; embeds business meaning | `ProductCard`, `CartLineItem` |

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
  transition:
    transform var(--transition-snap),
    box-shadow var(--transition-snap);
}
.b-button:active {
  transform: translate(var(--press-translate), var(--press-translate));
  box-shadow: var(--shadow-sm);
}
.b-button--spot {
  background: var(--spot);
  color: var(--ink);
}
.b-button--ink {
  background: var(--ink);
  color: var(--paper);
}
.b-button--ghost {
  background: transparent;
  box-shadow: none;
}
.b-button--danger {
  background: var(--stamp-red);
  color: var(--paper);
}
.b-button:focus-visible {
  outline: 3px solid var(--spot);
  outline-offset: 2px;
}
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
