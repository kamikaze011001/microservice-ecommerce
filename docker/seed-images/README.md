# Seed images

Placeholder JPEGs used by `make seed` (ENV=compose STAGE=pre-apps — also run
automatically on every `make up` via `mongo-seed-ensure`) to populate MinIO
with product images. Each image is keyed by `<category>/<slug>.jpg`,
originally generated to match `scripts/seed/products-manifest.json`'s
entries.

## Source

All images fetched from `picsum.photos` (Lorem Picsum) via deterministic
slug-keyed seeds: `https://picsum.photos/seed/<slug>/800/800.jpg`. Lorem
Picsum content is public-domain / Unsplash-CC0; see
https://picsum.photos/about for licensing.

## Re-fetch

`scripts/seed/fetch-seed-images.sh` (and the `products-manifest.json` it
reads) live under `scripts/seed/`, which is slated for deletion with **no
replacement** — there is no canonical re-fetch command for these images.
Until/unless one is added, the committed JPEGs below are the only source; a
replacement image has to be dropped in by hand at the same
`<category>/<slug>.jpg` path.

Images are committed to the repo so seeding is offline-safe.
