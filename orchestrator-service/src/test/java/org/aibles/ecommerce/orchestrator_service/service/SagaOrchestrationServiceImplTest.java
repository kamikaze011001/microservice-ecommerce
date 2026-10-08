package org.aibles.ecommerce.orchestrator_service.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.impl.SagaOrchestrationServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.core.KafkaTemplate;
import java.time.LocalDateTime;
import java.util.concurrent.CompletableFuture;
import java.util.Map;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SagaOrchestrationServiceImplTest {

    @Mock SagaInstanceRepository repo;
    @Mock KafkaTemplate<String, Object> kafkaTemplate;
    @Mock ApplicationKafkaProperties kafkaProperties;
    @Mock ObjectMapper objectMapper;

    SagaOrchestrationServiceImpl service;

    static final String SUCCESS_TOPIC = "t.order.success";
    static final String FAILED_TOPIC = "t.order.failed";
    static final String CANCELED_TOPIC = "t.order.canceled";
    static final String INVENTORY_TOPIC = "t.inventory.update-quantity";

    @BeforeEach
    void setUp() {
        // Resolved names deliberately differ from their properties keys: sending to a
        // KEY instead of topic(key) must fail these tests, not pass by coincidence.
        lenient().when(kafkaProperties.getTopics()).thenReturn(Map.of(
                "order-service.order.success-status", SUCCESS_TOPIC,
                "order-service.order.failed-status", FAILED_TOPIC,
                "order-service.order.canceled-status", CANCELED_TOPIC,
                "inventory-service.inventory-product.update-quantity", INVENTORY_TOPIC
        ));
        // Default: the broker acknowledges every send. Tests that need a failure override this.
        lenient().when(kafkaTemplate.send(anyString(), anyString(), any()))
                .thenReturn(CompletableFuture.completedFuture(null));
        service = new SagaOrchestrationServiceImpl(repo, kafkaTemplate, kafkaProperties, objectMapper, 3, 30);
    }

    @Test
    void startSaga_createsSagaInAwaitingPayment() {
        service.startSaga("order-1");
        ArgumentCaptor<SagaInstance> captor = ArgumentCaptor.forClass(SagaInstance.class);
        verify(repo).save(captor.capture());
        assertThat(captor.getValue().getState()).isEqualTo(SagaState.AWAITING_PAYMENT);
        assertThat(captor.getValue().getOrderId()).isEqualTo("order-1");
    }

    @Test
    void startSaga_duplicateOrderId_logsAndReturnsGracefully() {
        when(repo.save(any())).thenThrow(DataIntegrityViolationException.class);
        assertThatNoException().isThrownBy(() -> service.startSaga("order-1"));
    }

    @Test
    void handlePaymentReply_success_transitionsToCompleted() {
        SagaInstance saga = existingSaga("order-2", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-2")).thenReturn(Optional.of(saga));
        // event data is a Map — extractOrderId takes the instanceof Map path, objectMapper not called

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-2"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPLETED);
        verify(kafkaTemplate, times(2)).send(anyString(), anyString(), any()); // order + inventory
    }

    @Test
    void handlePaymentReply_failed_transitionsToCompensated() {
        SagaInstance saga = existingSaga("order-3", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-3")).thenReturn(Optional.of(saga));

        PaymentFailedEvent event = new PaymentFailedEvent(this, Map.of("orderId", "order-3"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate).send(eq(FAILED_TOPIC), anyString(), isA(PaymentFailed.class));
        verifyNoMoreInteractions(kafkaTemplate);
    }

    @Test
    void handlePaymentReply_canceled_staysAwaitingPaymentForRetry() {
        // A PayPal-approval cancel abandons the attempt, not the order: the user may
        // retry, and SagaTimeoutScheduler compensates if they never pay.
        SagaInstance saga = existingSaga("order-7", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-7")).thenReturn(Optional.of(saga));

        PaymentCanceledEvent event = new PaymentCanceledEvent(this, Map.of("orderId", "order-7"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.AWAITING_PAYMENT);
        verify(kafkaTemplate, never()).send(anyString(), anyString(), any());
    }

    @Test
    void handleSuccess_orderNotifyFails_compensatesAsPaymentFailed() {
        // The payment DID go through but order-service couldn't be told — that is a
        // failed saga (order FAILED), never a timeout (order CANCELED).
        SagaInstance saga = existingSaga("order-9", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-9")).thenReturn(Optional.of(saga));
        when(kafkaTemplate.send(eq(SUCCESS_TOPIC), anyString(), any())).thenThrow(new RuntimeException("Kafka down"));

        service.handlePaymentReply(new PaymentSuccessEvent(this, Map.of("orderId", "order-9")));

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate).send(eq(FAILED_TOPIC), anyString(), isA(PaymentFailed.class));
        verify(kafkaTemplate, never()).send(eq(CANCELED_TOPIC), anyString(), any());
    }

    @Test
    void handleSuccess_inventoryNotifyFails_compensatesAsPaymentFailed() {
        SagaInstance saga = existingSaga("order-10", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-10")).thenReturn(Optional.of(saga));
        // lenient: other sends (success-status, failed-status) use different args
        lenient().when(kafkaTemplate.send(eq(INVENTORY_TOPIC), anyString(), any())).thenThrow(new RuntimeException("Kafka down"));

        service.handlePaymentReply(new PaymentSuccessEvent(this, Map.of("orderId", "order-10")));

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate).send(eq(FAILED_TOPIC), anyString(), isA(PaymentFailed.class));
        verify(kafkaTemplate, never()).send(eq(CANCELED_TOPIC), anyString(), any());
    }

    @Test
    void handlePaymentReply_alreadyTerminal_isDiscarded() {
        SagaInstance saga = existingSaga("order-4", SagaState.COMPLETED);
        when(repo.findByOrderId("order-4")).thenReturn(Optional.of(saga));

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-4"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), anyString(), any());
    }

    @Test
    void handlePaymentReply_unknownOrderId_isDiscarded() {
        when(repo.findByOrderId("order-x")).thenReturn(Optional.empty());

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-x"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), anyString(), any());
    }

    @Test
    void compensate_paymentFailed_sendsPaymentFailedToFailedStatus() {
        SagaInstance saga = existingSaga("order-5", SagaState.AWAITING_PAYMENT);

        service.compensate(saga, CompensationReason.PAYMENT_FAILED);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        ArgumentCaptor<Object> record = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq(FAILED_TOPIC), anyString(), record.capture());
        assertThat(record.getValue()).isInstanceOfSatisfying(PaymentFailed.class,
                r -> assertThat(r.getOrderId().toString()).isEqualTo("order-5"));
    }

    @Test
    void compensate_timedOut_sendsPaymentCanceledToCanceledStatus() {
        // Regression: the timeout path used to send PaymentFailed to canceled-status,
        // which order-service (specific.avro.reader=true, @Payload PaymentCanceled)
        // cannot convert — the order was never canceled.
        SagaInstance saga = existingSaga("order-8", SagaState.AWAITING_PAYMENT);

        service.compensate(saga, CompensationReason.TIMED_OUT);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        ArgumentCaptor<Object> record = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq(CANCELED_TOPIC), anyString(), record.capture());
        assertThat(record.getValue()).isInstanceOfSatisfying(PaymentCanceled.class,
                r -> assertThat(r.getOrderId().toString()).isEqualTo("order-8"));
    }

    @Test
    void compensate_kafkaFailsAllRetries_transitionsToFailed() {
        SagaInstance saga = existingSaga("order-6", SagaState.AWAITING_PAYMENT);
        when(kafkaTemplate.send(anyString(), anyString(), any())).thenThrow(new RuntimeException("Kafka down"));

        service.compensate(saga, CompensationReason.TIMED_OUT);

        assertThat(saga.getState()).isEqualTo(SagaState.FAILED);
        // 3 retries attempted (maxRetries=3 set in setUp)
        verify(kafkaTemplate, times(3)).send(anyString(), anyString(), any());
    }

    @Test
    void sends_areKeyedByOrderId() {
        // Key → partition: every message about one order must share a partition.
        SagaInstance saga = existingSaga("order-11", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-11")).thenReturn(Optional.of(saga));

        service.handlePaymentReply(new PaymentSuccessEvent(this, Map.of("orderId", "order-11")));
        service.compensate(existingSaga("order-12", SagaState.AWAITING_PAYMENT), CompensationReason.TIMED_OUT);

        verify(kafkaTemplate).send(eq(SUCCESS_TOPIC), eq("order-11"), any());
        verify(kafkaTemplate).send(eq(INVENTORY_TOPIC), eq("order-11"), any());
        verify(kafkaTemplate).send(eq(CANCELED_TOPIC), eq("order-12"), any());
    }

    @Test
    void compensate_brokerRejectsSend_countsAsFailure() {
        // send() returning normally only means "queued in the producer buffer". The
        // broker can still reject it later; that must count as a failed attempt,
        // or the saga is marked COMPENSATED for a message that was never delivered.
        SagaInstance saga = existingSaga("order-13", SagaState.AWAITING_PAYMENT);
        when(kafkaTemplate.send(anyString(), anyString(), any()))
                .thenReturn(CompletableFuture.failedFuture(new RuntimeException("NOT_ENOUGH_REPLICAS")));

        service.compensate(saga, CompensationReason.TIMED_OUT);

        assertThat(saga.getState()).isEqualTo(SagaState.FAILED);
        verify(kafkaTemplate, times(3)).send(anyString(), anyString(), any());
    }

    private SagaInstance existingSaga(String orderId, SagaState state) {
        return SagaInstance.builder()
                .id("id-" + orderId).orderId(orderId).state(state)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().plusMinutes(30))
                .build();
    }
}
