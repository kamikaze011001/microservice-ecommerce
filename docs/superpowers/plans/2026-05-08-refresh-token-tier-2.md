# Refresh Token Tier 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire end-to-end refresh-token rotation with reuse detection, server-side family revocation, and frontend single-flight retry — so the SPA stops kicking the user to `/login` when the 15-minute access token expires.

**Architecture:** Backend switches the refresh token from a self-contained JWT to an opaque random string backed by Redis state (`rt:{token} → familyId`, `family:{familyId} → {userId, currentToken, ...}`, `user:{userId}:families → SET<familyId>`). Refresh rotates the token and detects reuse by mismatch against `family.currentToken`. Frontend coalesces concurrent 401s into a single refresh call and replays the original request.

**Tech Stack:** Spring Boot 3.3.6, Java 17, Spring Data Redis (Lettuce), Vue 3 + Pinia + openapi-fetch, Vault for config.

**Spec:** `docs/superpowers/specs/2026-05-08-refresh-token-tier-2-design.md`

**Coworking handoff points** — sections the user writes, not the assistant:
- **Task 4** — reuse detection branch in `RefreshTokenServiceImpl.lookupAndRotate`
- **Task 11** — `doRefresh()` body in `frontend/src/api/refresh.ts`
- **Task 13** — cross-tab `storage` listener extension in `auth.ts`
- **Task 15** — "Log out all devices" UX in account settings

---

## File Structure

### Backend (`authorization-server`)

| Path | Action | Purpose |
|---|---|---|
| `service/RefreshTokenService.java` | Create | Interface for opaque-RT operations |
| `service/impl/RefreshTokenServiceImpl.java` | Create | Redis-backed implementation: issue, rotate, revoke |
| `dto/internal/TokenFamily.java` | Create | Hash-shaped value object stored at `family:{familyId}` |
| `exception/TokenReuseException.java` | Create | 401 with code TOKEN_INVALID — same wire shape as `TokenInvalidException` |
| `service/impl/AuthFacadeServiceImpl.java` | Modify | login uses opaque RT; refreshToken delegates to RefreshTokenService; new logout/logoutAll methods |
| `service/AuthFacadeService.java` | Modify | Add `logout(String rt)` and `logoutAll(String userId)` |
| `controller/AuthUserController.java` | Modify | Add `/auth:logout` and `/auth:logout-all` |
| `controller/UserController.java` | Modify | After successful `:update-password`, revoke all families |
| `service/UserService.java` + impl | Modify | Pass userId-driven family wipe through to RefreshTokenService |
| `configuration/AuthorizationServerConfiguration.java` | Modify | Bean wiring for `RefreshTokenServiceImpl` + updated `AuthFacadeServiceImpl` constructor |
| `configuration/SecurityConfiguration.java` | Modify | Permit `/auth:logout` (RT-authenticated, no AT filter chain) |
| `docker/vault-configs/authorization-server.json` | Modify | Bump RT lifetime from 24h to 7d |

### Frontend

| Path | Action | Purpose |
|---|---|---|
| `frontend/src/api/refresh.ts` | Create | Single-flight `refreshAccessToken()` + `doRefresh()` body (handoff point) |
| `frontend/src/api/client.ts` | Modify | Replace inline 401 handling with `handle401AndMaybeRetry`; deduplicate two paths |
| `frontend/src/stores/auth.ts` | Modify | Cross-tab `storage` listener handles new tokens, not just clear (handoff point) |
| `frontend/src/api/queries/auth.ts` | Modify | Add `useLogoutMutation`, `useLogoutAllMutation` hooks |
| `frontend/src/components/layout/AppNav.vue` | Modify | Wire logout button to `/auth:logout` |
| `frontend/src/pages/account/...` | Modify | Add "Log out all devices" button (handoff point — UX choice) |
| `frontend/src/api/schema.d.ts` | Regenerate | After Swagger updates with new endpoints |

### Tests

| Path | Action |
|---|---|
| `authorization-server/src/test/java/.../RefreshTokenServiceImplTest.java` | Create |
| `authorization-server/src/test/java/.../AuthFacadeServiceRefreshTest.java` | Create |
| `frontend/tests/unit/api/refresh.spec.ts` | Create |
| `frontend/tests/unit/api/client.spec.ts` | Modify (existing 401 tests change) |

---

## Task 0: Create branch and worktree state

- [ ] **Step 1: Branch off main**

```bash
git checkout main && git pull
git checkout -b feat/refresh-token-tier-2
```

- [ ] **Step 2: Confirm Redis available locally**

```bash
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis ping
```

Expected: `PONG`

- [ ] **Step 3: Bump RT lifetime in Vault config**

Edit `docker/vault-configs/authorization-server.json`:
- Old: `"application.refresh-token.life-time": "86400000"`
- New: `"application.refresh-token.life-time": "604800000"`

- [ ] **Step 4: Re-import Vault and restart auth-server**

```bash
make vault-import
make svc-restart svc=authorization-server
```

- [ ] **Step 5: Commit**

```bash
git add docker/vault-configs/authorization-server.json
git commit -m "chore(auth): bump refresh-token lifetime to 7d for tier 2"
```

---

## Task 1: TokenFamily DTO and RefreshTokenService interface

