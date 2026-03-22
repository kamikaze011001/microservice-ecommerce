package org.aibles.ecommerce.orchestrator_service.entity;

public enum SagaState {
    STARTED, AWAITING_PAYMENT, CONFIRMING, COMPENSATING,
    COMPLETED, COMPENSATED, FAILED;

    public boolean isTerminal() {
        return this == COMPLETED || this == COMPENSATED || this == FAILED;
    }
}
