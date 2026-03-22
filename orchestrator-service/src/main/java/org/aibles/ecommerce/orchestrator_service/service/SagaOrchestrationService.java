package org.aibles.ecommerce.orchestrator_service.service;

import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;

public interface SagaOrchestrationService {
    void startSaga(String orderId);
    void handlePaymentReply(BaseEvent event);
    /**
     * @param compensationTopic the RESOLVED Kafka topic name (not a properties key).
     *                          Callers must resolve topic keys via kafkaProperties.getTopics()
     *                          before passing here. The scheduler passes the literal topic name.
     */
    void compensate(SagaInstance saga, String compensationTopic);
}
