package org.aibles.ecommerce.inventory_service.repository.projection;

public interface ProductQuantitySummary {

    String getProductId();
    Long getTotalQuantity();
}
