# Seed images

Placeholder JPEGs used by `make seed` (ENV=compose STAGE=pre-apps — also run
automatically on every `make up` via `mongo-seed-ensure`) to populate MinIO
with product images. Each image is keyed by `<category>/<slug>.jpg`, matching
the `category` and `imageUrl` of the corresponding entry in
`deploy/seed/product.json` — that is what `seed.sh` reads to decide which
bytes to upload, so the filename must agree with the seeded `imageUrl`.

(Originally generated from `scripts/seed/products-manifest.json`, deleted in
Phase 8 along with the rest of the old seed tree.)

## Source

All images fetched from `picsum.photos` (Lorem Picsum) via deterministic
slug-keyed seeds: `https://picsum.photos/seed/<slug>/800/800.jpg`. Lorem
Picsum content is public-domain / Unsplash-CC0; see
https://picsum.photos/about for licensing.

## Re-fetch

**There is no re-fetch command.** `scripts/seed/fetch-seed-images.sh` and the
`products-manifest.json` it read were deleted in Phase 8 with **no
replacement**, a known and accepted loss: the canonical seed path consumes
these JPEGs but cannot regenerate them.

So the committed JPEGs are the only source. To change or add one, drop the
file in by hand at `<category>/<slug>.jpg`, matching the `category` and the
`imageUrl` filename of that product's entry in `deploy/seed/product.json` — a
mismatch surfaces as `missing local seed image: …` from `seed.sh` and fails
the seed, which is the intended loud failure rather than a silently absent
image.

To restore the old generator, recover it from git history:
`git log --diff-filter=D -- scripts/seed/fetch-seed-images.sh`.

Images are committed to the repo so seeding is offline-safe.
