package org.aibles.ecommerce.inventory_service.listener;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

@Component
@Slf4j
public class InventoryServiceListener {

    private final InventoryService inventoryService;

    public InventoryServiceListener(InventoryService inventoryService) {
        this.inventoryService = inventoryService;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.product.update}",
    topics = "${application.kafka.topics.inventory-service.product.update}")
    public void handleProductUpdate(@Payload ProductUpdate productUpdate,
                                    @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
                                    @Header(KafkaHeaders.OFFSET) Long offsets) {
        log.info("(handleProductUpdate)partitions: {}, offsets: {}",
                partitions,
                offsets);
        inventoryService.save(productUpdate);
    }

    @KafkaListener(groupId = "${application.kafka.group-id.payment.success}",
    topics = "${application.kafka.topics.inventory-service.inventory-product.update-quantity}")
    public void handlePaymentSuccess(@Payload PaymentSuccess paymentSuccess,
                                     @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
                                     @Header(KafkaHeaders.OFFSET) Long offsets) {
        log.info("(handlePaymentSuccess)partitions: {}, offsets: {}",
                partitions,
                offsets);
        inventoryService.handleSuccessPayment(paymentSuccess.getOrderId().toString());
    }
}
