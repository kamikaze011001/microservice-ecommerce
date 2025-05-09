package org.aibles.payment_service.service;

import org.aibles.ecommerce.common_dto.response.BaseResponse;

public interface PaymentService {

    BaseResponse purchase(String orderId);

    void handleSuccessPayment(String token);

    void handleCancelPayment(String token);
}
