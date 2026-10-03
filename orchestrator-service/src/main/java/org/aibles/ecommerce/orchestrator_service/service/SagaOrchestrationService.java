package org.aibles.ecommerce.orchestrator_service.service;

import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.orchestrator_service.entity.CompensationReason;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;

public interface SagaOrchestrationService {
    void startSaga(String orderId);
    void handlePaymentReply(BaseEvent event);
    /**
     * @param reason why the saga is compensated; the implementation derives the
     *               topic AND the Avro record type from it, so callers never
     *               choose a topic.
     */
    void compensate(SagaInstance saga, CompensationReason reason);
}
