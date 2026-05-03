# Seed images

Placeholder JPEGs used by `make seed-data` to populate MinIO with product
images. Each image is keyed by `<category>/<slug>.jpg` matching the
`scripts/seed/products-manifest.json` entries.

## Source

All images fetched from `picsum.photos` (Lorem Picsum) via deterministic
slug-keyed seeds: `https://picsum.photos/seed/<slug>/800/800.jpg`. Lorem
Picsum content is public-domain / Unsplash-CC0; see
https://picsum.photos/about for licensing.

## Re-fetch

```bash
bash scripts/seed/fetch-seed-images.sh           # fill in missing files only
FORCE=1 bash scripts/seed/fetch-seed-images.sh   # overwrite all
```

Images are committed to the repo so seeding is offline-safe.
