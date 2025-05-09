package org.aibles.ecommerce.core_paypal.dto.paypal;

import lombok.Getter;

@Getter
public class PaypalRestTemplateException extends RuntimeException {

    private final int status;
    private final String code;
    private final String message;

    public PaypalRestTemplateException(int status, String code, String message) {
        this.status = status;
        this.code = code;
        this.message = message;
    }
}
