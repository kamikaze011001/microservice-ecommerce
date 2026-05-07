# core-s3

S3-compatible object storage helpers. MinIO locally (`:9000`), AWS S3 in prod. Used by product-service (product images) and authorization-server (avatars).

## Layout
- `core_s3/` — presign helpers, HEAD-check helpers, key validators

## Two-step upload contract
1. `POST /<resource>/image/presign` (or `/avatar/presign`) — server returns `{uploadUrl, objectKey, expiresAt}`. The signed URL embeds Content-Type and a 5MB content-length-range as conditions.
2. Client `PUT`s the bytes to `uploadUrl` with the matching `Content-Type`.
3. `PUT /<resource>/image` (or `/avatar`) with `{objectKey}` — server HEAD-checks the object, validates the key prefix, stores the public URL.

The JVM never touches the bytes.

## Object keys
- Products: `products/{productId}/{uuid}.{ext}`
- Avatars: `avatars/{userId}/{uuid}.{ext}`

Both prefixes have anonymous-read enabled — the stored URL is just `{public-base-url}/{key}` so clients fetch directly.

## Configuration
All settings (`bucket`, `endpoint`, `path-style`, credentials, `public-base-url`) come from Vault path `secret/core-s3`. Switching MinIO → AWS S3 is a Vault-only change.

## Importing service must add Vault import
```yaml
spring.config.import: vault://secret/<service>,vault://secret/core-s3
```
Otherwise the module bean fails to wire on startup.
