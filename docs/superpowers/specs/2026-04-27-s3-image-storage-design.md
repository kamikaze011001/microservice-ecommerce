# S3 Image Storage Design

**Date:** 2026-04-27
**Status:** Approved — ready for implementation plan
**Scope:** v1 — single product image, single user avatar, presigned upload only

---

## Goal

Add image storage for products and user avatars using S3-compatible object
storage. Use MinIO locally and AWS S3 in production with identical application
code, swapped only via configuration.

## Non-goals (v1)

- Deleting old objects when replacing an image (orphan cleanup deferred)
- Multiple images per product / image galleries
- Thumbnail / resize pipeline
- CDN integration or signed GETs (objects are public-read)
- Migration / backfill of existing seed data (new column nullable; admins backfill)

---

## Architecture

### Storage backend
- **Dev:** MinIO container in `docker/minio.yml`, S3 API on `:9000`, console
  on `:9001`. Bucket created on boot by a one-shot `mc` init container that
  also sets the anonymous-read policy. Started by `make infra-up`.
- **Prod:** AWS S3. Same Java code; only `endpoint` (unset), `path-style`
  (false), and credentials change.

### Bucket layout

Single bucket `ecommerce-media` with two prefixes:
- `products/{productId}/{uuid}.{ext}` — product images
- `avatars/{userId}/{uuid}.{ext}` — user avatars

Both prefixes are public-read. The plain public URL is what gets stored in
the database; clients fetch images directly.

### Module layout

New shared module **`core/core-s3`** (peer of `core-redis`, `core-paypal`).

| Class | Responsibility |
|---|---|
| `S3Properties` | `@ConfigurationProperties("s3")` — endpoint, region, bucket, credentials, path-style, public-base-url, presign-ttl, max-upload-size, allowed-types |
| `S3Config` | Builds `S3Client` and `S3Presigner` beans from `S3Properties` |
| `S3StorageService` | Interface — `presignUpload`, `objectExists`, `publicUrl` |
| `S3StorageServiceImpl` | Wraps the AWS SDK |
| `PresignedUpload` (record) | `{ uploadUrl, objectKey, expiresAt }` |

Consumers (`product-service`, `authorization-server`) add a Maven dependency
on `core-s3`, follow the existing manual-bean-wiring pattern in their
`*ServiceConfiguration` classes, and expose their own domain-scoped
endpoints.

No new microservice. No new Eureka entry.

---

## Data model

### Product (MongoDB, `ecommerce_inventory.product`)

Add one nullable field:

```java
@Data @NoArgsConstructor @AllArgsConstructor @Builder @Document
public class Product {
    @Id private String id;
    private String name;
    private Double price;
    private Map<String, Object> attributes;
    @Indexed private String category;
    private String imageUrl;   // NEW — nullable
}
```

Mongo is schemaless; no migration step required. Existing documents return
`imageUrl == null` until set.

### User (MySQL, `ecommerce_dev.user`)

Add one nullable column:

```sql
ALTER TABLE `user` ADD COLUMN avatar_url VARCHAR(512) NULL;
```

```java
@Entity @Table(name = "\"user\"") @Data
public class User {
    // existing fields …
    @Column(name = "avatar_url")
    private String avatarUrl;   // NEW — nullable
}
```

The ALTER lands in `docker/ecommerce.sql` (re-seed for fresh installs) and
is also applied to live dev DBs via a one-off SQL snippet documented in the
plan.

---

## API surface

All paths include the service's context-path per the gateway-routing
convention in `CLAUDE.md`. All responses use `BaseResponse` factories.

### product-service (admin only — `@PreAuthorize("hasRole('ADMIN')")`)

```
POST /product-service/v1/products/{id}/image/presign
Body:    { "contentType": "image/jpeg", "sizeBytes": 1234567 }
200:     BaseResponse<{ uploadUrl, objectKey, expiresAt }>
400:     IMAGE_TYPE_NOT_ALLOWED | IMAGE_TOO_LARGE
404:     PRODUCT_NOT_FOUND
```

