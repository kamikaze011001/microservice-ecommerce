package org.aibles.ecommerce.orchestrator_service.service;

import com.fasterxml.jackson.databind.ObjectMapper;
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

    @BeforeEach
    void setUp() {
        lenient().when(kafkaProperties.getTopics()).thenReturn(Map.of(
                "order-service.order.success-status", "order-service.order.success-status",
                "order-service.order.failed-status", "order-service.order.failed-status",
                "order-service.order.canceled-status", "order-service.order.canceled-status",
                "inventory-service.inventory-product.update-quantity", "inventory-service.inventory-product.update-quantity"
        ));
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
        verify(kafkaTemplate, times(2)).send(anyString(), any()); // order + inventory
    }

    @Test
    void handlePaymentReply_failed_transitionsToCompensated() {
        SagaInstance saga = existingSaga("order-3", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-3")).thenReturn(Optional.of(saga));

        PaymentFailedEvent event = new PaymentFailedEvent(this, Map.of("orderId", "order-3"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate, times(1)).send(anyString(), any()); // order only
    }

    @Test
    void handlePaymentReply_alreadyTerminal_isDiscarded() {
        SagaInstance saga = existingSaga("order-4", SagaState.COMPLETED);
        when(repo.findByOrderId("order-4")).thenReturn(Optional.of(saga));

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-4"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), any());
    }

    @Test
    void handlePaymentReply_unknownOrderId_isDiscarded() {
        when(repo.findByOrderId("order-x")).thenReturn(Optional.empty());

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-x"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), any());
    }

    @Test
    void compensate_sendsToOrderServiceAndTransitionsToCompensated() {
        SagaInstance saga = existingSaga("order-5", SagaState.AWAITING_PAYMENT);

        service.compensate(saga, "order-service.order.canceled-status");

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate).send(eq("order-service.order.canceled-status"), any());
    }

    @Test
    void compensate_kafkaFailsAllRetries_transitionsToFailed() {
        SagaInstance saga = existingSaga("order-6", SagaState.AWAITING_PAYMENT);
        when(kafkaTemplate.send(anyString(), any())).thenThrow(new RuntimeException("Kafka down"));

        service.compensate(saga, "order-service.order.canceled-status");

        assertThat(saga.getState()).isEqualTo(SagaState.FAILED);
        // 3 retries attempted (maxRetries=3 set in setUp)
        verify(kafkaTemplate, times(3)).send(anyString(), any());
    }

    private SagaInstance existingSaga(String orderId, SagaState state) {
        return SagaInstance.builder()
                .id("id-" + orderId).orderId(orderId).state(state)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().plusMinutes(30))
                .build();
    }
}
