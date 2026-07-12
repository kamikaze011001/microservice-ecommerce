# Editorial seed catalog + chatbot-ready product data

**Date:** 2026-07-12
**Status:** Approved (design)

## Problem

The storefront presents itself as *Issue Nº01 — a small editorial storefront*: the nav wordmark
reads `ISSUE Nº01`, order statuses are stamped `IN PRESS`, search says `SEARCH THE ISSUE`, section
headers say `THE MASTHEAD`. The Storybook fixtures go further and invent a product voice —
`FIELD NOTES — RULED PRESS JACKET`, `LETTERPRESS TOTE BAG — Limited Run Edition No. 07 of 250`.

The seed data never caught up. It ships 30 generic SKUs (`Graphic Tee`, `Work Boots`,
`Socks 3-Pack`) with **no prose at all**, and — the visible symptom — every product image is a
random photo. `fetch-seed-images.sh` pulled `picsum.photos/seed/<slug>`, which is deterministic per
slug but semantically unrelated to the product: the hoodie's image is whatever picsum returns.

Two consequences:

1. The storefront looks broken. A "Cotton Crewneck Tee" shows a landscape.
2. A future AI chatbot has nothing to ground on. `Product` carries only `name`, `price`,
   `category`, `attributes`, `imageUrl`. A bot could answer *"how much is the tote?"* and would
   fail at *"something warm for autumn, under $80"* — because no product has a description.

## Goals

- Every product image depicts that product.
- Every product has editorial-voice prose and tags a chatbot can ground on.
- The storefront's data matches the identity its UI already claims.

## Non-goals (deliberate)

No chatbot code, no embeddings, no vector store, no retrieval endpoint. Those need a spec of their
own, designed against the bot's real needs rather than guessed at now. This change makes the
catalog *groundable*; it does not consume it.

## Image source — how the decision was reached

Keyless real-photo sources were tested empirically, not assumed:

| Source | Result |
|---|---|
| `picsum.photos` (current) | Real photos, **unrelated subject**. The bug. |
| `source.unsplash.com` | **HTTP 503** — endpoint deprecated. |
| `loremflickr.com` | Correct-ish subject, but **burned-in `cc-nc` watermark + photographer credit**, and `cc-nc` forbids commercial use. Disqualified. |
| **`dummyjson.com`** | **Clean CG product renders on pure white, no watermark.** Ships `description` + `tags`. Chosen. |

DummyJSON's catalog contains real trademarks (Nike, Puma, Off-White, Prada, Calvin Klein, Rolex,
Marni, Gigabyte). Those are **excluded** — 18 items dropped, leaving **31 clean items**, of which we
use 30.

Its images are licensed for demo/testing use. **This repo is a portfolio/demo project, so that is
acceptable.** If it ever needs to be commercially clean, the fallback is generated typographic
"editorial plates" (Bodoni is present on macOS) — same pipeline, different bytes.

## Hard constraint: product IDs and stock are frozen

`k8s/apps/base/k6-stress/*.yaml` hardcodes product ObjectIds:

- `…0001`, `…0002`, `…0003` — payment + storefront load jobs
- `…0004` — oversell-boundary job

Product *names* are referenced nowhere outside the seed. Therefore:

- **All 30 ObjectIds `67c0…0001`–`…001e` are preserved.**
- **Each ID keeps its existing `quantity` verbatim.** This preserves the zero-stock SKUs
  (`…0004`, `…000f`, `…0019`) and the single-unit SKU (`…0012`) that exercise out-of-stock and
  "only 1 left" UI states, and it keeps the k6 suite behaviourally unchanged.
- IDs stay grouped by category so `…0001`–`…0004` remain apparel, where the k6 pins expect them.

Everything else per SKU is rewritten: `name`, `slug`, `price`, `category`, `attributes`,
`description`, `tags`, and the image bytes.

## Catalog

**13 apparel / 4 footwear / 13 accessories.** Footwear is thin because every men's shoe in the
source was trademarked; four pairs in a self-described *small editorial storefront* is honest.

