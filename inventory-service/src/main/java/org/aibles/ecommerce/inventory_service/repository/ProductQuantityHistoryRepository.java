package org.aibles.ecommerce.inventory_service.repository.master;

import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface MasterProductQuantityHistoryRepo extends JpaRepository<ProductQuantityHistory, String> {

    // Authoritative (master) stock SUM. Used for the reservation-gating read so
    // the atomic Lua reserve checks current stock, not a lagging slave replica —
    // an async-replica stale read here over-permitted reservations and oversold
    // stock to negative under load. Same query as the slave repo's; routed to
    // master on purpose. Browse/display reads stay on the slave.
    @Query("SELECT ph.productId as productId, SUM(ph.quantity) as totalQuantity " +
            "FROM ProductQuantityHistory ph " +
            "WHERE ph.productId IN :productIds " +
            "GROUP BY ph.productId")
    List<ProductQuantitySummary> sumQuantitiesByProductIds(@Param("productIds") List<String> productIds);
}
