# Local dev: fix the blanket 403 and start the frontend from `make up`

Date: 2026-07-12
Status: Approved

## Problem

After `make up`, every service reports healthy in `make status`, but every frontend API
call returns HTTP 403. The symptom looks like a CORS failure, and that was the initial
hypothesis. It is not CORS.

## Diagnosis (measured against a live stack, not inferred)

CORS is configured correctly and works. Measured against the running gateway:

```
OPTIONS /bff-service/v1/cart           -> 200, Access-Control-Allow-Origin: http://localhost:5173
OPTIONS /bff-service/v1/cart:add-item  -> 200
```

`http://localhost:5173` is in `application.gateway.cors.allowed-origins`, and Spring's
`CorsWebFilter` is registered at `SecurityWebFiltersOrder.CORS` — ahead of `AUTHENTICATION`
and `AUTHORIZATION`. It answers preflight itself and short-circuits, so `OPTIONS` never
reaches the authorization filter. (Consequence: the fact that no `api_role` row lists
`OPTIONS` in its method array is harmless. It looks like a bug and is not one.)

The real cause: **the MongoDB `api_role` collection was empty (`countDocuments() == 0`).**

The gateway's `AuthorizationFilter` resolves every request's permissions from that
collection. A path matching zero rows returns 403 `auth.forbidden` ("API path is not
registered in the system"):

```java
if (apiRoles.isEmpty()) {
    return handleError(exchange, HttpStatus.FORBIDDEN, "auth.forbidden", ...);
}
```

With the table empty, *every* path matched zero rows, so *everything* 403'd — including
`PERMIT_ALL` routes that require no token at all. That is the diagnostic tell, and it is
what rules out CORS and rules out auth: in this gateway a 403 can never mean
"unauthenticated" (that is a 401 from `JwtAuthenticationFilter`). A 403 means only "no
matching `api_role` row" or "wrong role".

Seeding the 40 rows from `docker/api_role.json` fixed it. Before / after:

| Request | Before | After |
|---|---|---|
| `GET /product-service/v1/products` (PERMIT_ALL) | 403 | 200 |
| `GET /bff-service/v1/products/{id}` | 403 | 200 |
| `GET /bff-service/v1/cart` (no token) | 403 | 401 (correct) |

The 403 -> 401 flip on the authenticated route is the signature of the fix.

### Why `make up` produces this state

```make
bootstrap: infra-up vault-init ... svc-start seed-data   # seeds
up:        infra-up vault-unseal mongo-connector-ensure svc-start   # does not seed
```

Only `bootstrap` seeds. On any machine whose Mongo volume is empty — fresh clone,
`make nuke`, a Docker prune or Desktop reset — `make up` brings up ten healthy services
and hands the developer a stack where every API call is forbidden. The health table is
green and the application is dead.

## Design

### Part 1 — Guarantee `api_role` exists on `make up`

`scripts/seed/mongo-roles.sh` already self-guards (`api_role already seeded (N docs) —
skipping`), so it is safe to call unconditionally. Add a `mongo-seed-ensure` Makefile
target that runs it, and wire it into `up`:

```make
up: infra-up vault-unseal mongo-seed-ensure mongo-connector-ensure svc-start
```

Ordering: after `infra-up` (Mongo must be alive) and before `svc-start` (no window where
services are up but unauthorized). The step needs a readiness retry — a started Mongo
container is not yet an accepting Mongo.

This mirrors the `mongo-connector-ensure` idiom already present in `up`.

**Scoped to `api_role` only — deliberately not `scripts/seed/all.sh`.** `mongo-products.sh`
drops its collection before importing, so calling `all.sh` from `up` would silently wipe
local product data on every `make up`. The restraint is the point.

### Part 2 — Start the frontend from `make up`

Add one entry to `scripts/services.list`:

```
"frontend  5173  -  4"
```

Tier 4, so the SPA starts only after the gateway (tier 1) is listening.

**`scripts/services/start.sh`** — `start_one` currently hardcodes `mvn spring-boot:run`.
Branch on what the directory contains:

- `pom.xml` -> existing `mvn spring-boot:run` path, including the `service_java_home`
  JDK step-up. Unchanged.
- `package.json` -> `pnpm dev`, running `pnpm install` first if `node_modules` is absent.

The tier loop grows from `0 1 2 3` to `0 1 2 3 4`. Fail with a clear message if `pnpm`/
`node` is unavailable.

**`scripts/services/stop.sh`** — replace its home-grown `awk`/`read` parser with
`registry.sh`'s `svc_list` / `svc_field`, the same helpers `start.sh` and `status.sh`
already use.

This is load-bearing, not a drive-by. `services.list` stores entries as quoted bash array
elements (`"gateway  6868  -  1"`). `registry.sh` sources the file, so bash strips the
quotes. `stop.sh` instead parses the raw text, so it sees `"gateway` (leading quote) and
also ingests the literal `SERVICES=(` and `)` lines. Consequences today:

- no pidfile ever matches -> nothing is ever SIGTERMed;
- `port_for` always returns empty -> the `lsof` orphan-kill fallback never fires;
- `make down` prints "All services stopped" while stopping nothing.

The bug is masked because `make down` also runs `infra-down`, and the JVM services crash
on their own once Vault/MySQL disappear. **Vite has no such dependency.** Without this
fix, adding the frontend would leave a Vite process squatting on 5173 after `make down`,
and the next `make up` would fail to bind — i.e. our change would introduce a new failure
mode. Fixing the parser also restores `make down` for all ten existing services and gives
Vite-child cleanup for free via the existing `lsof -tiTCP:5173` fallback (`pnpm dev` forks
a child, so the pidfile PID alone is not enough).

`status.sh` already uses `registry.sh`, so `frontend` appears in `make status` with no
further change.

### Part 3 — Same-origin `/api` in dev

Add `frontend/.env.development`:

```
VITE_API_BASE_URL=/api
```

The `/api` proxy in `vite.config.ts` already exists, already targets `http://localhost:6868`,
and already strips the prefix — it has simply never been used, because the client defaults
to the absolute `http://localhost:6868`:

```ts
const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868';
```

With the change, the browser calls `http://localhost:5173/api/...` — same-origin. No
preflight, no CORS, no allow-list to drift out of; Vite forwards server-side to the gateway.
Local dev then exercises the same same-origin topology as AWS, and the
`127.0.0.1`-vs-`localhost` footgun (which would defeat the CORS allow-list for real)
disappears.

This is cleanup, not the bug fix. CORS was never broken. It is included because it removes
the entire class of failure the original hypothesis pointed at.

Also correct two stale docs found during the investigation:

- root `CLAUDE.md` states the gateway is on port **8080**; it is **6868**
  (`scripts/services.list`). 8080 is the Caddy port inside the frontend container.
- `frontend/CLAUDE.md` claims "client sends credentials"; it does not — there is no
  `withCredentials` / `credentials: 'include'` anywhere in `src/`.

## Blast radius: k8s local dev and AWS are untouched

Each part is structurally incapable of reaching k8s or AWS:

- **Part 1.** `make up` / `mongo-seed-ensure` are local-only targets. k8s seeds via
  `k8s-seed`; AWS is separate.
- **Part 2.** The consumers of `scripts/services.list` are `registry.sh`, `start.sh`,
  `stop.sh`, and `next-error-target.mjs`. `k8s/images/build.sh` maintains its **own**
  `SERVICES=(...)` array and does not read the file. `next-error-target.mjs` filters to
  `name.endsWith('-service') || name === 'gateway'`, so `frontend` is ignored. `check_drift`
  scans directories -> list, so an extra list entry cannot trip it (and `frontend/` is not
  in its glob anyway).
- **Part 3.** `VITE_API_BASE_URL` is build-time; Vite inlines it. Vite loads
  `.env.development` **only** in dev mode. `pnpm build` runs in production mode and never
  reads it, and Docker builds pass `--build-arg VITE_API_BASE_URL` explicitly — which takes
  precedence over `.env` files in Vite regardless. k8s bakes
  `http://api.microecom.local` (`k8s/images/build.sh`); the AWS overlay bakes it empty for
  same-origin. Vitest runs in test mode, so it does not load `.env.development` and the
  existing unit tests keep their current fallback.

`.env.development` is not gitignored (`frontend/.gitignore` ignores only `.env.local` and
`.env.*.local`), so it is committed and shared.

## Verification

Reproduce the original failure and prove it cannot recur:

1. Drop the collection (`db.api_role.drop()`), run `make up`, and assert
   `GET /product-service/v1/products` returns **200**, not 403.
2. Assert an authenticated route with no token returns **401**, not 403.
3. Run `make up` twice; the seed step must be a no-op the second time and must not wipe
   `product`.
4. `make up` starts Vite; `http://localhost:5173` serves the SPA and its API calls go to
   `/api/...` with no CORS preflight.
5. `make down` frees port 5173 (`lsof -tiTCP:5173` empty) and stops the JVM services.
6. `pnpm test` and `pnpm typecheck` stay green.
