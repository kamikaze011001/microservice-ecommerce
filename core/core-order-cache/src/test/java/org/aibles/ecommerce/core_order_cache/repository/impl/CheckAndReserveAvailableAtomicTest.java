package org.aibles.ecommerce.core_order_cache.repository.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.RedisScriptingCommands;
import org.springframework.data.redis.connection.ReturnType;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class CheckAndReserveAvailableAtomicTest {

    private RedisTemplate<String, Object> redisTemplate;
    private PendingOrderCacheRepositoryImpl repo;

    @BeforeEach
    void setUp() {
        redisTemplate = mock(RedisTemplate.class);
        ObjectMapper objectMapper = new ObjectMapper();
        repo = new PendingOrderCacheRepositoryImpl(redisTemplate, objectMapper);
    }

    @Test
    void emptyProductQuantities_returnsTrue_withoutCallingRedis() {
        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of());

        assertThat(result).isTrue();
        verify(redisTemplate, never()).execute(any(RedisCallback.class));
    }

    @Test
    void luaReturns1_returnsTrue() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(1L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        Map<String, Long> quantities = new LinkedHashMap<>();
        quantities.put("prod-1", 3L);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        assertThat(result).isTrue();
    }

    @Test
    void luaReturns0_returnsFalse() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(0L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        Map<String, Long> quantities = Map.of("prod-1", 5L);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        assertThat(result).isFalse();
    }

    @Test
    void luaReturnsNull_returnsFalse() {
        when(redisTemplate.execute(any(RedisCallback.class))).thenReturn(null);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of("prod-1", 1L));

        assertThat(result).isFalse();
    }

    @Test
    void redisThrowsException_returnsFalse() {
        when(redisTemplate.execute(any(RedisCallback.class)))
                .thenThrow(new RuntimeException("Redis connection refused"));

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of("prod-1", 1L));

        assertThat(result).isFalse();
    }

    @Test
    void luaScript_containsGuardAgainstNegative() {
        String scriptField = captureScript();

        assertThat(scriptField).contains("available < quantities[i]");
        assertThat(scriptField).contains("DECRBY");
        assertThat(scriptField).doesNotContain("INCRBY");
    }

    @Test
    void multipleProducts_argsEncodedInCorrectOrder() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(1L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        Map<String, Long> quantities = new LinkedHashMap<>();
        quantities.put("prod-A", 2L);
        quantities.put("prod-B", 5L);

        repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        org.mockito.ArgumentCaptor<byte[][]> argsCaptor =
                org.mockito.ArgumentCaptor.forClass(byte[][].class);
        verify(scriptingCommands).eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), argsCaptor.capture());

        byte[][] argBytes = argsCaptor.getValue();
        assertThat(new String(argBytes[0])).isEqualTo("productAvailable:");
        assertThat(new String(argBytes[1])).isEqualTo("2");
        assertThat(new String(argBytes[2])).isEqualTo("prod-A");
        assertThat(new String(argBytes[3])).isEqualTo("prod-B");
        assertThat(new String(argBytes[4])).isEqualTo("2");
        assertThat(new String(argBytes[5])).isEqualTo("5");
    }

    private String captureScript() {
        try {
            java.lang.reflect.Field f = PendingOrderCacheRepositoryImpl.class
                    .getDeclaredField("CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT");
            f.setAccessible(true);
            return (String) f.get(null);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
