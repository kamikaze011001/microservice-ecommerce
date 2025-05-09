package org.aibles.order_service.listener;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.order_service.service.OrderService;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

@Component
@Slf4j
public class OrderServiceListener {

    private final OrderService orderService;

    public OrderServiceListener(OrderService orderService) {
        this.orderService = orderService;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.order.update-status}", topics = "${application.kafka.topics.order-service.order.canceled-status}")
    private void handleOrderCanceled(@Payload PaymentCanceled paymentCanceled,
                                     @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
                                     @Header(KafkaHeaders.OFFSET) Long offsets) {
        log.info("(handleOrderCanceled)partitions: {}, offsets: {}",
                partitions,
                offsets);
        orderService.handleCanceledOrder(paymentCanceled.getOrderId().toString());
    }

    @KafkaListener(groupId = "${application.kafka.group-id.order.update-status}", topics = "${application.kafka.topics.order-service.order.failed-status}")
    private void handleOrderFailed(@Payload PaymentFailed paymentCanceled,
                                     @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
                                     @Header(KafkaHeaders.OFFSET) Long offsets) {
        log.info("(handleOrderFailed)partitions: {}, offsets: {}",
                partitions,
                offsets);
        orderService.handleFailedOrder(paymentCanceled.getOrderId().toString());
    }

    @KafkaListener(groupId = "${application.kafka.group-id.order.update-status}", topics = "${application.kafka.topics.order-service.order.success-status}")
    private void handleOrderSuccess(@Payload PaymentSuccess paymentCanceled,
                                     @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partitions,
                                     @Header(KafkaHeaders.OFFSET) Long offsets) {
        log.info("(handleOrderSuccess)partitions: {}, offsets: {}",
                partitions,
                offsets);
        orderService.handleSuccessOrder(paymentCanceled.getOrderId().toString());
    }
}
