package org.aibles.order_service.service;

import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.dto.response.ShoppingCartListResponse;

public interface ShoppingCartService {

    void addItem(String userId, ShoppingCartAddRequest request);

    ShoppingCartListResponse list(String userId);

    void updateItem(String itemId, Long quantity);

    void deleteItem(String itemId);
}
