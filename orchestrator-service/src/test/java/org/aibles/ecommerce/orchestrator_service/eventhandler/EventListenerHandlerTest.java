package org.aibles.ecommerce.orchestrator_service.eventhandler;

import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.event.ProductQuantityUpdatedEvent;
import org.aibles.ecommerce.common_dto.event.ProductUpdateEvent;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Map;
import java.util.concurrent.CompletableFuture;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isA;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class EventListenerHandlerTest {

    static final String PRODUCT_QTY_TOPIC = "t.product.update-quantity";
    static final String INVENTORY_PRODUCT_TOPIC = "t.inventory.product-update";

    @Mock KafkaTemplate<String, Object> kafkaTemplate;
    @Mock ApplicationKafkaProperties kafkaProperties;

    EventListenerHandler handler;

    @BeforeEach
    void setUp() {
        lenient().when(kafkaProperties.getTopics()).thenReturn(Map.of(
                "product-service.product.update-quantity", PRODUCT_QTY_TOPIC,
                "inventory-service.product.update", INVENTORY_PRODUCT_TOPIC));
        lenient().when(kafkaTemplate.send(anyString(), anyString(), any()))
                .thenReturn(CompletableFuture.completedFuture(null));
        handler = new EventListenerHandler(kafkaTemplate, kafkaProperties);
    }

    @Test
    void productQuantityUpdated_isKeyedByProductId() {
        // Two stock deltas for one product must apply in order → same partition.
        String data = "{\"productId\": \"p-1\", \"quantity\": -2}";

        ReflectionTestUtils.invokeMethod(handler, "handleProductQuantityUpdated",
                new ProductQuantityUpdatedEvent(this, data));

        verify(kafkaTemplate).send(eq(PRODUCT_QTY_TOPIC), eq("p-1"), isA(ProductQuantityUpdated.class));
    }

    @Test
    void productUpdate_isKeyedByProductId() {
        String data = "{\"id\": \"p-2\", \"name\": \"Mug\", \"price\": 9.5, \"imageUrl\": null}";

        ReflectionTestUtils.invokeMethod(handler, "handleProductUpdate",
                new ProductUpdateEvent(this, data));

        verify(kafkaTemplate).send(eq(INVENTORY_PRODUCT_TOPIC), eq("p-2"), isA(ProductUpdate.class));
    }

    @Test
    void brokerRejectsSend_failsTheHandler_soTheCdcRecordIsRetried() {
        // This handler runs on the CDC consumer thread. If a failed forward is
        // swallowed, the CDC offset is committed and the update is lost for good.
        lenient().when(kafkaTemplate.send(anyString(), anyString(), any()))
                .thenReturn(CompletableFuture.failedFuture(new RuntimeException("broker down")));
        String data = "{\"productId\": \"p-3\", \"quantity\": 5}";

        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(handler, "handleProductQuantityUpdated",
                new ProductQuantityUpdatedEvent(this, data)))
                .hasStackTraceContaining("broker down");
    }
}
