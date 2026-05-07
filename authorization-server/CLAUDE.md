# authorization-server

JWT-based auth (RS256) + user/role management. Issues tokens that the gateway validates.

## Port & path
- App: `6666` (see `scripts/services.list`)
- Context path: `/authorization-server`
- Vault imports: `secret/ecommerce`, `secret/authorization-server`, `secret/core-s3`
- Readiness deps: `db, redis, mail` (don't drop these — startup will fail readiness)

## Layout
- `controller/` — REST endpoints (login, register, refresh, user CRUD, avatar)
- `service/impl/` — manual `@Bean` wiring in `configuration/` (no `@Service` annotations — see root CLAUDE.md)
- `repository/master/` writes, `repository/slave/` reads (routing datasource picks per package)
- `repository/projection/` — read-only views
- `filter/` — auth + tenant filters
- `annotation/` — custom validation (`@ValidEmail`, `@ValidPassword`)

## Avatar uploads
Two-step presign flow via `core-s3`:
1. `POST /v1/users/self/avatar/presign` → `{uploadUrl, objectKey}`
2. Client `PUT`s bytes
3. `PUT /v1/users/self/avatar` with `{objectKey}` — server HEAD-checks then stores public URL

Object key prefix: `avatars/{userId}/{uuid}.{ext}` (anonymous-read enabled).

## Gotchas
- Token signing key comes from Vault — sealed Vault → service crashes on boot.
- `UserDetailResponse` ships JSON via `SnakeCaseStrategy` — bff-service consumes it as a Map; key `userId` is `user_id` on the wire.
