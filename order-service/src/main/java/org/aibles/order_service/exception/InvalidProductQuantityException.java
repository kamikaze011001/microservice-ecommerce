package org.aibles.order_service.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

import java.util.List;

public class InvalidProductQuantityException extends BadRequestException {

    public InvalidProductQuantityException(List<String> invalidProductName) {
        setCode("org.aibles.order_service.exception.InvalidProductQuantity");
        addParams("productName", invalidProductName.toString());
    }
}
