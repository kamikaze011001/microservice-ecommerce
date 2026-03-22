package org.aibles.ecommerce.orchestrator_service.scheduler;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.util.List;
import java.util.concurrent.TimeUnit;

@Slf4j
@Component
@RequiredArgsConstructor
public class SagaTimeoutScheduler {

    private static final String LOCK_KEY = "saga-timeout-scheduler-lock";

    private final SagaInstanceRepository repo;
    private final SagaOrchestrationService orchestrationService;
    private final RedissonClient redissonClient;

    @Scheduled(fixedDelayString = "${application.saga.timeout-check-interval:60000}")
    public void checkExpiredSagas() {
        RLock lock = redissonClient.getLock(LOCK_KEY);
        boolean locked = false;
        try {
            locked = lock.tryLock(0, 55, TimeUnit.SECONDS);
            if (!locked) {
                log.debug("(checkExpiredSagas) Could not acquire lock — another instance is running");
                return;
            }

            List<SagaInstance> expired = repo.findExpiredSagas(LocalDateTime.now());
            log.info("(checkExpiredSagas) Found {} expired sagas", expired.size());

            for (SagaInstance saga : expired) {
                log.info("(checkExpiredSagas) Timeout compensation for orderId: {}", saga.getOrderId());
                orchestrationService.compensate(saga, "order-service.order.canceled-status");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.error("(checkExpiredSagas) Interrupted while acquiring lock", e);
        } finally {
            if (locked) {
                lock.unlock();
            }
        }
    }
}