**Files:**
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/dto/internal/TokenFamily.java`
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenService.java`

- [ ] **Step 1: Write `TokenFamily.java`**

```java
package org.aibles.ecommerce.authorization_server.dto.internal;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class TokenFamily implements Serializable {
    private String userId;
    private String currentToken;
    private long createdAt;   // epoch ms — login time
    private long expiresAt;   // epoch ms — hard cap, set at login
}
```

- [ ] **Step 2: Write `RefreshTokenService.java`**

```java
package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.dto.internal.TokenFamily;

public interface RefreshTokenService {

    /** Generate an opaque RT, persist a new family for the user. */
    String issueForUser(String userId);

    /**
     * Look up the incoming raw token, verify it is the family's current token,
     * rotate to a new RT. Throws TokenInvalidException if unknown / revoked /
     * reuse-detected.
     */
    String rotate(String incomingToken);

    /** Revoke the family the given RT belongs to. No-op if already revoked. */
    void revokeByToken(String incomingToken);

    /** Revoke every family for the user (logout-all / password-change). */
    void revokeAllForUser(String userId);

    /** Resolve userId from an RT — used by /auth:logout to know who to log. */
    String userIdForToken(String incomingToken);
}
```

- [ ] **Step 3: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/dto/internal/TokenFamily.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenService.java
git commit -m "feat(auth): add RefreshTokenService interface and TokenFamily DTO"
```

---

## Task 2: RefreshTokenServiceImpl — issue + Redis writes

**Files:**
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java`
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java`

- [ ] **Step 1: Write the failing test for `issueForUser`**

```java
package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.dto.internal.TokenFamily;
import org.aibles.ecommerce.authorization_server.service.impl.RefreshTokenServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.*;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class RefreshTokenServiceImplTest {

    @SuppressWarnings("unchecked")
    private final RedisTemplate<String, Object> redis = mock(RedisTemplate.class);
    private final ValueOperations<String, Object> valueOps = mock(ValueOperations.class);
    private final HashOperations<String, Object, Object> hashOps = mock(HashOperations.class);
    private final SetOperations<String, Object> setOps = mock(SetOperations.class);

    private RefreshTokenServiceImpl service;

    @BeforeEach
    void setup() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(redis.opsForHash()).thenReturn(hashOps);
        when(redis.opsForSet()).thenReturn(setOps);
        service = new RefreshTokenServiceImpl(redis, 604_800_000L);
    }

    @Test
    void issueForUser_writes_three_keys_with_ttl() {
        String token = service.issueForUser("user-1");

        assertThat(token).isNotBlank().hasSizeGreaterThan(30);
        verify(valueOps).set(eq("rt:" + token), anyString(), eq(604_800_000L), eq(TimeUnit.MILLISECONDS));
        verify(hashOps).putAll(startsWith("family:"), anyMap());
        verify(redis).expire(startsWith("family:"), eq(604_800_000L), eq(TimeUnit.MILLISECONDS));
        verify(setOps).add(eq("user:user-1:families"), anyString());
        verify(redis).expire(eq("user:user-1:families"), eq(604_800_000L), eq(TimeUnit.MILLISECONDS));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd authorization-server && mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: compile error — `RefreshTokenServiceImpl` not found.

- [ ] **Step 3: Implement `RefreshTokenServiceImpl` (issue path only)**

```java
package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.dto.internal.TokenFamily;
import org.aibles.ecommerce.authorization_server.service.RefreshTokenService;
import org.springframework.data.redis.core.RedisTemplate;

import java.security.SecureRandom;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

@Slf4j
public class RefreshTokenServiceImpl implements RefreshTokenService {

    private static final String RT_PREFIX = "rt:";
    private static final String FAMILY_PREFIX = "family:";
    private static final String USER_FAMILIES_PREFIX = "user:";
    private static final String USER_FAMILIES_SUFFIX = ":families";

    private final RedisTemplate<String, Object> redis;
    private final long refreshTokenLifetimeMs;
    private final SecureRandom random = new SecureRandom();

    public RefreshTokenServiceImpl(RedisTemplate<String, Object> redis, long refreshTokenLifetimeMs) {
        this.redis = redis;
        this.refreshTokenLifetimeMs = refreshTokenLifetimeMs;
    }

    @Override
    public String issueForUser(String userId) {
        String rawToken = randomOpaqueToken();
        String familyId = UUID.randomUUID().toString();
        long now = System.currentTimeMillis();
        long expiresAt = now + refreshTokenLifetimeMs;

        // rt:{token} → familyId
        redis.opsForValue().set(RT_PREFIX + rawToken, familyId, refreshTokenLifetimeMs, TimeUnit.MILLISECONDS);

        // family:{familyId} hash
        Map<String, Object> familyHash = new HashMap<>();
        familyHash.put("userId", userId);
        familyHash.put("currentToken", rawToken);
        familyHash.put("createdAt", now);
        familyHash.put("expiresAt", expiresAt);
        String familyKey = FAMILY_PREFIX + familyId;
        redis.opsForHash().putAll(familyKey, familyHash);
        redis.expire(familyKey, refreshTokenLifetimeMs, TimeUnit.MILLISECONDS);

        // user:{userId}:families set
        String userFamiliesKey = userFamiliesKey(userId);
        redis.opsForSet().add(userFamiliesKey, familyId);
        redis.expire(userFamiliesKey, refreshTokenLifetimeMs, TimeUnit.MILLISECONDS);

        return rawToken;
    }

    @Override
    public String rotate(String incomingToken) { throw new UnsupportedOperationException("Task 4"); }

    @Override
    public void revokeByToken(String incomingToken) { throw new UnsupportedOperationException("Task 5"); }

    @Override
    public void revokeAllForUser(String userId) { throw new UnsupportedOperationException("Task 5"); }

    @Override
    public String userIdForToken(String incomingToken) { throw new UnsupportedOperationException("Task 5"); }

    private String randomOpaqueToken() {
        byte[] buf = new byte[32];
        random.nextBytes(buf);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(buf);
    }

    private String userFamiliesKey(String userId) {
        return USER_FAMILIES_PREFIX + userId + USER_FAMILIES_SUFFIX;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd authorization-server && mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java
git commit -m "feat(auth): RefreshTokenServiceImpl.issueForUser writes Redis state"
```

---

## Task 3: rotate() — happy path (no reuse handling yet)

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java`
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java`

- [ ] **Step 1: Write the failing test for happy-path rotation**

Append to `RefreshTokenServiceImplTest.java`:

```java
@Test
void rotate_happyPath_returns_new_token_and_updates_family() {
    String oldToken = "old-token";
    String familyId = "fam-1";
    when(valueOps.get("rt:" + oldToken)).thenReturn(familyId);
    Map<Object, Object> familyHash = new HashMap<>();
    familyHash.put("userId", "user-1");
    familyHash.put("currentToken", oldToken);
    familyHash.put("createdAt", 1L);
    familyHash.put("expiresAt", System.currentTimeMillis() + 60_000L);
    when(hashOps.entries("family:" + familyId)).thenReturn(familyHash);

    String newToken = service.rotate(oldToken);

    assertThat(newToken).isNotBlank().isNotEqualTo(oldToken);
    verify(valueOps).set(eq("rt:" + newToken), eq(familyId), anyLong(), eq(TimeUnit.MILLISECONDS));
    verify(hashOps).put("family:" + familyId, "currentToken", newToken);
}
```

- [ ] **Step 2: Run test — verify it fails**

```bash
mvn -Dtest=RefreshTokenServiceImplTest#rotate_happyPath_returns_new_token_and_updates_family test
```

Expected: FAIL — `UnsupportedOperationException`.

- [ ] **Step 3: Implement `rotate` happy path (reuse branch deferred to Task 4)**

Replace the placeholder `rotate` method body:

```java
@Override
public String rotate(String incomingToken) {
    String familyId = (String) redis.opsForValue().get(RT_PREFIX + incomingToken);
    if (familyId == null) {
        throw new TokenInvalidException();
    }
    String familyKey = FAMILY_PREFIX + familyId;
    Map<Object, Object> familyHash = redis.opsForHash().entries(familyKey);
    if (familyHash.isEmpty()) {
        throw new TokenInvalidException();
    }

    String currentToken = (String) familyHash.get("currentToken");
    if (!incomingToken.equals(currentToken)) {
        // TASK 4 — reuse detection branch goes here (handoff point).
        throw new TokenInvalidException();
    }

    long expiresAt = ((Number) familyHash.get("expiresAt")).longValue();
    long remainingMs = Math.max(1, expiresAt - System.currentTimeMillis());

    String newToken = randomOpaqueToken();
    redis.opsForValue().set(RT_PREFIX + newToken, familyId, remainingMs, TimeUnit.MILLISECONDS);
    redis.opsForHash().put(familyKey, "currentToken", newToken);
    return newToken;
}
```

Add import:
```java
import org.aibles.ecommerce.authorization_server.exception.TokenInvalidException;
```

- [ ] **Step 4: Run all tests — verify pass**

```bash
mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java
git commit -m "feat(auth): rotate refresh token (happy path) with hard-cap TTL"
```

---

## Task 4 — **HANDOFF POINT**: Reuse detection branch

The user writes the reuse-detection branch in `RefreshTokenServiceImpl.rotate`. This is the security primitive of the whole tier — worth seeing it under your own keys.

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java` (the `// TASK 4 — reuse detection branch` comment from Task 3)
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java`

- [ ] **Step 1: Read the spec section**

Read `docs/superpowers/specs/2026-05-08-refresh-token-tier-2-design.md` § "Refresh lifecycle" and § "Reuse-detection truth table". The behavior: if `incomingToken != family.currentToken`, that means the incoming RT was once valid but the family rotated past it — almost certainly a stolen replay. Revoke the entire family.

- [ ] **Step 2: Write the failing test (user writes)**

Add a test in `RefreshTokenServiceImplTest.java` that:
- Pre-populates `rt:old-token` → `fam-1`
- Pre-populates `family:fam-1` with `currentToken = "newer-token"` (i.e., already rotated past)
- Calls `service.rotate("old-token")`
- Asserts: throws `TokenInvalidException`, `family:fam-1` was deleted, `user:user-1:families` had `fam-1` removed.

- [ ] **Step 3: Run test — verify it fails**

```bash
mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: FAIL on the new test (current branch only throws, doesn't revoke).

- [ ] **Step 4: Implement the reuse branch (user writes)**

Replace the `// TASK 4 — reuse detection branch` line in `rotate()` with a block that:
- Logs a `log.warn` with userId + familyId
- Deletes `family:{familyId}`
- Removes `familyId` from `user:{userId}:families`
- Throws `TokenInvalidException`

About 8-10 lines. The `userId` is in the `familyHash` you already loaded. Don't add new public methods — keep it inline.

- [ ] **Step 5: Run all tests — verify pass**

```bash
mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java
git commit -m "feat(auth): detect refresh-token reuse and revoke family"
```

---

## Task 5: revokeByToken, revokeAllForUser, userIdForToken

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java`
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java`

- [ ] **Step 1: Write tests**

Add three tests in `RefreshTokenServiceImplTest.java`:

```java
@Test
void revokeByToken_deletes_family_and_index_entry() {
    when(valueOps.get("rt:t1")).thenReturn("fam-1");
    Map<Object, Object> familyHash = new HashMap<>();
    familyHash.put("userId", "user-1");
    familyHash.put("currentToken", "t1");
    familyHash.put("expiresAt", System.currentTimeMillis() + 60_000L);
    when(hashOps.entries("family:fam-1")).thenReturn(familyHash);

    service.revokeByToken("t1");

    verify(redis).delete("family:fam-1");
    verify(setOps).remove("user:user-1:families", "fam-1");
}

@Test
void revokeByToken_silent_on_unknown_token() {
    when(valueOps.get("rt:unknown")).thenReturn(null);
    service.revokeByToken("unknown");
    verify(redis, never()).delete(anyString());
}

@Test
void revokeAllForUser_wipes_all_families_and_index() {
    when(setOps.members("user:user-1:families")).thenReturn(Set.of("fam-a", "fam-b"));

    service.revokeAllForUser("user-1");

    verify(redis).delete("family:fam-a");
    verify(redis).delete("family:fam-b");
    verify(redis).delete("user:user-1:families");
}
```

Add `import java.util.Set;` if not present.

- [ ] **Step 2: Run — verify fails**

```bash
mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: FAIL with `UnsupportedOperationException`.

- [ ] **Step 3: Implement the three methods**

```java
@Override
public void revokeByToken(String incomingToken) {
    String familyId = (String) redis.opsForValue().get(RT_PREFIX + incomingToken);
    if (familyId == null) return;
    String familyKey = FAMILY_PREFIX + familyId;
    Map<Object, Object> familyHash = redis.opsForHash().entries(familyKey);
    String userId = (String) familyHash.get("userId");
    redis.delete(familyKey);
    if (userId != null) {
        redis.opsForSet().remove(userFamiliesKey(userId), familyId);
    }
}

@Override
public void revokeAllForUser(String userId) {
    String userFamiliesKey = userFamiliesKey(userId);
    Set<Object> familyIds = redis.opsForSet().members(userFamiliesKey);
    if (familyIds != null) {
        for (Object familyId : familyIds) {
            redis.delete(FAMILY_PREFIX + familyId);
        }
    }
    redis.delete(userFamiliesKey);
}

@Override
public String userIdForToken(String incomingToken) {
    String familyId = (String) redis.opsForValue().get(RT_PREFIX + incomingToken);
    if (familyId == null) return null;
    Object userId = redis.opsForHash().get(FAMILY_PREFIX + familyId, "userId");
    return userId == null ? null : userId.toString();
}
```

Add `import java.util.Set;` if needed.

- [ ] **Step 4: Run — verify pass**

```bash
mvn -Dtest=RefreshTokenServiceImplTest test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/RefreshTokenServiceImpl.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/RefreshTokenServiceImplTest.java
git commit -m "feat(auth): refresh-token revocation and userId resolution"
```

---

## Task 6: Bean wiring for RefreshTokenServiceImpl

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java`

- [ ] **Step 1: Add bean method**

In `AuthorizationServerConfiguration.java`, add (next to the other `@Bean` methods):

```java
@Bean
public RefreshTokenService refreshTokenService(RedisTemplate<String, Object> redisTemplate) {
    return new RefreshTokenServiceImpl(redisTemplate, refreshTokenLifetime);
}
```

Imports:
```java
import org.aibles.ecommerce.authorization_server.service.RefreshTokenService;
import org.aibles.ecommerce.authorization_server.service.impl.RefreshTokenServiceImpl;
import org.springframework.data.redis.core.RedisTemplate;
```

Note: `refreshTokenLifetime` is declared as `Integer` at the top — convert: `Long.valueOf(refreshTokenLifetime).longValue()` if needed, or change the bean signature to accept `long` and cast at call site.

- [ ] **Step 2: Run auth-server context-loads test**

```bash
cd authorization-server && mvn test -Dtest='*ApplicationTests' -q
```

Expected: PASS (context loads).

- [ ] **Step 3: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java
git commit -m "feat(auth): wire RefreshTokenService bean"
```

---

## Task 7: Integrate into login flow

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java`

- [ ] **Step 1: Add `RefreshTokenService` constructor parameter**

Edit `AuthFacadeServiceImpl.java`:
- Add `private final RefreshTokenService refreshTokenService;` field.
- Add it as the last parameter of the constructor and assign it.
- Update the `@Bean` definition in `AuthorizationServerConfiguration.java` to pass the new bean.

- [ ] **Step 2: Replace login's RT generation**

In `AuthFacadeServiceImpl.login()` (around line 125-135 per spec context):
- **Remove**: `refreshToken = jwtService.generateRefreshToken(...);`
- **Add**: `refreshToken = refreshTokenService.issueForUser(accountUserPrj.getUserId());`

Keep the access-token generation untouched.

- [ ] **Step 3: Smoke-test login**

```bash
make svc-restart svc=authorization-server
curl -s -X POST http://localhost:8080/authorization-server/v1/auth:login \
  -H 'Content-Type: application/json' \
  -d '{"email":"<test-email>","password":"<test-password>"}' | jq
```

Expected: `data.refreshToken` is an opaque ~43-char URL-safe Base64 string, **not** a JWT (no dots).

- [ ] **Step 4: Verify Redis state**

```bash
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis --scan --pattern 'rt:*' | head
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis --scan --pattern 'family:*' | head
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis --scan --pattern 'user:*:families' | head
```

Expected: at least one of each.

- [ ] **Step 5: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java
git commit -m "feat(auth): login issues opaque refresh token via RefreshTokenService"
```

---

## Task 8: Integrate into refresh flow

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java`

- [ ] **Step 1: Replace `refreshToken` body**

Replace the body of `refreshToken(String refreshToken)` (currently around line 154-188):

```java
@Override
public RefreshTokenResponse refreshToken(String refreshToken) {
    if (Objects.isNull(refreshToken) || !refreshToken.startsWith("Bearer ")) {
        throw new TokenInvalidException();
    }
    String rawToken = refreshToken.substring(7);

    String userId = refreshTokenService.userIdForToken(rawToken);
    if (userId == null) {
        throw new TokenInvalidException();
    }

    String email = userService.getEmailById(userId);  // existing helper, or call accountService
    List<String> roles = accountService.getRolesByUserId(userId);

    String newAccessToken;
    try {
        newAccessToken = jwtService.generateAccessToken(userId, email, roles);
    } catch (JOSEException ex) {
        log.error("(refreshToken) generate access token failed", ex);
        throw new InternalErrorException();
    }

    String newRefreshToken = refreshTokenService.rotate(rawToken);

    return RefreshTokenResponse.builder()
            .accessToken(newAccessToken)
            .refreshToken(newRefreshToken)
            .build();
}
```

If `userService.getEmailById` doesn't exist, look up via `accountService` or add a thin helper. Confirm by reading `UserService.java` first.

- [ ] **Step 2: Smoke-test refresh**

After login (Task 7 step 3), grab `refreshToken` from the response:

```bash
RT="<paste-rt>"
curl -s -X POST http://localhost:8080/authorization-server/v1/auth:refresh-token \
  -H "Authorization: Bearer $RT" | jq
```

Expected: `data.accessToken` (new JWT) + `data.refreshToken` (new opaque token, different from RT).

- [ ] **Step 3: Smoke-test reuse detection**

Re-use the **old** `RT` (already rotated past):

```bash
curl -s -X POST http://localhost:8080/authorization-server/v1/auth:refresh-token \
  -H "Authorization: Bearer $RT" | jq
```

Expected: 401 `TOKEN_INVALID`. Verify in auth-server logs: `refresh-token reuse detected`. Verify Redis: `family:*` for that family is gone.

- [ ] **Step 4: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java
git commit -m "feat(auth): refreshToken delegates to RefreshTokenService (Redis-backed)"
```

---

## Task 9: Logout endpoints

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/AuthFacadeService.java`
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java`
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/controller/AuthUserController.java`
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java`

- [ ] **Step 1: Add interface methods**

In `AuthFacadeService.java`:

```java
void logout(String refreshTokenHeader);
void logoutAll(String userId);
```

- [ ] **Step 2: Implement them**

In `AuthFacadeServiceImpl.java`:

```java
@Override
public void logout(String refreshTokenHeader) {
    if (refreshTokenHeader == null || !refreshTokenHeader.startsWith("Bearer ")) {
        throw new TokenInvalidException();
    }
    refreshTokenService.revokeByToken(refreshTokenHeader.substring(7));
}

@Override
public void logoutAll(String userId) {
    if (userId == null || userId.isBlank()) {
        throw new TokenInvalidException();
    }
    refreshTokenService.revokeAllForUser(userId);
}
```

- [ ] **Step 3: Add controller methods**

In `AuthUserController.java`:

```java
@PostMapping("/auth:logout")
public BaseResponse logout(@RequestHeader(HttpHeaders.AUTHORIZATION) String refreshToken) {
    authFacadeService.logout(refreshToken);
    return BaseResponse.ok(null);
}

@PostMapping("/auth:logout-all")
public BaseResponse logoutAll(@RequestHeader("X-User-Id") String userId) {
    authFacadeService.logoutAll(userId);
    return BaseResponse.ok(null);
}
```

- [ ] **Step 4: Permit `/auth:logout` (RT-authenticated, not AT)**

In `SecurityConfiguration.java`, add `/v1/auth:logout` to the same permit list as `/v1/auth:refresh-token`. `/v1/auth:logout-all` stays AT-protected (default rules apply via gateway routing).

- [ ] **Step 5: Smoke-test logout**

```bash
# After login, capture both tokens.
curl -s -X POST http://localhost:8080/authorization-server/v1/auth:logout \
  -H "Authorization: Bearer $RT" -i
# Expected: 200 OK
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis --scan --pattern 'family:*' | wc -l
# Expected: one fewer than before
```

Then try refreshing with the now-orphaned RT:

```bash
curl -s -X POST http://localhost:8080/authorization-server/v1/auth:refresh-token \
  -H "Authorization: Bearer $RT" -i
# Expected: 401 (family revoked)
```

- [ ] **Step 6: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/AuthFacadeService.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/controller/AuthUserController.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/SecurityConfiguration.java
git commit -m "feat(auth): add /auth:logout and /auth:logout-all"
```

---

## Task 10: Wire password change → revokeAllForUser

**Files:**
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/UserServiceImpl.java` (or wherever `:update-password` is implemented — confirm by reading `UserController.java`)
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java` (for the `/auth:reset-password` path)

- [ ] **Step 1: Inject `RefreshTokenService` into the password-change service**

Check what service handles `PATCH /users/self:update-password` (UserController:39). Add `RefreshTokenService` as a constructor param; update the matching `@Bean` method in the configuration class.

- [ ] **Step 2: Call `revokeAllForUser` after successful update**

In the change-password method, **after** the password is persisted:
```java
refreshTokenService.revokeAllForUser(userId);
```

In `AuthFacadeServiceImpl.resetPassword(...)`, after `accountService.resetPasswordByEmail(...)`:
```java
String userId = accountService.getUserIdByEmail(request.getEmail());
refreshTokenService.revokeAllForUser(userId);
```

(Confirm `getUserIdByEmail` exists; if not, use the existing user lookup pattern.)

- [ ] **Step 3: Smoke-test**

Login → change password → try refresh with old RT → expect 401.

- [ ] **Step 4: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/UserServiceImpl.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/AuthFacadeServiceImpl.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java
git commit -m "feat(auth): wipe refresh-token families on password change/reset"
```

---

## Task 11 — **HANDOFF POINT**: `doRefresh()` body in `frontend/src/api/refresh.ts`

The user writes the body of `doRefresh()` — this is the contract surface between FE and BE.

**Files:**
- Create: `frontend/src/api/refresh.ts`
- Test: `frontend/tests/unit/api/refresh.spec.ts`

- [ ] **Step 1: Write the failing test (assistant scaffolds)**

Create `frontend/tests/unit/api/refresh.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { refreshAccessToken } from '@/api/refresh';

describe('refreshAccessToken', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.stubGlobal('fetch', vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns null and clears auth when no refresh token present', async () => {
    const result = await refreshAccessToken();
    expect(result).toBeNull();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it('coalesces concurrent calls into a single network request', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'old-at', refreshToken: 'old-rt' });

    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          status: 200,
          code: 'OK',
          message: 'ok',
          data: { accessToken: 'new-at', refreshToken: 'new-rt' },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const [r1, r2, r3] = await Promise.all([
      refreshAccessToken(),
      refreshAccessToken(),
      refreshAccessToken(),
    ]);

    expect(r1).toBe('new-at');
    expect(r2).toBe('new-at');
    expect(r3).toBe('new-at');
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(auth.accessToken).toBe('new-at');
    expect(auth.refreshToken).toBe('new-rt');
  });

  it('clears auth and returns null on refresh failure', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'old-at', refreshToken: 'old-rt' });

    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(
      new Response('{}', { status: 401 }),
    );

    const result = await refreshAccessToken();
    expect(result).toBeNull();
    expect(auth.accessToken).toBeNull();
    expect(auth.refreshToken).toBeNull();
  });
});
```

- [ ] **Step 2: Create `refresh.ts` skeleton — the user fills `doRefresh`**

Create `frontend/src/api/refresh.ts`:

```ts
import { useAuthStore } from '@/stores/auth';

