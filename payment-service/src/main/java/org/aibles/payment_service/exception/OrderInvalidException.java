package org.aibles.payment_service.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OrderInvalidException extends BadRequestException {

    public OrderInvalidException(String orderId) {
        addParams("orderId", orderId);
        setMessage("(orderId: " + orderId + ") is not valid");
    }
}
