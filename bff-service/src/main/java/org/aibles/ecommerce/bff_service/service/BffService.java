package org.aibles.ecommerce.bff_service.service;

import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.ProductDetailBffResponse;

public interface BffService {

    ProductDetailBffResponse getProductDetail(String productId);

    OrderDetailBffResponse getOrderDetail(String userId, String orderId);
}
