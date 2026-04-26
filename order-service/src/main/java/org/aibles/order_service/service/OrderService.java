package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.dto.response.OrderCreatedResponse;
import org.aibles.order_service.dto.response.OrderDetailResponse;

public interface OrderService {

    OrderCreatedResponse create(String userId, OrderRequest request);

    void handleCanceledOrder(String orderId);

    void handleFailedOrder(String orderId);

    void handleSuccessOrder(String orderId);

    PagingResponse list(String userId, int page, int size);

    OrderDetailResponse get(String userId, String orderId);
}
