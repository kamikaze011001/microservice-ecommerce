---
name: migrating-styled-buttons-to-biconbutton
description: Migrating a bordered/styled raw <button> to BIconButton keeps its look via a retained page class — parent scoped CSS wins the specificity tie
metadata: { type: convention, date: 2026-07-09 }
---
When migrate-sweep replaces a **visually-styled** raw `<button>` (visible border,
background, fixed size) with `BIconButton` — whose base `.b-icon-button` is
transparent / `border:0` / `padding:0` — keep the page-level class on the primitive
(`<BIconButton class="line__step" …>`). The page's appearance is preserved.

**Why it works:** In Vue SFC scoped styles both selectors end up equal-specificity —
`.line__step[data-v-parent]` (0,2,0) vs `.b-icon-button[data-v-child]` (0,2,0), because
a child component's root element inherits the parent's scope attribute too. Equal
specificity → source order decides, and Vite injects the **imported child's** styles
*before* the **parent's** (imports resolve first). So the parent class is defined later
and wins the tie — the retained `.line__step` border/background overrides the
primitive's transparent base. This is why AppNav's `<BIconButton class="app-nav__toggle">`
and CartLineItem's steppers both kept their custom look.

**How to apply:** For every glyph/icon button (single symbol + `aria-label`) → use
`BIconButton`, retain the existing class, and preserve `:disabled` / `@click` / `type` /
`aria-label` verbatim. `BIconButton` renders a real `<button>` with `aria-label`
fall-through, so tests querying by role/accessible-name still pass. Do NOT edit the
primitive to accommodate a page's border — that would break the page-only blast radius.
Caveat: the consistency gate counts raw elements only, so it confirms structural
completion but NOT visual regressions — the guarantee comes from keeping the class +
bindings, not from the gate. Related: [[a11y-guards-jsdom-pin-is-insurance]].
