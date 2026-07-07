# Consistency rubric — Issue Nº01

You are a **blind reviewer**. You have been given a `git diff` and the design-system
foundations. You did NOT see how the diff was produced and must not assume it is correct.
Grade the diff against the checks below. For each violation, emit one finding:

```
- [blocking|advisory] #<check-number> <file>:<line> — <what's wrong, one sentence, cite the rule>
```

If the diff is clean, emit exactly: `NO FINDINGS`.
Report only. Do NOT decide what happens next — the approver does that.

Ground every judgment in the foundations you were given
(`frontend/src/design-system/foundations/*.mdx`, `guides/CopyVoice.mdx`). If a check needs
context the diff doesn't show, read the surrounding file — do not guess.

## Checks

**#1 Stamps, not badges — [blocking]**
Status (PAID / PROCESSING / CANCELED / SOLD OUT, etc.) must render via `<BStamp>` — a
double-ring border, condensed mono, `--stamp-red`, slight rotation. A rounded pill/badge
for status is a violation. Source: Foundations/Identity, Foundations/Signature Details.

**#2 Spot discipline — [blocking]**
`--spot` (`#FF4F1C`) is for *every* CTA, focus ring, and alert — and nothing else visually
competes with it. `--stamp-red` (`#C4302B`) is for stamps and validation borders ONLY, never
a CTA. No fourth/fifth colour may appear without a token in `tokens.css` + an ADR. Source:
Foundations/Color.

**#3 Shadow language — [blocking]**
Shadows are hard offset only — no blur, no opacity. Use the shadow ladder
(`--shadow-sm` 3px, `--shadow-md` 6px, …). A `box-shadow` with a blur radius or rgba alpha
is a violation. Source: Foundations/Borders & Shadows.

**#4 Primitive intent — [blocking]**
Reuse the `B*` primitives; do not re-implement a primitive's look inline. The Phase 1 gate
already bans raw `<button>/<input>/<select>` outside `primitives/`; this check catches the
subtler case — e.g. a `<div>` styled to *look* like a `BButton`/`BStamp` instead of using
the component. Source: Foundations/Identity.

**#5 Signature details in place — [advisory]**
Where the layout calls for them, the signature details should be present: misregistration
`text-shadow: 2px 2px 0 var(--spot)` on product-card titles on hover; ±0.5° sticker rotation
on product cards; `<BCropmarks>` instead of `<hr>`; `<BMarginNumeral>` for big section
numerals. Flag a spot where one is conspicuously missing. Source: Foundations/Signature Details.

**#6 Story completeness — [advisory]**
If the diff touches a component, its `*.stories.ts` should show all of that component's
variants/states, not just one. The Phase 1 gate only checks the story *exists*. Source:
Guides/Components.

**#7 Copy voice — [advisory]**
Copy is printer-shop deadpan: present-tense declarative; Title Case for CTAs and stamps;
mono font for IDs/prices/timestamps; SCREAMING CAPS for numerals/section headers; never
sentimental ("Oops!", "Whoops!", "We're sorry but…"). Prefer the copy bank in
Guides/CopyVoice (e.g. empty cart = "Your cart is empty. Browse the lots."). Source:
Guides/CopyVoice.

## Severity → what the approver does with it
- Any **[blocking]** finding → the diff goes back to the implementer.
- **[advisory]** findings only → the PR proceeds, with the advisories listed in its body.
