package org.aibles.ecommerce.orchestrator_service.entity;

import org.aibles.ecommerce.orchestrator_service.config.TestJpaAuditingConfig;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;
import org.springframework.context.annotation.Import;
import java.time.LocalDateTime;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;

@DataJpaTest
@Import(TestJpaAuditingConfig.class)  // required: loads @EnableJpaAuditing for AuditingEntityListener
class SagaInstanceRepositoryTest {

    @Autowired TestEntityManager em;
    @Autowired SagaInstanceRepository repo;

    @Test
    void findByOrderId_returnsInstance() {
        SagaInstance saga = SagaInstance.builder()
                .id("saga-1")
                .orderId("order-1")
                .state(SagaState.AWAITING_PAYMENT)
                .expiresAt(LocalDateTime.now().plusMinutes(30))
                .build();
        em.persist(saga);
        em.flush();

        Optional<SagaInstance> result = repo.findByOrderId("order-1");
        assertThat(result).isPresent();
        assertThat(result.get().getState()).isEqualTo(SagaState.AWAITING_PAYMENT);
    }

    @Test
    void duplicateOrderId_throwsDataIntegrityViolation() {
        SagaInstance s1 = buildSaga("saga-2", "order-2");
        SagaInstance s2 = buildSaga("saga-3", "order-2");
        em.persist(s1);
        em.flush();
        assertThatThrownBy(() -> { em.persist(s2); em.flush(); })
                .isInstanceOf(Exception.class);
    }

    @Test
    void findExpiredSagas_returnsOnlyExpiredAwaitingPayment() {
        SagaInstance expired = buildSagaWithExpiry("saga-4", "order-4", LocalDateTime.now().minusMinutes(1));
        SagaInstance notExpired = buildSagaWithExpiry("saga-5", "order-5", LocalDateTime.now().plusMinutes(30));
        SagaInstance completedExpired = buildSagaWithExpiry("saga-6", "order-6", LocalDateTime.now().minusMinutes(1));
        completedExpired.setState(SagaState.COMPLETED);
        em.persist(expired); em.persist(notExpired); em.persist(completedExpired);
        em.flush();

        var result = repo.findExpiredSagas(LocalDateTime.now());
        assertThat(result).hasSize(1);
        assertThat(result.get(0).getOrderId()).isEqualTo("order-4");
    }

    private SagaInstance buildSaga(String id, String orderId) {
        return buildSagaWithExpiry(id, orderId, LocalDateTime.now().plusMinutes(30));
    }

    private SagaInstance buildSagaWithExpiry(String id, String orderId, LocalDateTime expiresAt) {
        return SagaInstance.builder()
                .id(id).orderId(orderId).state(SagaState.AWAITING_PAYMENT)
                .expiresAt(expiresAt).build();
    }
}
