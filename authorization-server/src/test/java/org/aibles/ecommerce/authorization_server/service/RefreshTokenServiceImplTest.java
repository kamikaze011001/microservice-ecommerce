package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.exception.TokenInvalidException;
import org.aibles.ecommerce.authorization_server.service.impl.RefreshTokenServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.SetOperations;
import org.springframework.data.redis.core.ValueOperations;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.startsWith;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
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

    @Test
    void rotate_reuse_detection_branch() {
        String oldToken = "old-token";
        String familyId = "fam-1";
        when(valueOps.get("rt:" + oldToken)).thenReturn(familyId);
        Map<Object, Object> familyHash = new HashMap<>();
        familyHash.put("userId", "user-1");
        familyHash.put("currentToken", "newer-token");
        familyHash.put("createdAt", 1L);
        familyHash.put("expiresAt", System.currentTimeMillis() + 60_000L);
        when(hashOps.entries("family:" + familyId)).thenReturn(familyHash);

        assertThatThrownBy(() -> service.rotate(oldToken))
                .isInstanceOf(TokenInvalidException.class);
        verify(redis).delete("family:" + familyId);
        verify(setOps).remove("user:user-1:families", familyId);
    }

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

    @Test
    void userIdForToken_returns_userId_from_family() {
        when(valueOps.get("rt:t1")).thenReturn("fam-1");
        when(hashOps.get("family:fam-1", "userId")).thenReturn("user-1");

        assertThat(service.userIdForToken("t1")).isEqualTo("user-1");
    }

    @Test
    void userIdForToken_returns_null_for_unknown_token() {
        when(valueOps.get("rt:unknown")).thenReturn(null);
        assertThat(service.userIdForToken("unknown")).isNull();
    }
}
