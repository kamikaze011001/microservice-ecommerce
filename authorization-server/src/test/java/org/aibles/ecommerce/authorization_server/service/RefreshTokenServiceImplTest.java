package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.service.impl.RefreshTokenServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.SetOperations;
import org.springframework.data.redis.core.ValueOperations;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.startsWith;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class RefreshTokenServiceImplTest {

    @SuppressWarnings("unchecked")
    private final RedisTemplate<String, Object> redis = mock(RedisTemplate.class);
    @SuppressWarnings("unchecked")
    private final ValueOperations<String, Object> valueOps = mock(ValueOperations.class);
    @SuppressWarnings("unchecked")
    private final HashOperations<String, Object, Object> hashOps = mock(HashOperations.class);
    @SuppressWarnings("unchecked")
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
}
