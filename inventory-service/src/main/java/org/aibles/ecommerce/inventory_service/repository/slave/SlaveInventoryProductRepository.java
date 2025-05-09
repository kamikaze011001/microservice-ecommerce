package org.aibles.ecommerce.inventory_service.repository.slave;

import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface SlaveInventoryProductRepository extends JpaRepository<InventoryProduct, String> {
}
