package org.aibles.ecommerce.inventory_service.service;

import java.util.Map;

import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.PagingResponse;

public interface InventoryService {

    void save(ProductUpdate productUpdate);

    InventoryProductIdsResponse list(InventoryProductIdsRequest request);

    void update(String id, Long quantity, Boolean isAdd);

    /** Applies a paid order to stock; {@code lines} = productId → quantity from the event (may be empty for old events). */
    void handleSuccessPayment(String orderId, Map<String, Long> lines);

    PagingResponse listAll(int page, int size);
}
