package org.aibles.order_service.scheduler;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.*;

class ExpiredOrderCleanupJobTest {

    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private ExpiredOrderCleanupJob job;

    @BeforeEach
    void setUp() {
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        job = new ExpiredOrderCleanupJob(pendingOrderCacheRepository);
    }

    @Test
    void cleanupExpiredOrders_releasesEachThroughTheAtomicClaim() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-a", Map.of("prod-1", 4L), "order-b", Map.of("prod-2", 1L)));
        when(pendingOrderCacheRepository.releaseReservation(anyString(), anyString()))
                .thenReturn(Optional.of(Map.of()));

        job.cleanupExpiredOrders();

        verify(pendingOrderCacheRepository).releaseReservation("order-a", RedisConstant.AVAILABLE_PRODUCT_KEY);
        verify(pendingOrderCacheRepository).releaseReservation("order-b", RedisConstant.AVAILABLE_PRODUCT_KEY);
        // never the old read → incr → remove sequence, which two pods could both run
        verify(pendingOrderCacheRepository, never()).removeFromPendingOrders(anyString());
    }

    @Test
    void cleanupExpiredOrders_oneFailure_doesNotStopTheRest() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-a", Map.of("prod-1", 4L), "order-b", Map.of("prod-2", 1L)));
        when(pendingOrderCacheRepository.releaseReservation(eq("order-a"), anyString()))
                .thenThrow(new RuntimeException("redis down"));
        when(pendingOrderCacheRepository.releaseReservation(eq("order-b"), anyString()))
                .thenReturn(Optional.empty());

        job.cleanupExpiredOrders();

        verify(pendingOrderCacheRepository).releaseReservation(eq("order-b"), anyString());
    }

    @Test
    void cleanupExpiredOrders_noExpiredOrders_releasesNothing() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong())).thenReturn(Map.of());

        job.cleanupExpiredOrders();

        verify(pendingOrderCacheRepository, never()).releaseReservation(anyString(), anyString());
    }
}
