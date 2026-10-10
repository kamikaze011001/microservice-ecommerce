package org.aibles.ecommerce.orchestrator_service.service.impl;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.OrderLine;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.apache.avro.specific.SpecificRecordBase;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

@Slf4j
@Service
public class SagaOrchestrationServiceImpl implements SagaOrchestrationService {

    /** Bounded so a hung broker can't hold the consumer thread past max.poll.interval.ms (5 min). */
    private static final Duration SEND_ACK_TIMEOUT = Duration.ofSeconds(10);

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
    public void startSaga(String orderId, List<SagaItem> items) {
        log.info("(startSaga) Starting saga for orderId: {} with {} line(s)", orderId, items.size());
        SagaInstance saga = SagaInstance.builder()
                .id(UUID.randomUUID().toString())
                .orderId(orderId)
                .state(SagaState.AWAITING_PAYMENT)
                .expiresAt(LocalDateTime.now().plusMinutes(sagaTtlMinutes))
                .items(items.isEmpty() ? null : writeItems(items))
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
            compensate(saga, CompensationReason.PAYMENT_FAILED);
        } else if (event instanceof PaymentCanceledEvent) {
            // A PayPal-approval cancel abandons THIS payment attempt but does NOT
            // cancel the order — the user can retry payment, and a later
            // PaymentSuccess must still complete it. So keep the saga in
            // AWAITING_PAYMENT (do not compensate to a terminal state, which would
            // discard a subsequent success). If the order is never paid,
            // SagaTimeoutScheduler compensates it once expiresAt passes
            // (findExpiredSagas only picks up AWAITING_PAYMENT sagas).
            log.info("(handlePaymentReply) Payment attempt canceled for orderId: {} — staying AWAITING_PAYMENT for retry", orderId);
        }
    }

    @Override
    @Transactional
    public void compensate(SagaInstance saga, CompensationReason compensationReason) {
        log.info("(compensate) Compensating saga orderId: {} via topic: {}", saga.getOrderId(), compensationReason.getTopicKey());
        saga.setState(SagaState.COMPENSATING);
        repo.save(saga);

        String orderId = saga.getOrderId();
        boolean sent = sendWithRetry(topic(compensationReason.getTopicKey()), orderId,
                buildPaymentCompensation(compensationReason, orderId));
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

        // The lines ride along so inventory decrements from the event itself.
        PaymentSuccess avro = PaymentSuccess.newBuilder()
                .setOrderId(orderId)
                .setItems(readItems(saga).stream()
                        .map(i -> OrderLine.newBuilder().setProductId(i.productId()).setQuantity(i.quantity()).build())
                        .toList())
                .build();
        boolean orderSent = sendWithRetry(topic("order-service.order.success-status"), orderId, avro);
        if (!orderSent) {
            log.error("(handleSuccess) Failed to notify order-service for orderId: {} — compensating", orderId);
            compensate(saga, CompensationReason.PAYMENT_FAILED);
            return;
        }

        boolean inventorySent = sendWithRetry(topic("inventory-service.inventory-product.update-quantity"), orderId, avro);
        if (!inventorySent) {
            log.error("(handleSuccess) Failed to notify inventory-service for orderId: {} — compensating", orderId);
            compensate(saga, CompensationReason.PAYMENT_FAILED);
            return;
        }

        saga.setState(SagaState.COMPLETED);
        repo.save(saga);
        log.info("(handleSuccess) Saga COMPLETED for orderId: {}", orderId);
    }

    /**
     * Sends {@code message} keyed by {@code orderId} and returns true only once the
     * broker has acknowledged it. The key pins every message about one order to one
     * partition; waiting for the ack matters because send() returns as soon as the
     * record is buffered, so a broker rejection would otherwise go unseen and the
     * saga would advance for a message nobody received.
     */
    private boolean sendWithRetry(String topicName, String orderId, Object message) {
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                kafkaTemplate.send(topicName, orderId, message)
                        .get(SEND_ACK_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
                return true;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.warn("send interrupted. topic={} orderId={}", topicName, orderId);
                return false;
            } catch (Exception e) {
                log.warn("send not acknowledged, attempt {}/{}. topic={} orderId={}",
                        attempt, maxRetries, topicName, orderId, e);
            }
        }
        return false;
    }

    private String topic(String key) {
        return kafkaProperties.getTopics().get(key);
    }

    private SpecificRecordBase buildPaymentCompensation(CompensationReason compensationReason, String orderId) {
        return switch (compensationReason) {
            case PAYMENT_FAILED -> PaymentFailed.newBuilder().setOrderId(orderId).build();
            case TIMED_OUT      -> PaymentCanceled.newBuilder().setOrderId(orderId).build();
        };
    }

    private String extractOrderId(Object data) {
        try {
            if (data instanceof Map) {
                Object id = ((Map<?, ?>) data).get("orderId");
                return id != null ? id.toString() : null;
            }
            if (data instanceof String str) {
                return objectMapper.readTree(str).path("orderId").asText(null);
            }
            String json = objectMapper.writeValueAsString(data);
            return objectMapper.readTree(json).path("orderId").asText(null);
        } catch (Exception e) {
            log.warn("(extractOrderId) Failed to extract orderId from data: {}", data, e);
            return null;
        }
    }

    private String writeItems(List<SagaItem> items) {
        try {
            return objectMapper.writeValueAsString(items);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("cannot serialize saga items", e);
        }
    }

    /** Empty for sagas started before Order.Created carried lines. */
    private List<SagaItem> readItems(SagaInstance saga) {
        if (saga.getItems() == null || saga.getItems().isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(saga.getItems(), new TypeReference<List<SagaItem>>() { });
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("corrupt saga items for orderId " + saga.getOrderId(), e);
        }
    }
}
