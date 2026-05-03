package org.aibles.ecommerce.bff_service.service;

import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.common_dto.response.BaseResponse;

import java.util.Map;

public interface CartBffService {
    CartView getCart(String userId);
    BaseResponse addItem(String userId, Map<String, Object> body);
    BaseResponse updateItem(Map<String, Object> body);
    BaseResponse deleteItem(String itemId);
}
