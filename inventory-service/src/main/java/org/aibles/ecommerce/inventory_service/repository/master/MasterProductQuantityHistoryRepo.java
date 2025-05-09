package org.aibles.ecommerce.inventory_service.repository.master;

import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterProductQuantityHistoryRepo extends JpaRepository<ProductQuantityHistory, String> {
}
