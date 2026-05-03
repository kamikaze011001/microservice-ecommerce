package org.aibles.payment_service.service;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.payment_service.dto.PaymentResponse;

public interface PaymentService {

    BaseResponse purchase(String orderId);

    String handleSuccessPayment(String token);

    String handleCancelPayment(String token);

    PaymentResponse getByOrderId(String orderId);
}
