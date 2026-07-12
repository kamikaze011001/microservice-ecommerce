# Editorial Seed Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 30 random-image, prose-less seed products with an editorial-voice catalog carrying real product images, descriptions, and tags — so the storefront matches the *Issue Nº01* identity its UI already claims, and a future chatbot has data to ground on.

**Architecture:** `scripts/seed/products-manifest.json` stays the single source of truth. A new gate script (`check-manifest.sh`) enforces the hard freeze constraint. The `Product` document and `ProductResponse` gain `description` + `tags`; `generate-product-json.sh` emits them; `fetch-seed-images.sh` is rewritten to pull real product renders and convert webp→jpg into the already-committed `docker/seed-images/` tree. The frontend detail page renders the description.

**Tech Stack:** Bash + `jq`, Java 17 / Spring Boot 3.3.6 (Mongo document + Lombok `@SuperBuilder` DTOs), Vue 3 + TypeScript + Vitest.

**Spec:** `docs/superpowers/specs/2026-07-12-editorial-seed-catalog-design.md`

**Branch:** `feat/editorial-seed-catalog` (already created; the spec is committed at `9b3d518`).

## Global Constraints

- **Product ObjectIds are frozen.** All 30 keep `67c0000000000000000000NN` where `NN` is the ID suffix in the catalog table below. `k8s/apps/base/k6-stress/*.yaml` hardcodes `…0001`, `…0002`, `…0003` (payment + storefront jobs) and `…0004` (oversell-boundary job). Renumbering breaks the stress suite.
- **Per-ID `quantity` is frozen.** Each ID keeps exactly the quantity in the catalog table. This preserves the zero-stock SKUs (`0004`, `000f`, `0019`) and the single-unit SKU (`0012`) that drive out-of-stock and "only 1 left" UI states, and keeps `docker/product-quantity-history.json` byte-identical.
- **IDs stay grouped by category:** `0001–000d` apparel, `000e–0011` footwear, `0012–001e` accessories. This keeps the k6-pinned IDs in apparel.
- **No trademarked products.** Nike, Puma, Off-White, Prada, Calvin Klein, Rolex, Marni, Gigabyte, Heshe are excluded from the source catalog and must not reappear.
- **Wire format is snake_case.** Java DTOs use `@JsonNaming(SnakeCaseStrategy)`; the frontend `ProductDto` therefore reads `image_url`, `description`, `tags`.
- **Names keep the product noun.** "Broadsheet Plaid Shirt", never "Broadsheet No. 4" — search and the future chatbot depend on the noun.
- **Scope stop:** no chatbot code, no embeddings, no retrieval endpoint.

## Catalog (authoritative)

`ID` column is the suffix of `67c0000000000000000000NN`. `Qty` is frozen. `Slug` is the kebab-case of `Name` and determines the committed image filename `docker/seed-images/<category>/<slug>.jpg`.

