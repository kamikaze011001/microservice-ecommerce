# Refresh Token — Tier 2 (Server-State + Rotation + Reuse Detection)

**Date:** 2026-05-08
**Owner:** anhson713@gmail.com
**Status:** Design — approved, awaiting plan

## Context

Backend already issues a refresh token (RT) at login and exposes
`POST /authorization-server/v1/auth:refresh-token`. The frontend stores both
the access token (AT) and RT in `localStorage` (`aibles.auth`) but **never
calls the refresh endpoint** — its 401 interceptor (`frontend/src/api/client.ts:39-43`
and `:79-83`) clears the store and redirects to `/login` immediately.

Symptom the user sees: AT lifetime is 15 min, so any session that idles
through expiry → next request 401 → redirected to login. The RT field is
dead state.

Goal: stop kicking the user out, and upgrade to a security posture where
stolen refresh tokens are detectable and revocable.

## Scope (Tier 2)

In:
- Frontend: wire the refresh endpoint into the 401 interceptor with
  single-flight + retry semantics. Add logout buttons.
- Backend: switch RT from JWT to opaque random string. Track RT state in
  Redis. Implement rotation, reuse detection, current-device logout, and
  log-out-all-devices. Wire password change into family revocation.
- Migration: existing logged-in users get one forced re-login on first 401
  after deploy.

Out (deferred to Tier 3):
- Moving RT from `localStorage` into an `httpOnly` cookie.
- Moving AT from `localStorage` into memory only.
- Cookie-aware CORS / CSRF rework on the gateway.

The Tier 3 swap is a pure transport change; everything in this design
remains valid.

## Architecture

### Token format

| Token | Format | Where it lives | Lifetime |
|---|---|---|---|
| Access token | RS256 JWT (unchanged) | `localStorage` (FE), Bearer header on every request | 15 min |
| Refresh token | **Opaque 32-byte URL-safe random string** | `localStorage` (FE), Redis (BE source of truth) | 7 days |

The AT keeps its current shape — gateway already validates it via JWKS, no
ripple effects in downstream services. Only the RT changes.

### Redis schema

```
rt:{rawToken}            → familyId                                       (string,  TTL = RT lifetime)
family:{familyId}        → hash{userId, currentToken, createdAt, expiresAt} (hash,  TTL = RT lifetime)
user:{userId}:families   → SET<familyId>                                  (set,    TTL = RT lifetime)
```

- `rt:{rawToken}` is the lookup primitive. Token presented at refresh →
  this tells us which family it belongs to.
- `family:{familyId}` holds the *current* (most-recently-rotated) RT. Reuse
  detection compares against this.
- `user:{userId}:families` is the index that makes "log out all devices"
  cheap. One `SMEMBERS` + N `DEL`.

**Why we don't `DEL rt:{oldToken}` on rotation.** Leaving the old key in
Redis (until natural TTL) is what lets us *detect* reuse: a replayed old RT
still resolves to a familyId, but the family record's `currentToken` has
moved on. Mismatch → reuse → revoke whole family. Costs ~one stale `rt:*`
key per refresh per family until expiry — at 15min refresh cadence and 7d
RT lifetime, ~670 keys per active family. Acceptable in Redis terms;
explicit cleanup not required.

### Refresh lifecycle

**Login** (`/auth:login`):
1. Authenticate → generate AT (existing path) + opaque RT
   (`SecureRandom.nextBytes(32)` → URL-safe Base64).
2. `familyId = UUID()`.
3. `SET rt:{rawToken} = familyId` (TTL = RT lifetime).
4. `HSET family:{familyId}` with `userId, currentToken, createdAt, expiresAt`
   (TTL = RT lifetime).
5. `SADD user:{userId}:families familyId` (TTL = RT lifetime, refreshed on
   each new family).
6. Return `{accessToken, refreshToken: rawToken, ...}`.

**Refresh** (`/auth:refresh-token`):
```
familyId = GET rt:{incomingToken}
if !familyId        → 401 TOKEN_INVALID  (unknown / expired)

family = HGETALL family:{familyId}
if !family          → 401 TOKEN_INVALID  (revoked)

if family.currentToken != incomingToken:
    # Reuse: this RT was once valid but the family rotated past it.
    DEL family:{familyId}
    SREM user:{family.userId}:families familyId
    log.warn("refresh-token reuse detected", userId, familyId)
    return 401 TOKEN_INVALID

newToken = randomOpaque()
SET rt:{newToken} = familyId  (TTL = remaining family lifetime — see below)
HSET family:{familyId} currentToken = newToken
return {accessToken: newAT, refreshToken: newToken}
```

