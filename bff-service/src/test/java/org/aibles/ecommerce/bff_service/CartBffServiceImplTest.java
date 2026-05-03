package org.aibles.ecommerce.bff_service;

import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.bff_service.service.impl.CartBffServiceImpl;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CartBffServiceImplTest {

    @Mock private OrderFeignClient orderFeignClient;
    @Mock private ProductFeignClient productFeignClient;
    @Mock private InventoryGrpcClientService inventoryGrpcClientService;

    private CartBffServiceImpl service() {
        return new CartBffServiceImpl(orderFeignClient, productFeignClient, inventoryGrpcClientService);
    }

    private BaseResponse cartResponse(List<Map<String, Object>> items) {
        BaseResponse r = new BaseResponse();
        r.setData(Map.of("shoppingCarts", items));
        return r;
    }

    private BaseResponse productListResponse(List<Map<String, Object>> products) {
        BaseResponse r = new BaseResponse();
        r.setData(products);
        return r;
    }

    @Test
    void getCart_emptyCart_returnsEmptyItems() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of()));
        CartView view = service().getCart("u1");
        assertThat(view.getUserId()).isEqualTo("u1");
        assertThat(view.getItems()).isEmpty();
    }

    @Test
    void getCart_normal_mergesProductAndInventory() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2)
        )));
        when(productFeignClient.listByIds(Set.of("p1"))).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder()
                .addInventoryProducts(InventoryProduct.newBuilder().setId("p1").setQuantity(10L).build())
                .build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems()).hasSize(1);
        var item = view.getItems().get(0);
        assertThat(item.getShoppingCartItemId()).isEqualTo("ci1");
        assertThat(item.getProductId()).isEqualTo("p1");
        assertThat(item.getName()).isEqualTo("Issue Nº01");
        assertThat(item.getImageUrl()).isEqualTo("http://img/p1.png");
        assertThat(item.getUnitPrice()).isEqualTo(25.0);
        assertThat(item.getQuantity()).isEqualTo(2L);
        assertThat(item.getAvailableStock()).isEqualTo(10L);
    }

    @Test
    void getCart_productMissing_dropsRow() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2),
            Map.of("id", "ci2", "productId", "p2", "price", 30.0, "quantity", 1)
        )));
        when(productFeignClient.listByIds(any())).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder()
                .addInventoryProducts(InventoryProduct.newBuilder().setId("p1").setQuantity(10L).build())
                .build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems()).hasSize(1);
        assertThat(view.getItems().get(0).getProductId()).isEqualTo("p1");
    }

    @Test
    void getCart_inventoryMissing_defaultsStockToZero() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2)
        )));
        when(productFeignClient.listByIds(any())).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder().build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems().get(0).getAvailableStock()).isEqualTo(0L);
    }
}
