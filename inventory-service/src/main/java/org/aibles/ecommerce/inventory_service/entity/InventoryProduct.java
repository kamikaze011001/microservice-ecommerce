package org.aibles.ecommerce.inventory_service.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;

@Entity
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class InventoryProduct {

    @Id
    private String id;

    private String name;

    private Double price;

    private String imageUrl;

    /**
     * Materialized available stock count. Authoritative committed stock:
     * decremented atomically at payment-success commit via a conditional
     * UPDATE (stock >= :n guard). Seeded on boot into Redis available counter.
     */
    @Builder.Default
    private Long stock = 0L;

    public static InventoryProduct from(final ProductUpdate productUpdate) {
        InventoryProduct inventoryProduct = new InventoryProduct();
        inventoryProduct.setId(productUpdate.getId().toString());
        inventoryProduct.setName(productUpdate.getName().toString());
        inventoryProduct.setPrice(productUpdate.getPrice());
        inventoryProduct.setImageUrl(productUpdate.getImageUrl() != null
                ? productUpdate.getImageUrl().toString()
                : null);
        inventoryProduct.setStock(0L);
        return inventoryProduct;
    }
}