| ID | Category | Name | Slug | Price | Qty | imageSource |
|---|---|---|---|---|---|---|
| 0001 | apparel | Broadsheet Check Shirt | broadsheet-check-shirt | 58 | 30 | `https://cdn.dummyjson.com/product-images/mens-shirts/blue-&-black-check-shirt/1.webp` |
| 0002 | apparel | Broadsheet Plaid Shirt | broadsheet-plaid-shirt | 62 | 18 | `https://cdn.dummyjson.com/product-images/mens-shirts/man-plaid-shirt/1.webp` |
| 0003 | apparel | Dispatch Short-Sleeve Shirt | dispatch-short-sleeve-shirt | 45 | 12 | `https://cdn.dummyjson.com/product-images/mens-shirts/man-short-sleeve-shirt/1.webp` |
| 0004 | apparel | Gazette Check Shirt | gazette-check-shirt | 58 | 0 | `https://cdn.dummyjson.com/product-images/mens-shirts/men-check-shirt/1.webp` |
| 0005 | apparel | Indigo Frock | indigo-frock | 78 | 8 | `https://cdn.dummyjson.com/product-images/tops/blue-frock/1.webp` |
| 0006 | apparel | Summer Issue Dress | summer-issue-dress | 68 | 25 | `https://cdn.dummyjson.com/product-images/tops/girl-summer-dress/1.webp` |
| 0007 | apparel | Column Dress, Ash | column-dress-ash | 84 | 22 | `https://cdn.dummyjson.com/product-images/tops/gray-dress/1.webp` |
| 0008 | apparel | Quarto Short Frock | quarto-short-frock | 72 | 2 | `https://cdn.dummyjson.com/product-images/tops/short-frock/1.webp` |
| 0009 | apparel | Tartan Folio Dress | tartan-folio-dress | 92 | 35 | `https://cdn.dummyjson.com/product-images/tops/tartan-dress/1.webp` |
| 000a | apparel | Nocturne Gown | nocturne-gown | 210 | 40 | `https://cdn.dummyjson.com/product-images/womens-dresses/black-women's-gown/1.webp` |
| 000b | apparel | Letterpress Corset & Leather Skirt | letterpress-corset-leather-skirt | 165 | 28 | `https://cdn.dummyjson.com/product-images/womens-dresses/corset-leather-with-skirt/1.webp` |
| 000c | apparel | Inkblack Corset & Skirt | inkblack-corset-skirt | 145 | 14 | `https://cdn.dummyjson.com/product-images/womens-dresses/corset-with-black-skirt/1.webp` |
| 000d | apparel | Pea Coat Dress | pea-coat-dress | 128 | 22 | `https://cdn.dummyjson.com/product-images/womens-dresses/dress-pea/1.webp` |
| 000e | footwear | Foldover Slipper, Black & Brown | foldover-slipper-black-brown | 48 | 10 | `https://cdn.dummyjson.com/product-images/womens-shoes/black-&-brown-slipper/1.webp` |
| 000f | footwear | Gilt Edition Shoe | gilt-edition-shoe | 115 | 0 | `https://cdn.dummyjson.com/product-images/womens-shoes/golden-shoes-woman/1.webp` |
| 0010 | footwear | Pampi Walking Shoe | pampi-walking-shoe | 95 | 30 | `https://cdn.dummyjson.com/product-images/womens-shoes/pampi-shoes/1.webp` |
| 0011 | footwear | Red Press Shoe | red-press-shoe | 105 | 6 | `https://cdn.dummyjson.com/product-images/womens-shoes/red-shoes/1.webp` |
| 0012 | accessories | Blackout Sunglasses | blackout-sunglasses | 85 | 1 | `https://cdn.dummyjson.com/product-images/sunglasses/black-sun-glasses/1.webp` |
| 0013 | accessories | Classic Frame Sunglasses | classic-frame-sunglasses | 75 | 18 | `https://cdn.dummyjson.com/product-images/sunglasses/classic-sun-glasses/1.webp` |
| 0014 | accessories | Bicolour Frame Sunglasses | bicolour-frame-sunglasses | 88 | 24 | `https://cdn.dummyjson.com/product-images/sunglasses/green-and-black-glasses/1.webp` |
| 0015 | accessories | Soirée Sunglasses | soiree-sunglasses | 42 | 50 | `https://cdn.dummyjson.com/product-images/sunglasses/party-glasses/1.webp` |
| 0016 | accessories | Cerulean Handbag | cerulean-handbag | 130 | 18 | `https://cdn.dummyjson.com/product-images/womens-bags/blue-women's-handbag/1.webp` |
| 0017 | accessories | Offset Backpack, Chalk | offset-backpack-chalk | 110 | 32 | `https://cdn.dummyjson.com/product-images/womens-bags/white-faux-leather-backpack/1.webp` |
| 0018 | accessories | Colophon Handbag, Black | colophon-handbag-black | 150 | 14 | `https://cdn.dummyjson.com/product-images/womens-bags/women-handbag-black/1.webp` |
| 0019 | accessories | Colophon Drop Earring, Emerald | colophon-drop-earring-emerald | 65 | 0 | `https://cdn.dummyjson.com/product-images/womens-jewellery/green-crystal-earring/1.webp` |
| 001a | accessories | Oval Signature Earring, Emerald | oval-signature-earring-emerald | 58 | 40 | `https://cdn.dummyjson.com/product-images/womens-jewellery/green-oval-earring/1.webp` |
| 001b | accessories | Tropic Edition Earring | tropic-edition-earring | 52 | 10 | `https://cdn.dummyjson.com/product-images/womens-jewellery/tropical-earring/1.webp` |
| 001c | accessories | Deadline Watch, Brown Leather | deadline-watch-brown-leather | 180 | 45 | `https://cdn.dummyjson.com/product-images/mens-watches/brown-leather-belt-watch/1.webp` |
| 001d | accessories | Masthead Wrist Watch | masthead-wrist-watch | 195 | 16 | `https://cdn.dummyjson.com/product-images/womens-watches/women's-wrist-watch/1.webp` |
| 001e | accessories | Gilt Masthead Watch | gilt-masthead-watch | 420 | 8 | `https://cdn.dummyjson.com/product-images/womens-watches/watch-gold-for-women/1.webp` |

