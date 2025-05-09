package org.aibles.ecommerce.product_service.listener;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

import java.util.Optional;

@Component
@Slf4j
public class ProductQuantityUpdatedListener {

    private final ProductQuantityHistoryRepo productQuantityHistoryRepo;

    public ProductQuantityUpdatedListener(ProductQuantityHistoryRepo productQuantityHistoryRepo) {
        this.productQuantityHistoryRepo = productQuantityHistoryRepo;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.product-service.product.update-quantity}",
    topics = "${application.kafka.topics.product-service.product.update-quantity}")
    public void handle(
            @Payload ProductQuantityUpdated productQuantityUpdated,
            @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
            @Header(KafkaHeaders.OFFSET) Long offset) {
        log.info("(handle)payload : {}, partitions : {}, offset : {}", productQuantityUpdated, partitions, offset);

        ProductQuantityHistory productQuantityHistory = ProductQuantityHistory.builder()
                .productId(productQuantityUpdated.getProductId().toString())
                .quantity(productQuantityUpdated.getQuantity())
                .build();
        productQuantityHistoryRepo.save(productQuantityHistory);
    }
}
