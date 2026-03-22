package org.aibles.ecommerce.orchestrator_service.scheduler;

import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import java.time.LocalDateTime;
import java.util.List;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SagaTimeoutSchedulerTest {

    @Mock SagaInstanceRepository repo;
    @Mock SagaOrchestrationService orchestrationService;
    @Mock RedissonClient redissonClient;
    @Mock RLock lock;

    @Test
    void checkExpiredSagas_compensatesExpiredSagas() throws InterruptedException {
        when(redissonClient.getLock("saga-timeout-scheduler-lock")).thenReturn(lock);
        when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);

        SagaInstance expired = SagaInstance.builder()
                .id("saga-1").orderId("order-1").state(SagaState.AWAITING_PAYMENT)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().minusMinutes(1))
                .build();
        when(repo.findExpiredSagas(any())).thenReturn(List.of(expired));

        SagaTimeoutScheduler scheduler = new SagaTimeoutScheduler(repo, orchestrationService, redissonClient);
        scheduler.checkExpiredSagas();

        verify(orchestrationService).compensate(eq(expired), eq("order-service.order.canceled-status"));
        verify(lock).unlock();
    }

    @Test
    void checkExpiredSagas_skipsIfLockNotAcquired() throws InterruptedException {
        when(redissonClient.getLock("saga-timeout-scheduler-lock")).thenReturn(lock);
        when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(false);

        SagaTimeoutScheduler scheduler = new SagaTimeoutScheduler(repo, orchestrationService, redissonClient);
        scheduler.checkExpiredSagas();

        verify(orchestrationService, never()).compensate(any(), any());
        verify(lock, never()).unlock();
    }
}