const REFRESH_URL = `${import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868'}/authorization-server/v1/auth:refresh-token`;

let inflight: Promise<string | null> | null = null;

export async function refreshAccessToken(): Promise<string | null> {
  if (inflight) return inflight;
  inflight = doRefresh().finally(() => {
    inflight = null;
  });
  return inflight;
}

/**
 * TASK 11 — HANDOFF: user writes this body.
 *
 * Requirements:
 *  - Read current refreshToken from useAuthStore(). If missing → return null.
 *  - POST to REFRESH_URL with header `Authorization: Bearer <refreshToken>`.
 *    No body. Server reads RT from header.
 *  - Backend returns BaseResponse<{ accessToken, refreshToken }> on success
 *    (snake_case wire keys: access_token, refresh_token — see root CLAUDE.md
 *     "Cross-service JSON" section).
 *  - On 2xx: call auth.login({ accessToken, refreshToken }) and return the new
 *    accessToken.
 *  - On any failure (non-2xx, network error, parse error): call auth.clear()
 *    and return null. Don't redirect from here — caller decides UX.
 *  - DO NOT call refreshAccessToken() recursively if this 401s.
 *
 * About 10–15 lines. Keep it simple. The tests in refresh.spec.ts pin the
 * contract — make them pass.
 */
async function doRefresh(): Promise<string | null> {
  // TODO(handoff): you write this.
  throw new Error('doRefresh() not implemented — see TASK 11 HANDOFF in plan');
}
```

- [ ] **Step 3: Run tests — verify they fail with the not-implemented error**

```bash
cd frontend && pnpm test refresh.spec
```

Expected: FAIL — `doRefresh() not implemented`.

- [ ] **Step 4: User implements `doRefresh()` body**

Replace the `TODO(handoff)` line. Make the three tests pass.

- [ ] **Step 5: Run tests — verify pass**

```bash
pnpm test refresh.spec
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/api/refresh.ts frontend/tests/unit/api/refresh.spec.ts
git commit -m "feat(fe): single-flight refreshAccessToken helper"
```

---

## Task 12: Replace 401 handling in `client.ts`

**Files:**
- Modify: `frontend/src/api/client.ts`
- Test: `frontend/tests/unit/api/client.spec.ts`

- [ ] **Step 1: Read existing client.spec.ts and adapt the 401 tests**

Existing tests assert "401 → redirect to /login". New behavior: "401 → refresh → replay; only if refresh fails → redirect". Update the test fixtures to mock both the failing-original-request and the refresh response.

(Concrete updates depend on the test's existing structure — read the file first; then rewrite the 401 test to first return 401, then return 200 on the replay, with a fetch-mock that asserts `/auth:refresh-token` was called once.)

- [ ] **Step 2: Refactor 401 handling**

In `client.ts`, both the `errorMiddleware.onResponse` and `apiFetchUnsafe`'s 401 branch should become:

```ts
// Skip refresh if the failing request IS the refresh call (avoid recursion).
const url = response.url;
const isRefreshCall = url.endsWith('/authorization-server/v1/auth:refresh-token');

