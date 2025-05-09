package org.aibles.ecommerce.inventory_service.repository.slave;

import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface SlaveProductQuantityHistoryRepo extends JpaRepository<ProductQuantityHistory, String> {

    @Query("SELECT ph.productId as productId, SUM(ph.quantity) as totalQuantity " +
            "FROM ProductQuantityHistory ph " +
            "WHERE ph.productId IN :productIds " +
            "GROUP BY ph.productId")
    List<ProductQuantitySummary> sumQuantitiesByProductIds(@Param("productIds") List<String> productIds);
}
