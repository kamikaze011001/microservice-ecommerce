# Design tokens — Issue Nº01

The Issue Nº01 risograph-zine identity. Tokens are defined in
[`src/styles/tokens.css`](../src/styles/tokens.css) — that file is the source of truth.
This doc is intent + usage. Update both together.

## Palette — risograph two-tone + one spot

| Token           | Hex       | Intent                                                                               |
| --------------- | --------- | ------------------------------------------------------------------------------------ |
| `--paper`       | `#F4EFE6` | Warm off-white. Page background.                                                     |
| `--paper-shade` | `#E8DFD0` | Card / surface contrast against paper.                                               |
| `--ink`         | `#1C1C1C` | Warm charcoal. Text + borders.                                                       |
| `--muted-ink`   | `#6B6256` | Secondary text, hints, colophon.                                                     |
| `--spot`        | `#FF4F1C` | Fluorescent riso orange. **Every CTA, focus ring, alert.** Singular memorable thing. |
| `--stamp-red`   | `#C4302B` | Stamps + inspection marks only — `<BStamp>`, validation borders. Never a CTA.        |

**Restraint matters.** Two-tone everywhere else makes orange punch.
Don't introduce a fourth or fifth colour without a token + ADR.

## Type stack — distinctive, free, self-hosted

| Role    | Family                               | Where                                              |
| ------- | ------------------------------------ | -------------------------------------------------- |
| Display | **Bricolage Grotesque** weight 900   | Hero titles, page numerals, big stamps             |
| Body    | **Cabinet Grotesk** Regular / Medium | Default body, buttons, cards                       |
| Mono    | **Departure Mono**                   | SKUs, order IDs, prices, timestamps, kicker labels |

`--type-display`, `--type-h1`, `--type-h2`, `--type-body`, `--type-small`, `--type-mono` are scaled with `clamp()` for fluid type. Don't hard-code `font-size: 32px;` — pick the closest scale token.

**Banned:** Inter, Archivo Black, system-ui as primary, Roboto.

## Borders & shadows — thick + hard offset

| Token            | Value                    | Use                          |
| ---------------- | ------------------------ | ---------------------------- |
| `--border-thin`  | `2px solid var(--ink)`   | Inputs, divider rules        |
| `--border-thick` | `3px solid var(--ink)`   | Cards, buttons, masthead     |
| `--shadow-sm`    | `3px 3px 0 var(--ink)`   | Hover state, small chips     |
| `--shadow-md`    | `6px 6px 0 var(--ink)`   | Default button + card shadow |
| `--shadow-lg`    | `10px 10px 0 var(--ink)` | Hero CTA, primary surfaces   |

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
