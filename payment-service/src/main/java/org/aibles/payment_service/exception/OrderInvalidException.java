package org.aibles.payment_service.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OrderInvalidException extends BadRequestException {

    public OrderInvalidException(String orderId) {
        setCode("payment.order.invalid");
        addParams("orderId", orderId);
    }
}