if (response.status === 401 && !isRefreshCall) {
  const newAT = await refreshAccessToken();
  if (newAT) {
    // Caller-specific replay logic: return Response from new fetch.
    return retryWithNewToken();
  }
  useAuthStore().clear();
  const next = router.currentRoute.value.fullPath;
  router.replace({ path: '/login', query: { next } });
}
```

For `openapi-fetch` middleware: returning a substituted `Response` from `onResponse` is allowed; build the retry by re-issuing `fetch(url, { ...originalInit, headers: { ...headers, Authorization: 'Bearer ' + newAT } })`. The middleware has access to the original `Request` via the hook's argument — verify against openapi-fetch types.

For `apiFetchUnsafe`: simpler — re-call `fetch(${BASE_URL}${path}, { ...init, headers: withNewAT })`.

Add: `import { refreshAccessToken } from './refresh';`

- [ ] **Step 3: Run client tests**

```bash
cd frontend && pnpm test client.spec
```

Expected: PASS (after fixture updates from Step 1).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/client.ts frontend/tests/unit/api/client.spec.ts
git commit -m "feat(fe): 401 triggers refresh+retry via single-flight helper"
```

---

## Task 13 — **HANDOFF POINT**: Cross-tab `storage` listener

User extends the existing `storage` event listener in `auth.ts` to sync new tokens, not just clears.

