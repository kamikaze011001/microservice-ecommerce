package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.exception.TokenInvalidException;
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
