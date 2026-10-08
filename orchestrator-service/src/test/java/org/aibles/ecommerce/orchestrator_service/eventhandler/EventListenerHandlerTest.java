package org.aibles.ecommerce.orchestrator_service.eventhandler;

import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.event.EventHeaders;
import org.aibles.ecommerce.common_dto.event.ProductQuantityUpdatedEvent;
import org.aibles.ecommerce.common_dto.event.ProductUpdateEvent;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.listener.CdcRecordSource;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.header.Header;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
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
        lenient().when(kafkaTemplate.send(any(ProducerRecord.class)))
                .thenReturn(CompletableFuture.completedFuture(null));
        handler = new EventListenerHandler(kafkaTemplate, kafkaProperties);
    }

    @Test
    void productQuantityUpdated_isKeyedByProductId() {
        // Two stock deltas for one product must apply in order → same partition.
        String data = "{\"productId\": \"p-1\", \"quantity\": -2}";

        ReflectionTestUtils.invokeMethod(handler, "handleProductQuantityUpdated",
                new ProductQuantityUpdatedEvent(this, data));

        ProducerRecord<String, Object> sent = sentRecord();
        assertThat(sent.topic()).isEqualTo(PRODUCT_QTY_TOPIC);
        assertThat(sent.key()).isEqualTo("p-1");
        assertThat(sent.value()).isInstanceOf(ProductQuantityUpdated.class);
    }

    @Test
    void productUpdate_isKeyedByProductId() {
        String data = "{\"id\": \"p-2\", \"name\": \"Mug\", \"price\": 9.5, \"imageUrl\": null}";

        ReflectionTestUtils.invokeMethod(handler, "handleProductUpdate",
                new ProductUpdateEvent(this, data));

        ProducerRecord<String, Object> sent = sentRecord();
        assertThat(sent.topic()).isEqualTo(INVENTORY_PRODUCT_TOPIC);
        assertThat(sent.key()).isEqualTo("p-2");
        assertThat(sent.value()).isInstanceOf(ProductUpdate.class);
    }

    @Test
    void forwardFromCdcRecord_carriesItsIdAsSourceEventHeader() {
        // product-service dedupes its stock-ledger row on this header: a redelivered
        // CDC record has the same coordinates, so a re-forward has the same id.
        String data = "{\"productId\": \"p-4\", \"quantity\": 1}";

        ReflectionTestUtils.invokeMethod(handler, "handleProductQuantityUpdated",
                new ProductQuantityUpdatedEvent(new CdcRecordSource("cdc.topic", 7, 42L), data));

        Header header = sentRecord().headers().lastHeader(EventHeaders.SOURCE_EVENT_ID);
        assertThat(header).isNotNull();
        assertThat(new String(header.value(), StandardCharsets.UTF_8)).isEqualTo("cdc.topic-7-42");
    }

    @Test
    void brokerRejectsSend_failsTheHandler_soTheCdcRecordIsRetried() {
        // This handler runs on the CDC consumer thread. If a failed forward is
        // swallowed, the CDC offset is committed and the update is lost for good.
        lenient().when(kafkaTemplate.send(any(ProducerRecord.class)))
                .thenReturn(CompletableFuture.failedFuture(new RuntimeException("broker down")));
        String data = "{\"productId\": \"p-3\", \"quantity\": 5}";

        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(handler, "handleProductQuantityUpdated",
                new ProductQuantityUpdatedEvent(this, data)))
                .hasStackTraceContaining("broker down");
    }

    @SuppressWarnings("unchecked")
    private ProducerRecord<String, Object> sentRecord() {
        ArgumentCaptor<ProducerRecord<String, Object>> captor = ArgumentCaptor.forClass(ProducerRecord.class);
        verify(kafkaTemplate).send(captor.capture());
        return captor.getValue();
    }
}
