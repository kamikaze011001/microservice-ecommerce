package org.aibles.order_service.scheduler;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.Map;

/**
 * Scheduled job that gives back the inventory reservations of orders that were
 * never paid (their pending-orders ZSET score — the expiry — has passed).
 *
 * Safe on any number of order-service pods without a job-level lock: each order is
 * released through {@link PendingOrderCacheRepository#releaseReservation}, an atomic
 * claim that exactly one caller wins — whether the competitor is this job on another
 * pod or the cancel/fail consumer handling the same order. The old version read the
 * entry, incremented `available`, then removed it, so two pods could both release
 * the same order and over-credit stock.
 */
@Component
@Slf4j
public class ExpiredOrderCleanupJob {

    private final PendingOrderCacheRepository pendingOrderCacheRepository;

    public ExpiredOrderCleanupJob(PendingOrderCacheRepository pendingOrderCacheRepository) {
        this.pendingOrderCacheRepository = pendingOrderCacheRepository;
    }

    /**
     * Runs every 30 minutes. Cron: at minute 0 and 30 of every hour.
     */
    @Scheduled(cron = "0 */30 * * * *")
    public void cleanupExpiredOrders() {
        Map<String, Map<String, Long>> expiredOrders =
                pendingOrderCacheRepository.getExpiredOrders(Instant.now().toEpochMilli());
        if (expiredOrders.isEmpty()) {
            return;
        }

        int released = 0;
        int alreadyHandled = 0;
        int failed = 0;
        for (String orderId : expiredOrders.keySet()) {
            try {
                if (pendingOrderCacheRepository.releaseReservation(orderId, RedisConstant.AVAILABLE_PRODUCT_KEY).isPresent()) {
                    released++;
                } else {
                    alreadyHandled++;   // another pod or the cancel/fail consumer got there first
                }
            } catch (Exception e) {
                failed++;
                log.error("expired reservation not released, will retry next run. orderId={}", orderId, e);
            }
        }
        log.info("expired-order cleanup finished. found={} released={} alreadyHandled={} failed={}",
                expiredOrders.size(), released, alreadyHandled, failed);
    }
}
