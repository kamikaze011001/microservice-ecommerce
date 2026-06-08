package org.aibles.order_service.scheduler;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;

import java.util.Map;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ExpiredOrderCleanupJobTest {

    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private RedissonClient redissonClient;

    private ExpiredOrderCleanupJob job;

    @BeforeEach
    void setUp() {
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        redissonClient = mock(RedissonClient.class);

        job = new ExpiredOrderCleanupJob(redisRepository, pendingOrderCacheRepository, redissonClient);

        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void cleanupExpiredOrders_incrsAvailableKey_notDecrsQueueKey() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-expired", Map.of("prod-1", 4L)));

        job.cleanupExpiredOrders();

        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 4L);
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void cleanupExpiredOrders_noExpiredOrders_doesNothing() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong())).thenReturn(Map.of());

        job.cleanupExpiredOrders();

        verifyNoInteractions(redisRepository);
    }

    @Test
    void cleanupExpiredOrders_removesFromPendingOrdersAfterRelease() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-expired", Map.of("prod-1", 2L)));

        job.cleanupExpiredOrders();

        verify(pendingOrderCacheRepository).removeFromPendingOrders("order-expired");
    }
}
