package org.aibles.ecommerce.inventory_service.repository.master;

import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface MasterInventoryProductRepository extends JpaRepository<InventoryProduct, String> {
    List<InventoryProduct> findByIdIn(List<String> ids);
}