| ID suffix | Category | Source item | Qty (frozen) |
|---|---|---|---|
| 0001 | apparel | Blue & Black Check Shirt | 30 |
| 0002 | apparel | Man Plaid Shirt | 18 |
| 0003 | apparel | Man Short Sleeve Shirt | 12 |
| 0004 | apparel | Men Check Shirt | **0** |
| 0005 | apparel | Blue Frock | 8 |
| 0006 | apparel | Girl Summer Dress | 25 |
| 0007 | apparel | Gray Dress | 22 |
| 0008 | apparel | Short Frock | 2 |
| 0009 | apparel | Tartan Dress | 35 |
| 000a | apparel | Black Women's Gown | 40 |
| 000b | apparel | Corset Leather With Skirt | 28 |
| 000c | apparel | Corset With Black Skirt | 14 |
| 000d | apparel | Dress Pea | 22 |
| 000e | footwear | Black & Brown Slipper | 10 |
| 000f | footwear | Golden Shoes Woman | **0** |
| 0010 | footwear | Pampi Shoes | 30 |
| 0011 | footwear | Red Shoes | 6 |
| 0012 | accessories | Black Sun Glasses | **1** |
| 0013 | accessories | Classic Sun Glasses | 18 |
| 0014 | accessories | Green and Black Glasses | 24 |
| 0015 | accessories | Party Glasses | 50 |
| 0016 | accessories | Blue Women's Handbag | 18 |
| 0017 | accessories | White Faux Leather Backpack | 32 |
| 0018 | accessories | Women Handbag Black | 14 |
| 0019 | accessories | Green Crystal Earring | **0** |
| 001a | accessories | Green Oval Earring | 40 |
| 001b | accessories | Tropical Earring | 10 |
| 001c | accessories | Brown Leather Belt Watch | 45 |
| 001d | accessories | Women's Wrist Watch | 16 |
| 001e | accessories | Watch Gold for Women | 8 |

The 31st clean item (the generic `Sunglasses`, a near-duplicate of `Black Sun Glasses`) is dropped.

Prices are set per SKU in the manifest, informed by but not bound to the source prices.

## Editorial voice

Names take the register of the Storybook fixtures **while keeping the product noun intact** — the
noun is what search and, later, the chatbot rely on. Never rename a shirt into something you can't
search for.

```
Man Plaid Shirt        → Broadsheet Plaid Shirt
Gray Dress             → Column Dress, Ash
Green Crystal Earring  → Colophon Drop Earring, Emerald
```

Descriptions are 2–3 sentences in the same voice, and must name **material, colour, and use** —
those are the attributes a bot needs to answer an open question like *"something warm, under $80"*.
Tags are lowercase and retrieval-oriented (`["shirt", "cotton", "check", "layering"]`).

## Schema

`Product` (Mongo document) and `ProductResponse` each gain:

```java
private String description;
private List<String> tags;
```

`attributes` stays `Map<String, Object>` — schemaless, so `edition` / `run` need no migration.
Create/update request DTOs accept both fields as optional. `ProductDetailPage` renders the
description; it currently renders none. `inventory_product` (MySQL) is a stock mirror and does not
need the new columns.

## Pipeline

`scripts/seed/products-manifest.json` remains the single source of truth and gains `description`,
`tags`, and `imageSource` (the upstream URL, so the fetch is reproducible).

- `fetch-seed-images.sh` — rewritten to pull each `imageSource` and convert webp→jpg, writing to
  the existing `docker/seed-images/<category>/<slug>.jpg` paths. Stale images for retired slugs are
  deleted.
- `generate-product-json.sh` — emits `description` and `tags`.
- `generate-quantity-history.sh` — **unchanged** (IDs and quantities are frozen).

**Portability:** webp→jpg conversion needs a tool, and `sips` is macOS-only. The script tries
`magick` → `dwebp` → `sips` → Python in order and fails loudly if none is present. Because the
JPEGs are **committed**, no contributor ever runs this — it is an authoring tool, not a build step,
and there is no runtime network dependency or link rot.

## Verification

- `verify-products.sh` extended: 30 docs; every doc has non-empty `description` and `tags`; every
  `imageUrl` returns 200 from MinIO.
- Frontend unit test: `ProductDetailPage` renders the description.
- End-to-end `make seed-data`, then browse the storefront.

## Risks

- **Renumbering IDs would break the k6 stress suite.** Freezing them is the mitigation; any future
  catalog edit must respect it.
- **DummyJSON is an upstream dependency at authoring time only.** If it disappears, the committed
  JPEGs still work; only re-authoring breaks.
- **Trademark filter is a denylist.** New items pulled later must be re-checked by hand.
