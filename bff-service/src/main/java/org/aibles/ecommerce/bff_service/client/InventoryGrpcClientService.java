package org.aibles.ecommerce.bff_service.client;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsRequest;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;

import java.util.List;

@Slf4j
public class InventoryGrpcClientService {

    private final InventoryServiceGrpc.InventoryServiceBlockingStub stub;

    public InventoryGrpcClientService(InventoryServiceGrpc.InventoryServiceBlockingStub stub) {
        this.stub = stub;
    }

    public InventoryProductIdsResponse fetchInventory(List<String> productIds) {
        log.info("(fetchInventory) productIds: {}", productIds);
        InventoryProductIdsRequest request = InventoryProductIdsRequest.newBuilder()
                .addAllIds(productIds)
                .build();
        return stub.listInventoryProducts(request);
    }
}
