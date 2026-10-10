package org.aibles.ecommerce.orchestrator_service.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.common_dto.avro_kafka.OrderCreated;
import org.aibles.ecommerce.common_dto.avro_kafka.OrderLine;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.PaymentSuccessEvent;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.aibles.ecommerce.orchestrator_service.entity.SagaItem;
import org.aibles.ecommerce.orchestrator_service.entity.SagaState;
import org.aibles.ecommerce.orchestrator_service.listener.MongoEventListenerProbe;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.impl.SagaOrchestrationServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The order's lines travel Order.Created → saga → PaymentSuccess, so inventory
 * can decrement stock without the Redis pending-order index (which a Redis
 * restart loses — the chaos run lost 70 of 532 decrements that way).
 * A real ObjectMapper here: the JSON round-trip is the thing under test.
 */
class SagaItemsTest {

    private static final String INVENTORY_TOPIC = "t.inventory.update-quantity";
    private final ObjectMapper mapper = new ObjectMapper();
    private SagaInstanceRepository repo;
    private KafkaTemplate<String, Object> kafka;
    private SagaOrchestrationServiceImpl service;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        repo = mock(SagaInstanceRepository.class);
        kafka = mock(KafkaTemplate.class);
        ApplicationKafkaProperties props = mock(ApplicationKafkaProperties.class);
        when(props.getTopics()).thenReturn(Map.of(
                "order-service.order.success-status", "t.order.success",
                "inventory-service.inventory-product.update-quantity", INVENTORY_TOPIC));
        when(kafka.send(anyString(), anyString(), any())).thenReturn(CompletableFuture.completedFuture(null));
        service = new SagaOrchestrationServiceImpl(repo, kafka, props, mapper, 3, 30);
    }

    @Test
    void theSagaRemembersTheOrderLines() {
        service.startSaga("order-1", List.of(new SagaItem("p1", 2), new SagaItem("p2", 1)));

        ArgumentCaptor<SagaInstance> saved = ArgumentCaptor.forClass(SagaInstance.class);
        verify(repo).save(saved.capture());
        assertThat(saved.getValue().getItems())
                .isEqualTo("[{\"productId\":\"p1\",\"quantity\":2},{\"productId\":\"p2\",\"quantity\":1}]");
    }

    @Test
    void paymentSuccessCarriesTheLinesToInventory() {
        SagaInstance saga = saga("order-2", "[{\"productId\":\"p1\",\"quantity\":2}]");
        when(repo.findByOrderId("order-2")).thenReturn(Optional.of(saga));

        service.handlePaymentReply(new PaymentSuccessEvent(this, Map.of("orderId", "order-2")));

        ArgumentCaptor<Object> sent = ArgumentCaptor.forClass(Object.class);
        verify(kafka).send(eq(INVENTORY_TOPIC), eq("order-2"), sent.capture());
        PaymentSuccess payload = (PaymentSuccess) sent.getValue();
        assertThat(payload.getItems()).extracting(l -> l.getProductId().toString(), OrderLine::getQuantity)
                .containsExactly(org.assertj.core.groups.Tuple.tuple("p1", 2L));
    }

    @Test
    void aSagaFromBeforeTheChangeSendsNoLines() {
        when(repo.findByOrderId("order-3")).thenReturn(Optional.of(saga("order-3", null)));

        service.handlePaymentReply(new PaymentSuccessEvent(this, Map.of("orderId", "order-3")));

        ArgumentCaptor<Object> sent = ArgumentCaptor.forClass(Object.class);
        verify(kafka).send(eq(INVENTORY_TOPIC), eq("order-3"), sent.capture());
        assertThat(((PaymentSuccess) sent.getValue()).getItems()).isEmpty();
    }

    @Test
    void theListenerReadsLinesFromWhatOrderServiceActuallyWritesToMongo() {
        // Order.Created reaches the orchestrator as the Avro record's toString()
        // (MongoSavedEventListener stores data.toString(); CDC carries it as JSON).
        String asStoredInMongo = OrderCreated.newBuilder()
                .setOrderId("order-4")
                .setItems(List.of(
                        OrderLine.newBuilder().setProductId("p1").setQuantity(3).build(),
                        OrderLine.newBuilder().setProductId("p2").setQuantity(1).build()))
                .build().toString();

        assertThat(MongoEventListenerProbe.extractItems(mapper, asStoredInMongo))
                .containsExactly(new SagaItem("p1", 3), new SagaItem("p2", 1));
    }

    @Test
    void theListenerToleratesOldAndOddEvents() {
        assertThat(MongoEventListenerProbe.extractItems(mapper, "{\"orderId\": \"o\"}")).isEmpty();
        assertThat(MongoEventListenerProbe.extractItems(mapper, Map.of("orderId", "o",
                "items", List.of(Map.of("productId", "p1", "quantity", 2), Map.of("productId", "p2", "quantity", 0)))))
                .containsExactly(new SagaItem("p1", 2));
        assertThat(MongoEventListenerProbe.extractItems(mapper, "not json")).isEmpty();
    }

    private static SagaInstance saga(String orderId, String items) {
        return SagaInstance.builder().id("id-" + orderId).orderId(orderId).state(SagaState.AWAITING_PAYMENT)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().plusMinutes(30)).items(items).build();
    }
}
