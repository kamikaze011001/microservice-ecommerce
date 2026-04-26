package org.aibles.ecommerce.bff_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.ProductDetailBffResponse;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;

import java.util.List;
import java.util.Map;

@Slf4j
public class BffServiceImpl implements BffService {

    private final ProductFeignClient productFeignClient;
    private final OrderFeignClient orderFeignClient;
    private final InventoryGrpcClientService inventoryGrpcClientService;

    public BffServiceImpl(ProductFeignClient productFeignClient,
                          OrderFeignClient orderFeignClient,
                          InventoryGrpcClientService inventoryGrpcClientService) {
        this.productFeignClient = productFeignClient;
        this.orderFeignClient = orderFeignClient;
        this.inventoryGrpcClientService = inventoryGrpcClientService;
    }

    @Override
    public ProductDetailBffResponse getProductDetail(String productId) {
        log.info("(getProductDetail) productId: {}", productId);

        Map<String, Object> productData = (Map<String, Object>) productFeignClient.getById(productId).getData();

        List<InventoryProduct> inventoryProducts = inventoryGrpcClientService.fetchInventory(List.of(productId)).getInventoryProductsList();
        long quantity = inventoryProducts.isEmpty() ? 0L : inventoryProducts.get(0).getQuantity();

        return ProductDetailBffResponse.builder()
                .id((String) productData.get("id"))
                .name((String) productData.get("name"))
                .category((String) productData.get("category"))
                .attributes((Map<String, Object>) productData.get("attributes"))
                .price(productData.get("price") != null ? ((Number) productData.get("price")).doubleValue() : null)
                .inStock(quantity > 0)
                .stockQuantity(quantity)
                .build();
    }

    @Override
    public OrderDetailBffResponse getOrderDetail(String userId, String orderId) {
        log.info("(getOrderDetail) userId: {}, orderId: {}", userId, orderId);
        BaseResponse orderResponse = orderFeignClient.getOrder(userId, orderId);
        return OrderDetailBffResponse.builder()
                .order(orderResponse.getData())
                .payment(null)
                .build();
    }
}
