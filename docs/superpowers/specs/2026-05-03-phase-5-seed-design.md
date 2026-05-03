# Phase 5 Seed — Design Spec

Date: 2026-05-03
Status: Approved (brainstorming → ready for implementation plan)
Predecessor: Phase 4 Browse (PR #4, merged)

## Goal

Replace the 5-product `docker/product.json` stub with a curated catalog of 30
products plus matching images uploaded to MinIO, so the Phase 4 storefront
(`HomePage`, `ProductDetailPage`) has real, demoable data when running
`make up` locally.

## Non-goals

- No category filter UI (Phase 4 doesn't filter by category).
- No image variants (thumbnail / full). Single 800×800 JPEG per product.
- No localization — English names and categories only.
- No exercising of the presign/upload endpoint as part of seed (those have their own integration tests in `core-s3`).

## Catalog shape

- **30 products total**, distributed `apparel: 10`, `footwear: 10`, `accessories: 10`.
- Each product is a MongoDB document matching the existing
  `org.aibles.ecommerce.product_service.entity.Product` shape, extended with
  the fields the Phase 4 frontend reads:
  - `_id` — stable MongoDB ObjectId, hand-picked (not auto-generated) so the
    image object key `products/{id}/<uuid>.jpg` is reproducible across reseeds.
  - `name` — human-readable, e.g., "Cotton Crewneck Tee".
  - `price` — integer USD, range 15–600.
  - `category` — one of `apparel`, `footwear`, `accessories`.
  - `quantity` — see distribution below.
  - `attributes` — category-shaped map:
    - apparel: `{ color, material, size: [..] }`
    - footwear: `{ color, size: [..], gender }`
    - accessories: `{ color, material }`
  - `image_url` — full MinIO public URL (see "Public URL" below).
- **Quantity distribution** (verified across the 30 entries):
  - 25 in-stock with `quantity` between 5 and 50.
  - 3 sold-out (`quantity: 0`) — demos the `SOLD OUT` CTA on PDP.
  - 2 low-stock (`quantity` between 1 and 3) — visual variety; no special UI.

## File layout

```
docker/
  seed-images/
    README.md                    # CC0 attribution + source list
    apparel/<slug>.jpg           # 10 files
    footwear/<slug>.jpg          # 10 files
    accessories/<slug>.jpg       # 10 files
  product.json                   # REPLACED — 30 products with image_url baked in
scripts/seed/
  all.sh                         # MODIFIED — add minio-product-images step before mongo-products
  minio-product-images.sh        # CREATED — mc-based upload script
  mongo-products.sh              # UNCHANGED if it already drops+reloads; otherwise patched
  products-manifest.json         # CREATED — slug → productId → image-uuid lookup; source for product.json + uploads
  verify-products.sh             # CREATED — post-seed smoke check (optional but recommended)
```

Images are committed to the repo. Each JPEG is downscaled to ~800×800 and
optimized to ≤150 KB. Total committed binary footprint: ~3–4 MB.

Source images are CC0 (Pexels / Unsplash CC0 / similar) — `seed-images/README.md`
lists each filename with its source URL and license note.

## Image upload mechanism

`scripts/seed/minio-product-images.sh` does the upload directly via the MinIO
client (`mc`) — no JVM, no presign, no auth. Steps:

1. Source `docker/.env` for `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`,
   `MINIO_BUCKET`, `MINIO_PUBLIC_BASE_URL` (the last two with sensible
   defaults: bucket `core-s3`, base URL
   `http://localhost:9000/${MINIO_BUCKET}`).
2. Run `mc` inside the existing `mc` container or via `docker run --rm
   minio/mc` (whichever already exists in `docker/` compose; reuse, don't
   add a new container).
3. `mc alias set local http://minio:9000 ...` against the compose network.
4. `mc mb --ignore-existing local/${MINIO_BUCKET}` to ensure bucket exists.
5. Set the anonymous-read policy on `products/*` (matches the policy the app
   already expects per `CLAUDE.md` "Image storage" section).
6. For each `docker/seed-images/<category>/<slug>.jpg`:
   - Compute `productId` from a lookup table keyed by `<slug>` (the same
     table that produced `product.json`).
   - Compute `objectUuid` as a deterministic UUIDv5 from the slug (so
     reseeding produces the same key).
   - Upload to `local/${MINIO_BUCKET}/products/${productId}/${objectUuid}.jpg`
     with `Content-Type: image/jpeg`.
   - Skip if the object already exists with matching size (idempotent
     re-run).

The slug→productId→uuid mapping lives in `scripts/seed/products-manifest.json`
(committed). Both `minio-product-images.sh` and the source-of-truth for
generating `product.json` read from this manifest.

## Public URL convention

`image_url` in `product.json` is the literal string
`${MINIO_PUBLIC_BASE_URL}/products/${productId}/${objectUuid}.jpg`.

Default `MINIO_PUBLIC_BASE_URL`: `http://localhost:9000/core-s3`.

The script logs the resolved base URL on every run, so a `.env` drift
(e.g., bucket renamed) is visible in the seed output.

## Idempotency

- `make seed-data` re-runs cleanly:
  - `mongo-products.sh` drops + reinserts the `product` collection.
  - `minio-product-images.sh` skips uploads where the object already
    exists with matching size; bucket policy is reapplied each run.
- Reseeding does **not** touch other prefixes (e.g., `avatars/`).
- Re-running with a modified `products-manifest.json` (e.g., a new product
  added) inserts the new product and uploads its image; existing entries
  are unchanged unless the manifest changed.

## Verification

- `scripts/seed/verify-products.sh` (run manually or as a smoke step):
  1. `GET http://localhost:8080/product-service/v1/products?page=1&size=12` → expect 200 and `total >= 30`.
  2. `HEAD` the first returned `image_url` → expect 200 and `Content-Type: image/jpeg`.
  3. Pick one seeded sold-out product by id from the manifest → fetch detail → assert `quantity == 0`.
- Manual:
  - Visit `http://localhost:5173/` → see grid of 12 products with images.
  - Paginate to page 3 → see remaining 6 products.
  - Land on a seeded sold-out PDP → see `SOLD OUT` stamp; no `ADD TO CART`.

## Error / drift handling

- If MinIO is not reachable, `minio-product-images.sh` fails fast with a
  clear "is MinIO up? `make infra-up`" message and the seed pipeline aborts
  before touching MongoDB (so we never leave product rows pointing at
  missing images).
- If `docker/.env` is missing required keys, the script prints exactly which
  key is missing and exits non-zero.
- If a source JPEG is missing for a slug listed in the manifest, the script
  fails with the offending slug and the expected path.

## Out of scope (explicit YAGNI)

- No image generation pipeline — images are hand-curated and committed.
- No CDN or signed-URL flow — public anonymous-read on `products/*` matches
  what the app already does in production per `core-s3`.
- No backwards-compat shim for the old 5-product seed — `product.json` is
  fully replaced.
- No production seed (this is dev-only data; production seeding is a
  separate concern owned by ops).

## Decisions captured during brainstorming

- Catalog size: realistic ~30 products, not minimal 5.
- Hosting: real MinIO (not external CDN) — exercises the production
  storage path the app actually uses.
- Upload mechanism: direct `mc` (not via presign endpoint) — seed runs
  during `make bootstrap` before services are healthy; presign has its
  own integration tests.
- Image source: committed CC0 JPEGs (not Unsplash/picsum) — deterministic,
  offline-safe.
- Categories: 3 × 10 (`apparel`, `footwear`, `accessories`).