```
PUT  /product-service/v1/products/{id}/image
Body:    { "objectKey": "products/{id}/{uuid}.jpg" }
200:     BaseResponse<ProductResponse>            (imageUrl populated)
400:     IMAGE_NOT_UPLOADED
403:     IMAGE_KEY_FORBIDDEN                      (key prefix mismatch)
404:     PRODUCT_NOT_FOUND
```

### authorization-server (current user only — uses `X-User-Id`)

```
POST /authorization-server/v1/users/me/avatar/presign
Body:    { "contentType": "image/png", "sizeBytes": 234567 }
200:     BaseResponse<{ uploadUrl, objectKey, expiresAt }>
400:     IMAGE_TYPE_NOT_ALLOWED | IMAGE_TOO_LARGE
```

```
PUT  /authorization-server/v1/users/me/avatar
Body:    { "objectKey": "avatars/{userId}/{uuid}.png" }
200:     BaseResponse<UserResponse>               (avatarUrl populated)
400:     IMAGE_NOT_UPLOADED
403:     IMAGE_KEY_FORBIDDEN                      (key prefix mismatch)
```

---

## Upload flow

```
client                  backend                       S3 / MinIO
  │ POST .../presign       │                             │
  │  {contentType,size}    │                             │
  │───────────────────────►│                             │
  │                        │ 1. validate type & size     │
  │                        │ 2. authorize caller         │
  │                        │ 3. mint UUID, build key     │
  │                        │ 4. S3Presigner.presignPut(  │
  │                        │     key,                    │
  │                        │     contentType,            │
  │                        │     content-length-range:   │
  │                        │       0..maxBytes,          │
  │                        │     ttl: 5 min)             │
  │ {uploadUrl, key, exp}  │                             │
  │◄───────────────────────│                             │
  │                                                      │
  │ PUT uploadUrl  (raw bytes; Content-Type header)      │
  │─────────────────────────────────────────────────────►│
  │                                                 200  │
  │◄─────────────────────────────────────────────────────│
  │                        │                             │
  │ PUT .../image {key}    │                             │
  │───────────────────────►│                             │
  │                        │ 1. authorize caller         │
  │                        │ 2. key prefix matches       │
  │                        │    {productId} | {userId}   │
  │                        │ 3. HEAD object exists       │
  │                        │────────────────────────────►│
  │                        │◄────────────────────────────│
  │                        │ 4. set entity.imageUrl =    │
  │                        │    publicUrl(key) and save  │
  │ updated entity         │                             │
  │◄───────────────────────│                             │
```

**Why this shape:**
- Presign-only is fast and bandwidth-free for the JVM, but it trusts the
  client to finish the upload. The HEAD on attach is the cheap server-side
  proof that the bytes are actually in S3.
- The key-prefix check on attach (against the path-param product id or the
  JWT-derived user id) prevents a client from attaching someone else's
  object to their own resource.
- The signed `content-length-range` and `Content-Type` conditions push
  validation into S3 itself — even if a client edits the URL, S3 rejects
  the upload. The backend never sees the bytes.

---

## Configuration

### Vault — new path `secret/core-s3`

| Key | Dev value | Prod value |
|---|---|---|
| `endpoint` | `http://minio:9000` | *(blank — SDK default)* |
| `region` | `us-east-1` | actual region |
| `bucket` | `ecommerce-media` | `ecommerce-media` |
| `access-key` | `minioadmin` | IAM user access key |
| `secret-key` | `minioadmin` | IAM user secret key |
| `path-style` | `true` | `false` |
| `public-base-url` | `http://localhost:9000/ecommerce-media` | `https://ecommerce-media.s3.<region>.amazonaws.com` |
| `presign-ttl` | `PT5M` | `PT5M` |
| `max-upload-size` | `5242880` (5 MB) | `5242880` |
| `allowed-types` | `image/jpeg,image/png,image/webp` | same |