**Files:**
- Modify: `frontend/src/stores/auth.ts`

- [ ] **Step 1: Read the current listener**

Currently (`auth.ts:46-52`) the listener only handles `e.newValue === null` (cross-tab clear). When tab A refreshes, tab B is unaware until it 401s and refreshes itself — wasteful and racy.

- [ ] **Step 2: User extends the listener**

Open `auth.ts` and modify the `'storage'` event handler so that when `e.key === AUTH_STORAGE_KEY` and `e.newValue` is a JSON object with new tokens, the local `accessToken.value` and `refreshToken.value` refs update to match. Keep the existing `null` → clear branch.

Considerations:
- Wrap `JSON.parse` in try/catch — tab A could write garbage.
- Don't re-emit the `storage` event (Pinia ref assignment doesn't, so this is naturally fine).
- Decide: if tab A clears auth (logout) while tab B has a request in flight, what should tab B do? Default answer: just sync the clear; in-flight 401 will redirect via the existing flow.

About 6–8 lines of code.

- [ ] **Step 3: Manual verify**

Open the SPA in two tabs, login. In tab A, force a refresh (DevTools: tweak `auth` localStorage to have a clearly-near-expired AT, or just wait 15min). After tab A refreshes, switch to tab B and check `useAuthStore().accessToken` — it should already be the new value.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/stores/auth.ts
git commit -m "feat(fe): cross-tab sync of refreshed tokens via storage event"
```

---

## Task 14: Logout button in AppNav

**Files:**
- Modify: `frontend/src/api/queries/auth.ts`
- Modify: `frontend/src/components/layout/AppNav.vue`

- [ ] **Step 1: Add `useLogoutMutation` hook**

In `frontend/src/api/queries/auth.ts`, add:

```ts
export function useLogoutMutation() {
  const auth = useAuthStore();
  const router = useRouter();
  return useMutation({
    mutationFn: async () => {
      const rt = auth.refreshToken;
      if (!rt) return;
      try {
        await fetch(`${import.meta.env.VITE_API_BASE_URL}/authorization-server/v1/auth:logout`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${rt}` },
        });
      } catch {
        /* network failure — local clear still proceeds */
      }
    },
    onSettled: () => {
      auth.clear();
      router.replace('/login');
    },
  });
}
```

Add `useRouter` import.

- [ ] **Step 2: Wire the button in `AppNav.vue`**

Replace whatever currently runs on the "Logout" click with:

```ts
const logoutMutation = useLogoutMutation();
const onLogout = () => logoutMutation.mutate();
```

`@click="onLogout"` on the button.

- [ ] **Step 3: Manual verify**

Login → click Logout in the nav → expect redirect to `/login`. Verify Redis: the family for that session is gone:

```bash
docker exec -i ecommerce-redis redis-cli -a ecommerce_redis --scan --pattern 'family:*' | wc -l
```

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/queries/auth.ts frontend/src/components/layout/AppNav.vue
git commit -m "feat(fe): logout button calls /auth:logout and clears local state"
```

---

## Task 15 — **HANDOFF POINT**: "Log out all devices" UX

User decides UX in account settings — modal confirm? toast on success? Where exactly does the button live?

**Files:**
- Modify: account-page Vue file (probably `frontend/src/pages/account/AccountPage.vue` or similar — locate by reading `frontend/src/router/`)
- Modify: `frontend/src/api/queries/auth.ts` — add `useLogoutAllMutation`

- [ ] **Step 1: Add `useLogoutAllMutation`**

```ts
export function useLogoutAllMutation() {
  const auth = useAuthStore();
  const router = useRouter();
  return useMutation({
    mutationFn: async () => {
      // AT-authenticated; openapi-fetch already attaches the Bearer header.
      const at = auth.accessToken;
      if (!at) return;
      const userId = decodeUserId(at); // helper: parse `sub` claim from JWT
      await fetch(`${import.meta.env.VITE_API_BASE_URL}/authorization-server/v1/auth:logout-all`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${at}`,
          'X-User-Id': userId,
        },
      });
    },
    onSettled: () => {
      auth.clear();
      router.replace('/login');
    },
  });
}
```

Note: gateway already extracts `X-User-Id` from AT and forwards it; no need to parse in browser. Just send the AT and let the gateway do the work. **Update the controller signature** if the gateway-injected `X-User-Id` is sufficient: drop the manual injection and skip `decodeUserId` entirely.

- [ ] **Step 2: User adds the UI** (handoff — UX choice)

In the account settings page, add a "Log out all devices" button. Decisions to make:
- Where on the page (under security section? bottom danger zone?)
- Confirm dialog before invoking? (Recommended — destructive on multiple sessions.)
- Success affordance? (Toast vs immediate redirect to login.)
- Error handling? (Probably same as logout — best-effort.)

About 20–40 lines of Vue depending on dialog choice. Use the `reka-ui` components already in the codebase.

- [ ] **Step 3: Manual verify**

Login on two browsers (or one normal + one private). Click "Log out all devices" in browser A. Browser B's next API call should 401 → refresh → 401 → redirect to login.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/queries/auth.ts frontend/src/pages/account/<file>.vue
git commit -m "feat(fe): log out all devices from account settings"
```

---

## Task 16: Final verification + push

- [ ] **Step 1: Run full backend test suite**

```bash
cd authorization-server && mvn test
```

- [ ] **Step 2: Run full frontend test suite + typecheck**

```bash
cd frontend && pnpm test && pnpm typecheck
```

- [ ] **Step 3: End-to-end manual run-through**

1. `make svc-restart svc=authorization-server` and `pnpm dev` in frontend.
2. Login → leave SPA idle for >15min → make a request → expect: AT refreshed silently, no redirect.
3. Logout → expect family gone in Redis.
4. Login on two browsers → "Log out all devices" → both kicked out.
5. Replay an old (rotated) RT manually with `curl` → expect 401 + family revoked.

- [ ] **Step 4: Push**

```bash
git push -u origin feat/refresh-token-tier-2
```

- [ ] **Step 5: Open PR**

```bash
gh pr create --title "feat(auth): refresh token tier 2 — rotation, reuse detection, server-side revocation" \
  --body "Implements design at docs/superpowers/specs/2026-05-08-refresh-token-tier-2-design.md."
```

---

## Self-review notes

- **Spec coverage:** every section of the spec has at least one task — Redis schema (Tasks 2–5), refresh lifecycle (Tasks 7–8), logout endpoints (Task 9), password-change wipe (Task 10), single-flight FE (Task 11), 401 handling (Task 12), cross-tab sync (Task 13), logout UX (Tasks 14–15), migration is implicit (covered by Task 7's "old JWT RTs no longer valid" behavior).
- **Type consistency:** `RefreshTokenService` methods (`issueForUser`, `rotate`, `revokeByToken`, `revokeAllForUser`, `userIdForToken`) used identically across all callers (`AuthFacadeServiceImpl`, password-change service).
- **Handoff points:** four explicit handoff tasks (4, 11, 13, 15), each with its own context block.
- **Open assumption to verify before Task 10:** `accountService.getUserIdByEmail` may not exist — confirm by reading the file when the task starts, and add a thin helper if missing.
