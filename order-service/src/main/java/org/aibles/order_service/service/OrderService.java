package org.aibles.order_service.service;

import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.dto.response.OrderCreatedResponse;

public interface OrderService {

    OrderCreatedResponse create(String userId, OrderRequest request);

    void handleCanceledOrder(String orderId);

    void handleFailedOrder(String orderId);

    void handleSuccessOrder(String orderId);
}
