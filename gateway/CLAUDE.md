# gateway

Spring Cloud Gateway. Single entry point for all browser traffic. JWT validation + `X-User-Id` injection + CORS + Swagger aggregation.

## Port
- App: `6868` (services.list); external: `8080` per project README
- Eureka client — discovers downstreams by service name

## Layout
- `configuration/` — route definitions, CORS bean (`CorsConfigurationSource`), security
- `filter/` — JWT validation, `X-User-Id` header injection
- `repository/`, `entity/` — auth rules loaded from MongoDB (`api_role` collection, seeded from `docker/api_role.json`)

## Routing rules (don't violate)
- Routes use `Path=/<service-name>/**` → `lb://<SERVICE-NAME>` (uppercase, **no `StripPrefix`**)
- Each downstream sets `server.servlet.context-path: /<service-name>` so the prefix lands naturally
- `GET /product-service/v1/products/**` and `GET /bff-service/v1/products/**` are `PERMIT_ALL`
- All other routes need auth; admin routes require `ADMIN` role
- Auth rules live in MongoDB (`api_role`), edited via `docker/api_role.json` + `make seed-data`
- **`/actuator/**` is intentionally NOT routed** — management ports are internal-only

## CORS
Single `CorsConfigurationSource` covers all routes. Config under `application.gateway.cors.*` in `application.yml` (Vault override available). Defaults: `http://localhost:3000`, `http://localhost:5173`, `allow-credentials=true`. Per-service CORS would be redundant.

## JWT
Validates RS256 token, extracts `userId`, forwards as `X-User-Id` header. Downstreams read via `@RequestHeader("X-User-Id")` — never parse JWTs in business services.
