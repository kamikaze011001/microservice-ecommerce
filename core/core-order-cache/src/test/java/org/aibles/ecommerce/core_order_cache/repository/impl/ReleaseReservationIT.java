package org.aibles.ecommerce.core_order_cache.repository.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.core_order_cache.constant.OrderCacheConstant;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Runs the release Lua script against a real Redis. The point is the race: the
 * cleanup job on every pod and the cancel/fail consumer can all try to give back
 * the same reservation, and the units must come back exactly once.
 *
 * Integration test (`*IT`): not part of the default surefire run; skipped without
 * Docker. Run with:
 *   mvn -o test -Dtest=ReleaseReservationIT -DargLine="-Dapi.version=1.44"
 * (Docker Engine 29 rejects Testcontainers 1.20's default API 1.32 as too old.)
 */
@Testcontainers(disabledWithoutDocker = true)
class ReleaseReservationIT {

    static final String PREFIX = "productAvailable:";

    @Container
    static final GenericContainer<?> REDIS = new GenericContainer<>("redis:7.4-alpine").withExposedPorts(6379);

    static LettuceConnectionFactory factory;
    static RedisTemplate<String, Object> template;
    PendingOrderCacheRepositoryImpl repo;

    @BeforeAll
    static void connect() {
        factory = new LettuceConnectionFactory(new RedisStandaloneConfiguration(REDIS.getHost(), REDIS.getMappedPort(6379)));
        factory.afterPropertiesSet();
        // Same serializers as core-redis RedisConfiguration — the script must match its bytes.
        template = new RedisTemplate<>();
        template.setConnectionFactory(factory);
        template.setKeySerializer(new StringRedisSerializer());
        template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.afterPropertiesSet();
    }

    @AfterAll
    static void close() {
        factory.destroy();
    }

    @BeforeEach
    void reset() {
        template.execute(c -> { c.serverCommands().flushAll(); return null; }, true);
        repo = new PendingOrderCacheRepositoryImpl(template, new ObjectMapper());
    }

    @Test
    void release_returnsUnitsToAvailable_andRemovesTheEntry() {
        template.opsForValue().increment(PREFIX + "p1", 10);
        repo.addToPendingOrders("o1", 50.0, Map.of("p1", 3L, "p2", 2L), System.currentTimeMillis() + 60_000);

        Optional<Map<String, Long>> released = repo.releaseReservation("o1", PREFIX);

        assertThat(released).contains(Map.of("p1", 3L, "p2", 2L));
        assertThat(available("p1")).isEqualTo(13);
        assertThat(available("p2")).isEqualTo(2);
        assertThat(template.opsForZSet().size(OrderCacheConstant.PENDING_ORDERS_ZSET)).isZero();
        assertThat(template.opsForHash().get(OrderCacheConstant.PENDING_ORDERS_INDEX, "o1")).isNull();
        assertThat(repo.releaseReservation("o1", PREFIX)).as("second release").isEmpty();
        assertThat(available("p1")).as("not released twice").isEqualTo(13);
    }

    @Test
    void concurrentReleases_exactlyOneWins() throws Exception {
        repo.addToPendingOrders("o2", 10.0, Map.of("p1", 4L), System.currentTimeMillis() + 60_000);
        int racers = 16;
        ExecutorService pool = Executors.newFixedThreadPool(racers);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<Optional<Map<String, Long>>>> results = new ArrayList<>();
        for (int i = 0; i < racers; i++) {
            results.add(pool.submit(() -> { start.await(); return repo.releaseReservation("o2", PREFIX); }));
        }
        start.countDown();
        int winners = 0;
        for (Future<Optional<Map<String, Long>>> f : results) {
            if (f.get().isPresent()) winners++;
        }
        pool.shutdown();

        assertThat(winners).isEqualTo(1);
        assertThat(available("p1")).isEqualTo(4);
    }

    @Test
    void releaseOfUnknownOrder_isEmpty_andTouchesNothing() {
        assertThat(repo.releaseReservation("never-pending", PREFIX)).isEmpty();
        assertThat(template.hasKey(PREFIX + "p1")).isFalse();
    }

    private long available(String productId) {
        Object v = template.opsForValue().get(PREFIX + productId);
        return v == null ? 0 : ((Number) v).longValue();
    }
}
