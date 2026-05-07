package org.aibles.ecommerce.bff_service.service.impl;

import feign.FeignException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.PaymentFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.ProductDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.response.OrderDetailView;
import org.aibles.ecommerce.bff_service.dto.response.OrderItemView;
import org.aibles.ecommerce.bff_service.dto.response.PaymentView;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;

import java.time.LocalDateTime;
import java.util.Collections;
import java.util.List;
import java.util.Map;

@Slf4j
public class BffServiceImpl implements BffService {

    private final ProductFeignClient productFeignClient;
    private final OrderFeignClient orderFeignClient;
    private final PaymentFeignClient paymentFeignClient;
    private final InventoryGrpcClientService inventoryGrpcClientService;

    public BffServiceImpl(ProductFeignClient productFeignClient,
                          OrderFeignClient orderFeignClient,
                          PaymentFeignClient paymentFeignClient,
                          InventoryGrpcClientService inventoryGrpcClientService) {
        this.productFeignClient = productFeignClient;
        this.orderFeignClient = orderFeignClient;
        this.paymentFeignClient = paymentFeignClient;
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

        BaseResponse orderResponse;
        try {
            orderResponse = orderFeignClient.getOrder(userId, orderId);
        } catch (FeignException.NotFound e) {
            // order-service couldn't find the order — surface as 404 to the client
            // instead of bubbling Feign's exception up as 500.
            throw new NotFoundException();
        }
        Map<String, Object> orderData = (Map<String, Object>) orderResponse.getData();
        OrderDetailView orderView = mapToOrderDetailView(orderData);

        PaymentView paymentView = fetchPaymentOrNull(orderId);

        return new OrderDetailBffResponse(orderView, paymentView);
    }

    private PaymentView fetchPaymentOrNull(String orderId) {
        try {
            return paymentFeignClient.byOrderId(orderId);
        } catch (FeignException.NotFound e) {
            // Order has no payment yet (created but never checked out, or canceled before pay).
            return null;
        }
    }

    private OrderDetailView mapToOrderDetailView(Map<String, Object> data) {
        List<Map<String, Object>> rawItems = (List<Map<String, Object>>) data.getOrDefault("items", Collections.emptyList());
        List<OrderItemView> items = rawItems.stream()
                .map(this::mapToOrderItemView)
                .toList();

        String createdAtStr = (String) data.get("created_at");
        String updatedAtStr = (String) data.get("updated_at");

        return new OrderDetailView(
                (String) data.get("id"),
                (String) data.get("status"),
                (String) data.get("address"),
                (String) data.get("phone_number"),
                createdAtStr != null ? LocalDateTime.parse(createdAtStr) : null,
                updatedAtStr != null ? LocalDateTime.parse(updatedAtStr) : null,
                items
        );
    }

    private OrderItemView mapToOrderItemView(Map<String, Object> item) {
        return new OrderItemView(
                (String) item.get("id"),
                (String) item.get("product_id"),
                (String) item.get("product_name"),
                (String) item.get("image_url"),
                item.get("price") != null ? ((Number) item.get("price")).doubleValue() : null,
                item.get("quantity") != null ? ((Number) item.get("quantity")).longValue() : null
        );
    }
}
