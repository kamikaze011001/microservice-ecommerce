package org.aibles.ecommerce.inventory_service.service;

import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;

public interface InventoryService {

    void save(ProductUpdate productUpdate);

    InventoryProductIdsResponse list(InventoryProductIdsRequest request);

    void update(String id, Long quantity, Boolean isAdd);

    void handleSuccessPayment(String orderId);
}