**Session lifetime semantics: hard-cap, not sliding.** A family is born at
login with `expiresAt = now + 7d`. Rotated RTs inherit *that* boundary —
new `rt:{newToken}` TTL is `expiresAt - now`, not a fresh 7d. Same for the
family record itself. This means:
- Active session → user keeps refreshing seamlessly until day 7, then must
  re-login.
- Idle session → `rt:*` key TTLs naturally; user re-logins on return.
- Sliding sessions (where each refresh extends 7d) are deferred to a later
  iteration if needed; hard-cap keeps the security model simple and
  predictable.

**Logout-current** (`/auth:logout`, body-less, RT in `Authorization` header):
1. `familyId = GET rt:{token}` → reject 401 if missing.
2. `DEL family:{familyId}`, `SREM user:{userId}:families familyId`.
3. Stale `rt:*` keys for that family die by TTL or 401-on-family-miss
   thereafter.

**Logout-all** (`/auth:logout-all`, AT-authenticated, reads `X-User-Id`):
1. `familyIds = SMEMBERS user:{userId}:families`.
2. `DEL family:{f1} family:{f2} …`.
3. `DEL user:{userId}:families`.

### Reuse-detection truth table

| Scenario | Behavior |
|---|---|
| Replay current RT (race with rotation) | First request rotates; second sees `currentToken` mismatch → revoke family |
| Stolen RT replayed after legitimate user rotated | Mismatch → revoke family. Legitimate user gets logged out — by design (alarms them, kicks the thief). |
| RT presented after logout-current | `family:{id}` missing → 401 |
| RT presented after logout-all | All `family:*` for that user gone → 401 |
| RT presented after natural expiry | `rt:{token}` TTL'd → 401 |
| RT presented after password change | `family:*` wiped (see below) → 401 |

### Password change → revoke all families

`POST /v1/users/self/change-password` and the forgot-password reset path
both call the same "wipe all families" routine after a successful
password update. This is the moment where killing all sessions actually
matters — and it's what makes a 7-day RT lifetime safe to ship.

## API Surface

All under `/authorization-server/v1`. `BaseResponse<T>` envelope unchanged.

| Method | Path | Auth | Body | Result |
|---|---|---|---|---|
| POST | `/auth:login` | none | `{email, password}` | **Modified** — RT is now opaque |
| POST | `/auth:refresh-token` | `Authorization: Bearer <RT>` | — | **Modified** — Redis lookup, rotation, reuse detection |
| POST | `/auth:logout` | `Authorization: Bearer <RT>` | — | **New** — revoke current family |
| POST | `/auth:logout-all` | `Authorization: Bearer <AT>` (uses `X-User-Id`) | — | **New** — revoke all families |
| POST | `/users/self/change-password` | AT | `{old, new}` | **Augmented** — wipe all families on success |
| POST | `/auth:reset-password` | reset token | `{token, newPassword}` | **Augmented** — wipe all families on success |

**Why RT for `/auth:logout` and AT for `/auth:logout-all`.** Logout-current
acts on a specific family — the RT identifies which one. Logout-all acts
on a user — AT carries `userId`. Picking the right credential per endpoint
keeps each handler's lookup trivial.

**Error contract.** Unknown RT, family revoked, and reuse detected all
return the same `401 TOKEN_INVALID`. Distinguishing them on the wire would
leak information to an attacker. Server logs distinguish them for ops /
alerting.

## Frontend

### Where the change lives

`frontend/src/api/client.ts` already has duplicated 401 handling in the
openapi-fetch middleware (`:39-43`) and in `apiFetchUnsafe` (`:79-83`).
Tier 2 factors refresh into a single helper that both paths call,
eliminating the duplication.

### Single-flight refresh

```ts
// frontend/src/api/refresh.ts (new)
let inflight: Promise<string | null> | null = null;

export async function refreshAccessToken(): Promise<string | null> {
  if (inflight) return inflight;
  inflight = doRefresh().finally(() => { inflight = null; });
  return inflight;
}

async function doRefresh(): Promise<string | null> {
  const auth = useAuthStore();
  if (!auth.refreshToken) return null;
  // POST /authorization-server/v1/auth:refresh-token with Bearer <RT>.
  // On success: auth.login({accessToken, refreshToken}) → return newAT.
  // On any failure: auth.clear() → return null.
}
```