**Shell hazard:** four `imageSource` URLs contain `&` or `'` (`0001`, `000a`, `000e`, `0016`, `001d`). Always pass them to `curl` **double-quoted** (`curl "$url"`), never bare — an unquoted `&` backgrounds the command.

## Editorial voice (for `name` and `description`)

Register comes from the existing Storybook fixtures (`FIELD NOTES — RULED PRESS JACKET`, `LETTERPRESS TOTE BAG — Limited Run Edition No. 07 of 250`). Names are fixed in the table above — do not invent new ones.

Each `description` is **2–3 sentences** and **must name the material, the colour, and the use**. Those three facts are what lets a future bot answer an open question like *"something warm, under $80"*. Write plainly; no invented brand history, no fake awards.

Three worked examples (use these verbatim for `0002`, `0007`, `0019`):

- **0002 Broadsheet Plaid Shirt** — `"A brushed cotton plaid cut for layering, in muted red and navy. The collar holds its shape without starch, and the body is roomy enough to wear open over a tee. Warm enough for a cold newsroom, light enough to keep on all day."`
- **0007 Column Dress, Ash** — `"A sleeveless button-through dress in ash-grey crepe, belted at the waist with a self tie. The A-line skirt falls below the knee and moves well. Reads as tailored, wears as easy."`
- **0019 Colophon Drop Earring, Emerald** — `"A faceted emerald crystal drop suspended from gold-tone brass. Light catches the facets at every angle, so it carries a plain outfit on its own. Weighs almost nothing on the ear."`

`tags` are lowercase, retrieval-oriented, 3–6 per product — the material, the form, the colour, the use. Example for `0002`: `["shirt", "cotton", "plaid", "layering", "warm"]`.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `product-service/src/main/java/.../entity/Product.java` | Mongo document — add `description`, `tags` | 1 |
| `product-service/src/main/java/.../dto/response/ProductResponse.java` | API response — add fields + map them in `from()` | 1 |
| `product-service/src/main/java/.../dto/request/ProductRequest.java` | Create/update input — accept both, optional | 1 |
| `product-service/src/test/java/.../dto/ProductResponseMappingTest.java` | **New.** Guards the `from()` mapping | 1 |
| `scripts/seed/check-manifest.sh` | **New.** Gate: freeze constraint + data completeness | 2 |
| `scripts/seed/products-manifest.json` | Source of truth — full rewrite | 2 |
| `scripts/seed/fetch-seed-images.sh` | Rewrite: pull `imageSource`, webp→jpg, prune stale | 3 |
| `docker/seed-images/**` | Committed JPEGs — replaced | 3 |
| `scripts/seed/generate-product-json.sh` | Emit `description` + `tags` | 4 |
| `docker/product.json` | Regenerated output | 4 |
| `frontend/src/api/queries/products.ts` | `ProductDto` — add `description`, `tags` | 5 |
| `frontend/src/pages/ProductDetailPage.vue` | Render the description | 5 |
| `frontend/tests/unit/pages/ProductDetailPage.spec.ts` | Test the render | 5 |
| `scripts/seed/verify-products.sh` | Assert prose + tags are actually served | 6 |

---

### Task 1: Backend schema — `description` + `tags`

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/request/ProductRequest.java`
- Test: `product-service/src/test/java/org/aibles/ecommerce/product_service/dto/ProductResponseMappingTest.java` (new)

**Interfaces:**
- Consumes: nothing.
- Produces: `Product.getDescription(): String`, `Product.getTags(): List<String>`, and the same two on `ProductResponse` (serialised as `description` and `tags` — both are already snake_case-identical, so `@JsonNaming` leaves them unchanged). Task 4 and Task 5 depend on these names.

- [ ] **Step 1: Write the failing test**

Create `product-service/src/test/java/org/aibles/ecommerce/product_service/dto/ProductResponseMappingTest.java`:

```java
package org.aibles.ecommerce.product_service.dto;