Added to `scripts/vault/import-secrets.sh` so `make vault-import` picks it
up. Consuming services add `secret/core-s3` to their `bootstrap.yml`
imports list.

### Docker — new `docker/minio.yml`

- `minio` service — `minio/minio` image, `:9000` and `:9001` published,
  named volume for data, env `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`
  matching Vault `access-key` / `secret-key`.
- `minio-init` one-shot — `minio/mc` image, depends on `minio` healthy,
  creates the bucket and applies anonymous-read policy on `products/*` and
  `avatars/*`. Idempotent: `mc mb --ignore-existing`, policy reapply is a no-op.

`scripts/infra/up.sh` adds `docker/minio.yml` to its compose-file list. No
change needed in `down.sh` / `status.sh` — they iterate the same list.

---

## Error model

All errors flow through the existing `core-exception-api` global handler
and produce a `BaseResponse` with a stable error code. New codes:

| Code | HTTP | Cause |
|---|---|---|
| `IMAGE_TYPE_NOT_ALLOWED` | 400 | Content-type not in allowlist |
| `IMAGE_TOO_LARGE` | 400 | `sizeBytes` > `max-upload-size` |
| `IMAGE_KEY_FORBIDDEN` | 403 | Object key prefix doesn't match the path-param resource id (products) or the caller's `X-User-Id` (avatars) |
| `IMAGE_NOT_UPLOADED` | 400 | HEAD on attach returns 404 — client never finished the upload |
| `STORAGE_UNAVAILABLE` | 503 | SDK threw `S3Exception` / `SdkClientException` |

Existing codes (`PRODUCT_NOT_FOUND`, `USER_NOT_FOUND`) reused for entity
lookup failures.

---

## Authorization

| Endpoint | Check |
|---|---|
| Product presign + attach | `@PreAuthorize("hasRole('ADMIN')")` (same as other admin product mutations) |
| Avatar presign + attach | `X-User-Id` header (gateway-injected) — path is `/users/me/...` so no IDOR by construction; key prefix MUST equal `avatars/{X-User-Id}/` |

Service-to-service calls are not in scope — these endpoints are caller-facing only.

---

## Testing

### `core-s3` (unit / integration)
- Testcontainers `MinIOContainer` (`testcontainers:minio`).
- Real `S3Client` + `S3Presigner` against the container.
- Cover: bucket create, `presignUpload` returns a working signed URL, raw
  HTTP `PUT` to that URL succeeds, `objectExists` returns true after, and
  false for an unknown key.
- Negative: a `PUT` exceeding `content-length-range` or with a wrong
  `Content-Type` is rejected by MinIO (validates the signed conditions).

### product-service / authorization-server (controller)
- `@WebMvcTest` with `S3StorageService` mocked.
- Cover: presign happy path returns expected JSON shape; type/size
  validation returns 400; attach with a key-prefix mismatch returns 403;
  attach when `objectExists` is false returns 400; attach happy path
  persists `imageUrl` / `avatarUrl` and returns the updated entity.

### `contextLoads`
- Guarded — passes without MinIO running, per the orchestrator-service
  pattern documented in `CLAUDE.md`.

---

## Risks & open questions

- **Orphans:** v1 leaks objects on replace and on failed attach (presigned
  but never attached). Acceptable in v1; v2 introduces a sweep job that
  lists `products/` / `avatars/` and deletes unreferenced keys older than
  N hours.
- **Public-read default:** appropriate for product/avatar imagery. If the
  product set later includes anything sensitive (e.g. licensed content),
  v2 switches to GET presigns and removes the anonymous policy.
- **MinIO ↔ AWS path-style:** the most common deployment-time bug class.
  Both `path-style` and `endpoint` must be flipped together; integration
  tests against MinIO will not catch a virtual-host-style misconfig in
  prod. Mitigation: smoke-test the real bucket on first prod deploy.