**Why single-flight matters.** When a page mounts, multiple queries fire
in parallel. If AT just expired they all 401 simultaneously. Without
coalescing, each request would call `/refresh` independently — five
rotations in a millisecond, four of them seen as reuse, family revoked,
user kicked out. With single-flight, only the first request hits
`/refresh`; the rest await the same promise and replay with the new AT.

### 401 handling

```ts
async function handle401AndMaybeRetry(replay: () => Promise<Response>): Promise<Response | null> {
  const newAT = await refreshAccessToken();
  if (!newAT) {
    redirectToLogin();
    return null;
  }
  return replay();
}
```

The auth middleware re-reads `auth.accessToken` on every request, so
`replay()` automatically picks up the rotated AT.

### Edge cases

| Case | Behavior |
|---|---|
| Refresh endpoint itself 401s | Don't recurse — guard by URL match. Clear + redirect. |
| No RT in store | `refreshAccessToken()` returns null without a network call. |
| Non-idempotent POST 401 | Safe to replay — server-side rejected the first call before any side effect. |
| Multiple tabs | Each has its own `inflight`. Cross-tab sync via `storage` event in `auth.ts` so a refresh in tab A propagates the new tokens to tab B. |
| Refresh succeeds, replay also 401s | Don't loop. Treat the second 401 as terminal → redirect. |

### Logout wiring

- AppNav "Logout" button → `POST /auth:logout` with RT → `auth.clear()` →
  `router.replace('/login')`. If the network call fails, still clear
  locally; server family TTLs out.
- Account settings "Log out all devices" button (optional in this PR) →
  `POST /auth:logout-all` with AT → same local cleanup.

## Migration / Rollout

On deploy, every existing session holds a JWT-format RT. After the deploy
the `/refresh` endpoint expects opaque-format RTs and will 401 the old
ones. Result: each user gets one forced re-login on next 401.

Acceptable because:
- Dev project, no real users.
- Existing RT lifetime is 24h, so the old cohort drains within a day even
  without the explicit kick.
- One re-login is the cost of changing token semantics; no data migration
  is required.

## Testing

**Backend (`authorization-server`)**
- Login issues opaque RT; Redis has matching `rt:*`, `family:*`,
  `user:*:families` entries.
- Refresh rotates: old `currentToken` → new `currentToken`, returns new
  pair, both old and new `rt:*` keys exist (old one TTLs out).
- Reuse detection: present a stale (already-rotated) RT → family deleted,
  401 returned.
- Logout-current: `family:*` deleted, RT then 401s.
- Logout-all: every `family:*` for that user deleted in one call.
- Password change: family wipe runs, all sessions invalidated.

**Frontend**
- 401 → single-flight refresh → request replays with new AT.
- N parallel 401s → exactly one `POST /auth:refresh-token`.
- Refresh fails → redirect to `/login` with `next` query param.
- Cross-tab: tab A refreshes, tab B's `auth` store picks up new tokens via
  `storage` event.
- Logout button calls `/auth:logout` then clears.

## Risks / Open Questions

- **Redis as a hard dependency for auth.** If Redis is down, refresh and
  logout fail closed (401). Login also fails because we can't write the
  family record. This is correct behavior but worth noting in the readiness
  probe — Redis was already in `auth-server.readiness.include`, so this
  doesn't change the deploy model.
- **`SADD` after `SET`** isn't atomic. If we crash between writing
  `family:*` and `SADD user:*:families`, we get an orphan family that
  works for refresh but isn't reachable from logout-all. Acceptable —
  family naturally TTLs. Could wrap in a `MULTI/EXEC` if we care.
- **Cleanup of stale `rt:*` keys.** None — they expire by TTL. If we add
  Tier 3 we may revisit this when RTs move into an httpOnly cookie.

## Coworking Handoff Points

These are the spots where the user writes the code, not the assistant —
business logic and design choices that shape the feature:

1. **Reuse detection branch** in `AuthFacadeServiceImpl.refreshToken` — the
   ~10 lines that decide what to do when `currentToken != incomingToken`.
   This is the security primitive of the whole tier.
2. **`doRefresh()` body** in `frontend/src/api/refresh.ts` — the contract
   surface between FE and BE.
3. **Cross-tab `storage` listener** extension in `auth.ts` — small but the
   sync semantics shape multi-tab UX.
4. **Logout-all UX** in account settings — modal confirm, success toast,
   etc. UX decision, not boilerplate.
