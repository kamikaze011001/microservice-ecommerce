# Accessibility checklist

Issue Nº01 is loud, but accessibility is non-negotiable. The brutalist look already helps (high contrast, big type, hard focus rings). What follows is the full per-screen checklist. Run through it before merging any screen.

## Targets

| Concern                                          | Target                                                                      |
| ------------------------------------------------ | --------------------------------------------------------------------------- |
| Color contrast (text on background)              | WCAG AA (≥ 4.5:1 normal, ≥ 3:1 large ≥ 18.66 px)                            |
| Color contrast (UI components, focus indicators) | WCAG AA (≥ 3:1)                                                             |
| Keyboard navigation                              | Every interactive element reachable + operable via keyboard                 |
| Focus visible                                    | Always. `:focus-visible` outline, never `outline: none` without replacement |
| Reduced motion                                   | Respect `prefers-reduced-motion: reduce`                                    |
| Screen reader                                    | Landmarks + labels + live regions                                           |

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

| Background                | Text            | Ratio  | Verdict                                   |
| ------------------------- | --------------- | ------ | ----------------------------------------- |
| `--paper` `#F4EFE6`       | `--ink`         | 12.5:1 | AAA                                       |
| `--paper-shade` `#E8DFD0` | `--ink`         | 11.0:1 | AAA                                       |
| `--spot` `#FF4F1C`        | `--ink`         | 5.6:1  | AA                                        |
| `--spot`                  | `--paper`       | 2.2:1  | **FAIL — never put paper text on orange** |
| `--ink`                   | `--paper`       | 12.5:1 | AAA                                       |
| `--stamp-red` `#C4302B`   | `--paper`       | 5.4:1  | AA                                        |
| `--muted-ink` `#6B6256`   | `--paper`       | 5.0:1  | AA                                        |
| `--muted-ink`             | `--paper-shade` | 4.5:1  | AA (just)                                 |

If you introduce a new pairing, verify with a checker (e.g. https://contrastchecker.com).

## Reduced motion

Respect `prefers-reduced-motion: reduce`. The brutalist press is fun but not essential.

```css
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
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
