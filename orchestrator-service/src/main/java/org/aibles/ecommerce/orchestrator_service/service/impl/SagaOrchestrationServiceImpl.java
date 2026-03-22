package org.aibles.ecommerce.orchestrator_service.service.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

@Slf4j
@Service
public class SagaOrchestrationServiceImpl implements SagaOrchestrationService {

    private final SagaInstanceRepository repo;
    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final ApplicationKafkaProperties kafkaProperties;
    private final ObjectMapper objectMapper;
    private final int maxRetries;
    private final int sagaTtlMinutes;

    public SagaOrchestrationServiceImpl(
            SagaInstanceRepository repo,
            KafkaTemplate<String, Object> kafkaTemplate,
            ApplicationKafkaProperties kafkaProperties,
            ObjectMapper objectMapper,
            @Value("${application.saga.compensation-max-retries:3}") int maxRetries,
            @Value("${application.saga.saga-ttl-minutes:30}") int sagaTtlMinutes) {
        this.repo = repo;
        this.kafkaTemplate = kafkaTemplate;
        this.kafkaProperties = kafkaProperties;
        this.objectMapper = objectMapper;
        this.maxRetries = maxRetries;
        this.sagaTtlMinutes = sagaTtlMinutes;
    }

    @Override
    @Transactional
    public void startSaga(String orderId) {
        log.info("(startSaga) Starting saga for orderId: {}", orderId);
        SagaInstance saga = SagaInstance.builder()
                .id(UUID.randomUUID().toString())
                .orderId(orderId)
                .state(SagaState.AWAITING_PAYMENT)
                .expiresAt(LocalDateTime.now().plusMinutes(sagaTtlMinutes))
                .build();
        try {
            repo.save(saga);
            log.info("(startSaga) Saga created in AWAITING_PAYMENT for orderId: {}", orderId);
        } catch (DataIntegrityViolationException e) {
            log.warn("(startSaga) Saga already exists for orderId: {} — duplicate Order.Created, discarding", orderId);
        }
    }

    @Override
    @Transactional
    public void handlePaymentReply(BaseEvent event) {
        String orderId = extractOrderId(event.getData());
        if (orderId == null) {
            log.warn("(handlePaymentReply) Cannot extract orderId from event data: {}", event.getData());
            return;
        }

        Optional<SagaInstance> optional = repo.findByOrderId(orderId);
        if (optional.isEmpty()) {
            log.warn("(handlePaymentReply) No SagaInstance for orderId: {} — discarding", orderId);
            return;
        }

        SagaInstance saga = optional.get();
        if (saga.getState().isTerminal()) {
            log.warn("(handlePaymentReply) Saga for orderId: {} is already in terminal state {} — discarding", orderId, saga.getState());
            return;
        }

        if (event instanceof PaymentSuccessEvent) {
            handleSuccess(saga, orderId);
        } else if (event instanceof PaymentFailedEvent) {
            compensate(saga, topic("order-service.order.failed-status"));
        } else if (event instanceof PaymentCanceledEvent) {
            compensate(saga, topic("order-service.order.canceled-status"));
        }
    }

    @Override
    @Transactional
    public void compensate(SagaInstance saga, String compensationTopic) {
        log.info("(compensate) Compensating saga orderId: {} via topic: {}", saga.getOrderId(), compensationTopic);
        saga.setState(SagaState.COMPENSATING);
        repo.save(saga);

        String orderId = saga.getOrderId();
        boolean sent = sendWithRetry(compensationTopic, buildPaymentFailed(orderId));
        if (!sent) {
            saga.setState(SagaState.FAILED);
            repo.save(saga);
            log.error("(compensate) Saga FAILED — could not send compensation for orderId: {}", orderId);
            return;
        }

        saga.setState(SagaState.COMPENSATED);
        repo.save(saga);
        log.info("(compensate) Saga COMPENSATED for orderId: {}", orderId);
    }

    private void handleSuccess(SagaInstance saga, String orderId) {
        saga.setState(SagaState.CONFIRMING);
        repo.save(saga);

        PaymentSuccess avro = PaymentSuccess.newBuilder().setOrderId(orderId).build();
        boolean orderSent = sendWithRetry(topic("order-service.order.success-status"), avro);
        if (!orderSent) {
            log.error("(handleSuccess) Failed to notify order-service for orderId: {} — compensating", orderId);
            compensate(saga, topic("order-service.order.failed-status"));
            return;
        }

        boolean inventorySent = sendWithRetry(topic("inventory-service.inventory-product.update-quantity"), avro);
        if (!inventorySent) {
            log.error("(handleSuccess) Failed to notify inventory-service for orderId: {} — compensating", orderId);
            compensate(saga, topic("order-service.order.failed-status"));
            return;
        }

        saga.setState(SagaState.COMPLETED);
        repo.save(saga);
        log.info("(handleSuccess) Saga COMPLETED for orderId: {}", orderId);
    }

    private boolean sendWithRetry(String topicName, Object message) {
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                kafkaTemplate.send(topicName, message);
                return true;
            } catch (Exception e) {
                log.warn("(sendWithRetry) Attempt {}/{} failed for topic: {}", attempt, maxRetries, topicName, e);
            }
        }
        return false;
    }

    private String topic(String key) {
        return kafkaProperties.getTopics().get(key);
    }

    private PaymentFailed buildPaymentFailed(String orderId) {
        return PaymentFailed.newBuilder().setOrderId(orderId).build();
    }

    private String extractOrderId(Object data) {
        try {
            if (data instanceof Map) {
                Object id = ((Map<?, ?>) data).get("orderId");
                return id != null ? id.toString() : null;
            }
            String json = objectMapper.writeValueAsString(data);
            return objectMapper.readTree(json).path("orderId").asText(null);
        } catch (Exception e) {
            log.warn("(extractOrderId) Failed to extract orderId from data: {}", data, e);
            return null;
        }
    }
}
