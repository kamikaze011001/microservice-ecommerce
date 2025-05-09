package org.aibles.order_service.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.decorators.Decorators;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsRequest;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.function.Supplier;

@Slf4j
@Service
public class InventoryGrpcClientService {

    private final InventoryServiceGrpc.InventoryServiceBlockingStub blockingStub;
    private final CircuitBreaker inventoryServiceCircuitBreaker;

    public InventoryGrpcClientService(
            InventoryServiceGrpc.InventoryServiceBlockingStub blockingStub,
            CircuitBreaker inventoryServiceCircuitBreaker) {
        this.blockingStub = blockingStub;
        this.inventoryServiceCircuitBreaker = inventoryServiceCircuitBreaker;
    }

    public org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse fetchInventoryData(List<String> productIds) {
        log.info("(fetchInventoryData) Fetching inventory data for {} products", productIds.size());

        InventoryProductIdsRequest request = InventoryProductIdsRequest.newBuilder()
                .addAllIds(productIds)
                .build();

        // Wrap gRPC call with circuit breaker
        Supplier<InventoryProductIdsResponse> grpcCallSupplier = () -> {
            try {
                return blockingStub.listInventoryProducts(request);
            } catch (StatusRuntimeException e) {
                log.error("gRPC call failed with status {}", e.getStatus());
                if (e.getStatus().getCode() == Status.Code.UNAVAILABLE) {
                    log.error("Service unavailable, this will count toward circuit breaker failure rate");
                }
                throw e;
            }
        };

        // Add fallback behavior
        Supplier<InventoryProductIdsResponse> decoratedSupplier = Decorators.ofSupplier(grpcCallSupplier)
                .withCircuitBreaker(inventoryServiceCircuitBreaker)
                .withFallback(throwable -> {
                    log.error("Circuit is open or call failed, returning empty response", throwable);
                    // Return empty response as fallback
                    return InventoryProductIdsResponse.newBuilder().build();
                })
                .decorate();

        InventoryProductIdsResponse response = decoratedSupplier.get();
        log.info("(fetchInventoryData) Received inventory data for {} products",
                response.getInventoryProductsCount());

        return convertToAppModel(response);
    }

    public org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse convertToAppModel(
            InventoryProductIdsResponse grpcResponse) {

        List<org.aibles.ecommerce.common_dto.response.InventoryProductResponse> products =
                grpcResponse.getInventoryProductsList().stream()
                        .map(product -> org.aibles.ecommerce.common_dto.response.InventoryProductResponse.builder()
                                .id(product.getId())
                                .name(product.getName())
                                .price(product.getPrice())
                                .quantity(product.getQuantity())
                                .build())
                        .toList();

        return new org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse(products);
    }
}