import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ProductResponseMappingTest {

    @Test
    void from_carriesDescriptionAndTags() {
        Product product = Product.builder()
                .id("67c000000000000000000002")
                .name("Broadsheet Plaid Shirt")
                .price(62.0)
                .category("apparel")
                .attributes(Map.of("color", "Red"))
                .imageUrl("http://localhost:9000/x.jpg")
                .description("A brushed cotton plaid cut for layering.")
                .tags(List.of("shirt", "cotton", "plaid"))
                .build();

        ProductResponse response = ProductResponse.from(product, 18L);

        assertThat(response.getDescription()).isEqualTo("A brushed cotton plaid cut for layering.");
        assertThat(response.getTags()).containsExactly("shirt", "cotton", "plaid");
        assertThat(response.getQuantity()).isEqualTo(18L);
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd product-service && mvn -q test -Dtest=ProductResponseMappingTest`
Expected: **compilation failure** — `cannot find symbol: method description(String)` on the builder.

- [ ] **Step 3: Add the two fields to `Product`**

In `entity/Product.java`, add `import java.util.List;` and, after the `imageUrl` field:

```java
    private String description;

    private List<String> tags;
```

- [ ] **Step 4: Add the two fields to `ProductResponse` and map them**

In `dto/response/ProductResponse.java`, add `import java.util.List;`, add the fields after `imageUrl`:

```java
    private String description;

    private List<String> tags;
```

and extend the builder chain inside `from()`:

```java
    public static ProductResponse from(final Product product, final long quantity) {
        return ProductResponse.builder()
                .id(product.getId())
                .name(product.getName())
                .price(product.getPrice())
                .quantity(quantity)
                .attributes(product.getAttributes())
                .category(product.getCategory())
                .imageUrl(product.getImageUrl())
                .description(product.getDescription())
                .tags(product.getTags())
                .build();
    }
```

- [ ] **Step 5: Accept both fields on `ProductRequest`**

In `dto/request/ProductRequest.java`, add `import java.util.List;`, add the fields after `category` (both **optional** — no validation annotations; existing API clients that omit them must keep working):

```java
    private String description;

    private List<String> tags;
```

and extend `to()`:

```java
    public static Product to(final ProductRequest productRequest) {
        return Product.builder()
                .name(productRequest.name)
                .price(productRequest.price)
                .attributes(productRequest.attributes)
                .category(productRequest.category)
                .description(productRequest.description)
                .tags(productRequest.tags)
                .build();
    }
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd product-service && mvn -q test -Dtest=ProductResponseMappingTest`
Expected: PASS.

- [ ] **Step 7: Run the full product-service suite (no regressions)**

Run: `cd product-service && mvn -q test`
Expected: PASS — including `ProductImageUrlTest`, `ProductServiceImplListByIdsTest`, `ProductErrorCatalogTest`.

- [ ] **Step 8: Commit**

```bash
git add product-service/src/main/java product-service/src/test/java
git commit -m "feat(product): add description + tags to Product schema"
```

---

### Task 2: Manifest rewrite, behind a freeze gate

Write the gate **first** so the freeze constraint is machine-checked, not trusted.

**Files:**
- Create: `scripts/seed/check-manifest.sh`
- Modify: `scripts/seed/products-manifest.json` (full rewrite of the `products` array)

**Interfaces:**
- Consumes: nothing.
- Produces: each manifest entry gains `description` (String), `tags` (array of String), `imageSource` (String URL). Task 3 reads `imageSource` + `slug` + `category`; Task 4 reads `description` + `tags`.

- [ ] **Step 1: Write the gate script**

Create `scripts/seed/check-manifest.sh`:

```bash
#!/bin/bash
# Gate for products-manifest.json.
#
# The k6 stress jobs (k8s/apps/base/k6-stress/*.yaml) hardcode product
# ObjectIds 67c0…0001-0004. Renumbering the catalog silently breaks them,
# and the failure surfaces far from the cause. So the IDs and their stock
# levels are FROZEN and checked here.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

# id-suffix:quantity — frozen. Do not edit without re-checking the k6 jobs.
FROZEN="01:30 02:18 03:12 04:0 05:8 06:25 07:22 08:2 09:35 0a:40 \
0b:28 0c:14 0d:22 0e:10 0f:0 10:30 11:6 12:1 13:18 14:24 \
15:50 16:18 17:32 18:14 19:0 1a:40 1b:10 1c:45 1d:16 1e:8"

fail=0
err() { log_warn "$1"; fail=1; }

count=$(jq '.products | length' "$MANIFEST")
[ "$count" -eq 30 ] || err "expected 30 products, got $count"

for pair in $FROZEN; do
    suffix="${pair%%:*}"
    want_qty="${pair##*:}"
    id="67c0000000000000000000${suffix}"
    entry=$(jq -c --arg id "$id" '.products[] | select(.productId == $id)' "$MANIFEST")
    if [ -z "$entry" ]; then
        err "missing frozen productId $id"
        continue
    fi
    got_qty=$(echo "$entry" | jq -r '.quantity')
    [ "$got_qty" = "$want_qty" ] || err "$id quantity drifted: want $want_qty, got $got_qty"
done

# Every product must carry chatbot-grounding data and a real image source.
while IFS=$'\t' read -r id desc_len tag_count src; do
    [ "$desc_len" -ge 80 ] || err "$id description too short ($desc_len chars; need >= 80)"
    [ "$tag_count" -ge 3 ] || err "$id has $tag_count tags (need >= 3)"
    case "$src" in
        https://cdn.dummyjson.com/product-images/*) ;;
        *) err "$id imageSource is not a dummyjson product image: '$src'" ;;
    esac
done < <(jq -r '.products[] | "\(.productId)\t\(.description | length)\t\(.tags | length)\t\(.imageSource)"' "$MANIFEST")

# Trademarked brands must never re-enter the catalog.
if jq -r '.products[] | .name' "$MANIFEST" \
   | grep -inE 'nike|puma|off.?white|prada|calvin klein|rolex|marni|gigabyte|heshe'; then
    err "trademarked brand name found in catalog"
fi

# Slugs must be unique — they are the image filenames.
dupes=$(jq -r '.products[].slug' "$MANIFEST" | sort | uniq -d)
[ -z "$dupes" ] || err "duplicate slugs: $dupes"

if [ "$fail" -ne 0 ]; then
    log_warn "manifest check FAILED"
    exit 1
fi
log_ok "manifest check passed (30 products, IDs + stock frozen)"
```

- [ ] **Step 2: Make it executable and run it — verify it fails**

Run:
```bash
chmod +x scripts/seed/check-manifest.sh
bash scripts/seed/check-manifest.sh
```
Expected: **FAIL.** The current manifest has no `description`, `tags`, or `imageSource`, so `jq` yields `null` and every product trips the description/tags/imageSource checks.

- [ ] **Step 3: Rewrite the manifest**

Rewrite the `products` array of `scripts/seed/products-manifest.json` with all 30 entries from the **Catalog** table above. Keep the existing top-level `bucket` and `publicBaseUrl` keys unchanged. Each entry has this exact shape:

```json
{
  "slug": "broadsheet-plaid-shirt",
  "productId": "67c000000000000000000002",
  "category": "apparel",
  "name": "Broadsheet Plaid Shirt",
  "price": 62,
  "quantity": 18,
  "description": "A brushed cotton plaid cut for layering, in muted red and navy. The collar holds its shape without starch, and the body is roomy enough to wear open over a tee. Warm enough for a cold newsroom, light enough to keep on all day.",
  "tags": ["shirt", "cotton", "plaid", "layering", "warm"],
  "imageSource": "https://cdn.dummyjson.com/product-images/mens-shirts/man-plaid-shirt/1.webp",
  "attributes": { "color": "Red", "material": "cotton", "size": ["S", "M", "L", "XL"] }
}
```

Rules for the fields not pinned by the table:
- **`description`** — follow the *Editorial voice* section: 2–3 sentences, ≥ 80 chars, naming material + colour + use. Use the three worked examples verbatim for `0002`, `0007`, `0019`.
- **`tags`** — 3–6 lowercase tags: material, form, colour, use.
- **`attributes`** — keep the existing shape conventions: apparel gets `color` + `material` + `size` (`["S","M","L","XL"]` for shirts, `["XS","S","M","L"]` for dresses); footwear gets `color` + `size` (`["6","7","8","9"]`) + `gender`; sunglasses / bags / earrings / watches get `color` + `material` and **no `size`**.

- [ ] **Step 4: Run the gate — verify it passes**

Run: `bash scripts/seed/check-manifest.sh`
Expected: `manifest check passed (30 products, IDs + stock frozen)`

- [ ] **Step 5: Commit**

```bash
git add scripts/seed/check-manifest.sh scripts/seed/products-manifest.json
git commit -m "feat(seed): editorial catalog manifest + frozen-ID gate"
```

---

### Task 3: Real product images

**Files:**
- Modify: `scripts/seed/fetch-seed-images.sh` (rewrite)
- Modify: `docker/seed-images/**` (30 JPEGs replaced, stale ones deleted)

**Interfaces:**
- Consumes: `slug`, `category`, `imageSource` from the manifest (Task 2).
- Produces: `docker/seed-images/<category>/<slug>.jpg` for all 30 products. `minio-product-images.sh` and `generate-product-json.sh` already assume exactly these paths — do not change the layout.

- [ ] **Step 1: Rewrite the fetch script**

Replace `scripts/seed/fetch-seed-images.sh` entirely:

```bash
#!/bin/bash
# Download each product's real image from its manifest `imageSource` and
# convert webp -> jpg into docker/seed-images/<category>/<slug>.jpg.
#
# The JPEGs are COMMITTED, so this is an authoring tool, not a build step —
# no contributor and no CI job needs to run it. Re-run only when the
# manifest changes. Idempotent: skips files that exist unless FORCE=1.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/seed/products-manifest.json"
OUT_DIR="$REPO_ROOT/docker/seed-images"

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"

# webp -> jpg. No single converter is present on every machine, so try the
# common ones in order and fail loudly rather than silently emitting a webp
# with a .jpg extension (MinIO would then serve the wrong Content-Type).
convert_webp() {
    local src="$1" dst="$2"
    if command -v magick >/dev/null 2>&1; then
        magick "$src" "$dst"
    elif command -v dwebp >/dev/null 2>&1; then
        dwebp -quiet "$src" -o "${dst%.jpg}.png" && magick "${dst%.jpg}.png" "$dst"
    elif command -v sips >/dev/null 2>&1; then
        sips -s format jpeg "$src" --out "$dst" >/dev/null
    elif python3 -c "import PIL" >/dev/null 2>&1; then
        python3 -c "from PIL import Image; Image.open('$src').convert('RGB').save('$dst', 'JPEG', quality=90)"
    else
        log_err "no webp->jpg converter found. Install one of: imagemagick (brew install imagemagick), webp (brew install webp), or Pillow (pip install Pillow)."
        exit 1
    fi
}

mkdir -p "$OUT_DIR/apparel" "$OUT_DIR/footwear" "$OUT_DIR/accessories"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetched=0
skipped=0

while IFS=$'\t' read -r slug category src; do
    out="$OUT_DIR/$category/$slug.jpg"
    if [ -f "$out" ] && [ -z "$FORCE" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    log_info "Fetching $slug"
    # NOTE: several imageSource URLs contain & and ' — always keep "$src" quoted.
    curl -sSL --fail --max-time 30 --output "$tmp/$slug.webp" "$src"
    convert_webp "$tmp/$slug.webp" "$out"
    fetched=$((fetched + 1))
done < <(jq -r '.products[] | "\(.slug)\t\(.category)\t\(.imageSource)"' "$MANIFEST")

# Prune images whose slug is no longer in the manifest.
pruned=0
expected=$(jq -r '.products[] | "\(.category)/\(.slug).jpg"' "$MANIFEST" | sort)
while IFS= read -r existing; do
    rel="${existing#"$OUT_DIR/"}"
    if ! echo "$expected" | grep -qx "$rel"; then
        log_info "Pruning stale image $rel"
        rm -f "$existing"
        pruned=$((pruned + 1))
    fi
done < <(find "$OUT_DIR" -name '*.jpg')

log_ok "seed-images: fetched=$fetched skipped=$skipped pruned=$pruned"
```

- [ ] **Step 2: Run it with FORCE to replace every image**

Run: `FORCE=1 bash scripts/seed/fetch-seed-images.sh`
Expected: `seed-images: fetched=30 skipped=0 pruned=30` — 30 new JPEGs written, the 30 stale picsum ones (old slugs) pruned.

- [ ] **Step 3: Verify the bytes are real JPEGs, not renamed webp**

Run:
```bash
find docker/seed-images -name '*.jpg' | wc -l
file docker/seed-images/apparel/broadsheet-plaid-shirt.jpg
```
Expected: `30`, and `JPEG image data` (**not** `RIFF (little-endian) data, Web/P image`). If you see WebP, the converter fell through — fix it before committing, or MinIO will serve `image/jpeg` for webp bytes and `verify-products.sh` will pass while browsers show a broken image.

- [ ] **Step 4: Eyeball two images**

Open `docker/seed-images/apparel/broadsheet-plaid-shirt.jpg` and `docker/seed-images/accessories/colophon-drop-earring-emerald.jpg`. Expected: a plaid shirt and an emerald drop earring, each a product render on a white background. If either shows an unrelated subject, the manifest's `imageSource` is wrong for that SKU — fix the manifest, don't paper over it here.

- [ ] **Step 5: Commit**

```bash
git add scripts/seed/fetch-seed-images.sh docker/seed-images
git commit -m "feat(seed): real product images, replacing random picsum placeholders"
```

---

### Task 4: Generators emit the new fields

**Files:**
- Modify: `scripts/seed/generate-product-json.sh`
- Modify: `docker/product.json` (regenerated)
- Verify unchanged: `docker/product-quantity-history.json`

**Interfaces:**
- Consumes: `description` + `tags` from the manifest (Task 2); the `Product` field names from Task 1.
- Produces: `docker/product.json` with `description` and `tags` on every document. `mongo-products.sh` and `mysql-inventory-products.sh` consume this file unchanged (the MySQL mirror only selects `id, name, price, image_url`, so it needs no migration).

- [ ] **Step 1: Add the two fields to the generator**

In `scripts/seed/generate-product-json.sh`, extend the `jq` map to emit them. The full expression becomes:

```bash
jq --arg base "$base_url" '
  .products | map({
    "_id":         { "$oid": .productId },
    "_class":      "org.aibles.ecommerce.product_service.entity.Product",
    "name":        .name,
    "price":       .price,
    "category":    .category,
    "attributes":  .attributes,
    "description": .description,
    "tags":        .tags,
    "imageUrl":    ($base + "/products/" + .productId + "/" + .slug + ".jpg")
  })
' "$MANIFEST" > "$OUT"
```

(Field names are the **camelCase Java field names**, because `mongoimport` writes straight into the Mongo document — this file is not the JSON wire format. `description` and `tags` are single words, so they are identical either way.)

- [ ] **Step 2: Regenerate both seed files**

Run:
```bash
bash scripts/seed/generate-product-json.sh
bash scripts/seed/generate-quantity-history.sh
```
Expected: `Wrote 30 products to …/docker/product.json` and `Wrote 30 quantity-history docs to …`.

- [ ] **Step 3: Verify the freeze held**

Run: `git diff --stat docker/product-quantity-history.json`
Expected: **no output.** Quantities and IDs are frozen, so this file must be byte-identical. If it changed, a quantity drifted in Task 2 — go fix the manifest.

- [ ] **Step 4: Verify the new fields landed**

Run: `jq -r '.[0] | {name, description, tags, imageUrl}' docker/product.json`
Expected: the first product with a non-null `description`, a non-empty `tags` array, and an `imageUrl` ending in `/broadsheet-check-shirt.jpg`.

- [ ] **Step 5: Commit**

```bash
git add scripts/seed/generate-product-json.sh docker/product.json
git commit -m "feat(seed): emit description + tags into product.json"
```

---

### Task 5: Frontend renders the description

**Files:**
- Modify: `frontend/src/api/queries/products.ts`
- Modify: `frontend/src/pages/ProductDetailPage.vue`
- Test: `frontend/tests/unit/pages/ProductDetailPage.spec.ts`

**Interfaces:**
- Consumes: `description` + `tags` on the API response (Task 1). Wire format is snake_case, but both names are single words, so they arrive as `description` and `tags`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

In `frontend/tests/unit/pages/ProductDetailPage.spec.ts`, add `description` and `tags` to the existing `makeProduct` fixture (find the object with `name: 'Glass Vase'` and add the two keys):

```ts
    description: 'A hand-blown glass vase in clear soda-lime, for a single stem.',
    tags: ['vase', 'glass', 'home'],
```

Then add this test beside the existing `renders name, formatted price, and attribute rows`:

```ts
  it('renders the product description', () => {
    mockDetailQuery.mockReturnValue({
      data: { value: makeProduct() },
      isPending: { value: false },
      error: { value: null },
    });

    renderPage();

    expect(
      screen.getByText(/hand-blown glass vase in clear soda-lime/i),
    ).toBeInTheDocument();
  });
```

**Note:** match the mock-return shape used by the neighbouring tests in this file exactly — if they build the query mock via a helper, reuse it rather than the literal above.

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd frontend && pnpm test -- ProductDetailPage.spec.ts`
Expected: FAIL — `Unable to find an element with the text: /hand-blown glass vase in clear soda-lime/i`.

- [ ] **Step 3: Add the fields to `ProductDto`**

In `frontend/src/api/queries/products.ts`, extend the interface:

```ts
export interface ProductDto {
  id: string;
  name: string;
  price: number;
  attributes: Record<string, unknown> | null;
  quantity: number;
  category: string | null;
  image_url: string | null;
  description: string | null;
  tags: string[] | null;
}
```

- [ ] **Step 4: Render the description**

In `frontend/src/pages/ProductDetailPage.vue`, add the paragraph between the price and the attribute list (currently lines 95–96), so it reads:

```html
        <p class="pdp__price">{{ formattedPrice }}</p>
        <p v-if="product.description" class="pdp__description">{{ product.description }}</p>
        <dl v-if="attributeRows.length" class="pdp__attrs">
```

Add the style beside the existing `.pdp__price` rule, using only existing tokens (never a raw hex or font — see `frontend/CLAUDE.md`):

```css
.pdp__description {
  margin-top: var(--space-3);
  max-width: 60ch;
  color: var(--muted-ink);
  line-height: 1.6;
}
```

Both `--space-3` and `--muted-ink` are verified present in `frontend/src/styles/tokens.css`, and `--muted-ink` is the same token `.pdp__attrs dt` already uses. Note the name is `--muted-ink`, **not** `--ink-muted`. Never invent a token or hard-code a hex (see `frontend/CLAUDE.md`).

- [ ] **Step 5: Run the test and verify it passes**

Run: `cd frontend && pnpm test -- ProductDetailPage.spec.ts`
Expected: PASS, including the pre-existing tests in the file.

- [ ] **Step 6: Typecheck and run the full suite**

Run: `cd frontend && pnpm typecheck && pnpm test`
Expected: both green. `pnpm typecheck` is the canary — a `ProductDto` that disagrees with the backend surfaces here.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/api/queries/products.ts frontend/src/pages/ProductDetailPage.vue frontend/tests/unit/pages/ProductDetailPage.spec.ts
git commit -m "feat(frontend): render product description on the detail page"
```

---

### Task 6: Verify the seed end-to-end

**Files:**
- Modify: `scripts/seed/verify-products.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Extend the verifier to assert prose and tags are actually served**

In `scripts/seed/verify-products.sh`, insert this block immediately **before** the final `log_ok "Seed verification passed"` line. It asserts the chatbot-grounding data survives the whole path (manifest → `product.json` → Mongo → service → gateway), which is the thing the whole change exists for:

```bash
missing_desc=$(echo "$body" | jq -r '
  (.data.data // .data.items // .data.content)
  | map(select((.description // "") == "" or ((.tags // []) | length) == 0))
  | length')
if [ "$missing_desc" != "0" ]; then
    log_warn "$missing_desc product(s) on page 1 are missing description or tags"
    echo "$body" | jq -r '(.data.data // .data.items // .data.content)
      | map(select((.description // "") == "" or ((.tags // []) | length) == 0))
      | .[].name'
    exit 1
fi
log_ok "All products on page 1 carry description + tags"
```

- [ ] **Step 2: Bring the stack up and reseed**

Run:
```bash
make up
make seed-data
```
Expected: seed scripts report 30 products, 30 quantity-history docs, and images uploaded to MinIO.

- [ ] **Step 3: Run the verifier**

Run: `GATEWAY_URL=http://localhost:6868 bash scripts/seed/verify-products.sh`
Expected: `Catalog total: 30`, `First image reachable: …`, `All products on page 1 carry description + tags`, `Seed verification passed`.

**Note:** the script defaults `GATEWAY_URL` to `:8080`, but this repo's gateway is on **`:6868`** — pass it explicitly as shown.

- [ ] **Step 4: Look at the storefront**

Open `http://localhost:5173`. Expected: a grid of real product photography on white — shirts, dresses, shoes, sunglasses, bags, earrings, watches — with no random landscapes. Open any product: its description renders under the price. Open `Gazette Check Shirt` (`…0004`): it is SOLD OUT.

- [ ] **Step 5: Commit**

```bash
git add scripts/seed/verify-products.sh
git commit -m "test(seed): assert served products carry description + tags"
```

---

## Self-Review

**Spec coverage:** Image source decision → Task 3. Frozen IDs/stock → Task 2 gate (`check-manifest.sh`) + Task 4 Step 3. Catalog 13/4/13 → Task 2 table. Editorial voice → Task 2 voice section. Schema (`description`, `tags`) → Task 1. `ProductDetailPage` renders description → Task 5. Pipeline (manifest, fetch, generate) → Tasks 2–4. `inventory_product` needs no migration → Task 4 note (confirmed: the mirror selects only `id, name, price, image_url`). Verification → Task 6. Non-goals (no chatbot code) → Global Constraints.

**Type consistency:** `description: String` / `tags: List<String>` in Task 1 match `description: string | null` / `tags: string[] | null` in Task 5 (nullable on the wire because pre-existing documents may lack them) and the `description` / `tags` manifest keys in Tasks 2–4. `ProductResponse.from(product, quantity)` keeps its existing two-arg signature.

**Known follow-on (out of scope):** the storefront search is name-only. Once the bot exists, a text search over `description` + `tags` is the natural next spec.
