package org.aibles.ecommerce.orchestrator_service.service;

import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.orchestrator_service.entity.CompensationReason;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.aibles.ecommerce.orchestrator_service.entity.SagaItem;

import java.util.List;

public interface SagaOrchestrationService {
    /** Starts the saga for an order and records its lines for the stock decrement. */
    void startSaga(String orderId, List<SagaItem> items);

    /** Order.Created without lines (written before they were carried). */
    default void startSaga(String orderId) {
        startSaga(orderId, List.of());
    }
    void handlePaymentReply(BaseEvent event);
    /**
     * @param reason why the saga is compensated; the implementation derives the
     *               topic AND the Avro record type from it, so callers never
     *               choose a topic.
     */
    void compensate(SagaInstance saga, CompensationReason reason);
}
