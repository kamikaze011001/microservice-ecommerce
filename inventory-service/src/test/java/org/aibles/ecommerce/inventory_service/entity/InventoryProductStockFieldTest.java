package org.aibles.ecommerce.inventory_service.entity;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class InventoryProductStockFieldTest {

    @Test
    void inventoryProduct_hasStockField_defaultZero() {
        InventoryProduct product = new InventoryProduct();
        assertThat(product.getStock()).isNotNull();
        assertThat(product.getStock()).isEqualTo(0L);
    }

    @Test
    void inventoryProduct_stockCanBeSet() {
        InventoryProduct product = new InventoryProduct();
        product.setStock(60L);
        assertThat(product.getStock()).isEqualTo(60L);
    }
}
