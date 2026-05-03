package org.aibles.payment_service.service;

import org.aibles.ecommerce.common_dto.response.BaseResponse;

public interface PaymentService {

    BaseResponse purchase(String orderId);

    String handleSuccessPayment(String token);

    String handleCancelPayment(String token);
}
