package org.aibles.ecommerce.inventory_service.grpc.server;

import io.grpc.stub.StreamObserver;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsRequest;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;
import org.aibles.ecommerce.inventory_service.service.InventoryService;

import java.util.List;

@Slf4j
public class InventoryGprcService extends InventoryServiceGrpc.InventoryServiceImplBase {

    private final InventoryService inventoryService;

    public InventoryGprcService(InventoryService inventoryService) {
        this.inventoryService = inventoryService;
    }


    @Override
    public void listInventoryProducts(InventoryProductIdsRequest request, StreamObserver<InventoryProductIdsResponse> responseObserver) {
        log.info("(listInventoryProducts)request: {}", request);

        try {
            org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest inventoryProductIdsRequest = new org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest();
            inventoryProductIdsRequest.setIds(request.getIdsList());

            org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse serviceResponse = inventoryService.list(inventoryProductIdsRequest);

            List<InventoryProduct> inventoryProductResponses = serviceResponse.getInventoryProducts().stream().map(
                    product -> InventoryProduct.newBuilder()
                            .setId(product.getId())
                            .setName(product.getName())
                            .setPrice(product.getPrice())
                            .setQuantity(product.getQuantity())
                            .build()
            ).toList();

            InventoryProductIdsResponse grpcResp = InventoryProductIdsResponse.newBuilder()
                    .addAllInventoryProducts(inventoryProductResponses)
                    .build();

            responseObserver.onNext(grpcResp);
            responseObserver.onCompleted();
            log.info("(listInventoryProducts)response: {}", grpcResp);
        } catch (Exception e) {
            log.error("(listInventoryProducts)error in grpc call", e);
            responseObserver.onError(e);
        }
    }
}
