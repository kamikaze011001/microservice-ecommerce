package org.aibles.order_service.service.impl;

import lombok.Builder;
import lombok.Getter;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;

import java.util.Map;

/**
 * Value object that encapsulates the result of inventory validation and reservation.
 * Contains all data needed to create an order after successful reservation.
 */
@Getter
@Builder
public class InventoryReservationResult {

    /**
     * The original response from inventory service containing product details.
     */
    private final InventoryProductIdsResponse inventoryResponse;

    /**
     * Map of product ID to price.
     * All prices are guaranteed to be non-null after validation.
     */
    private final Map<String, Double> priceMap;

    /**
     * The total price of all products in the order.
     * Calculated as sum of (price * quantity) for all products.
     */
    private final double totalOrderPrice;

    /**
     * Map of product ID to reserved quantity.
     * These quantities have been atomically reserved in Redis.
     */
    private final Map<String, Long> reservedQuantities;
}
