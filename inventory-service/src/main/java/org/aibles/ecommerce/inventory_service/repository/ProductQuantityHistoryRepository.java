package org.aibles.ecommerce.inventory_service.repository;

import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface ProductQuantityHistoryRepository extends JpaRepository<ProductQuantityHistory, String> {

    // Stock SUM per product. Primary by default; replica only when the caller is
    // @ReplicaRead (the display `list`). Never route a reservation-gating read to a
    // replica — a stale SUM there over-permitted reservations and oversold stock to
    // negative under load.
    @Query("SELECT ph.productId as productId, SUM(ph.quantity) as totalQuantity " +
            "FROM ProductQuantityHistory ph " +
            "WHERE ph.productId IN :productIds " +
            "GROUP BY ph.productId")
    List<ProductQuantitySummary> sumQuantitiesByProductIds(@Param("productIds") List<String> productIds);
}
