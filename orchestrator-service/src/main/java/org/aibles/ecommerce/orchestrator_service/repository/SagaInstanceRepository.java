package org.aibles.ecommerce.orchestrator_service.repository;

import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

public interface SagaInstanceRepository extends JpaRepository<SagaInstance, String> {

    Optional<SagaInstance> findByOrderId(String orderId);

    @Query("SELECT s FROM SagaInstance s WHERE s.state = org.aibles.ecommerce.orchestrator_service.entity.SagaState.AWAITING_PAYMENT AND s.expiresAt < :now")
    List<SagaInstance> findExpiredSagas(@Param("now") LocalDateTime now);
}
