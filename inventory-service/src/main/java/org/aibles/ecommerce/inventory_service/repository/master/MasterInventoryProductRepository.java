package org.aibles.ecommerce.inventory_service.repository.master;

import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Repository
public interface MasterInventoryProductRepository extends JpaRepository<InventoryProduct, String> {
    List<InventoryProduct> findByIdIn(List<String> ids);

    /**
     * One-time / self-healing data backfill of the materialized `stock` column from the
     * append-only `product_quantity_history` ledger. Runs at inventory-service boot
     * (invoked by AvailableStockSeeder) BEFORE the Redis available counters are seeded.
     *
     * The `stock` COLUMN itself is created by Hibernate hbm2ddl.auto=update from the
     * InventoryProduct.stock field — this query only populates its DATA. Native query
     * because it correlates two tables with GREATEST/COALESCE (no clean JPQL form).
     *
     * Idempotent: stock and SUM(ledger) move together during normal operation, so this
     * is a no-op on every boot after the first deploy and reconciles any drift.
     * Returns the number of rows updated.
     *
     * `@Transactional` is required: this is a `@Modifying` query invoked from a
     * non-transactional ApplicationRunner (the seeder), so the method must open its
     * own JTA transaction or it throws TransactionRequiredException at boot.
     */
    @Modifying
    @Transactional
    @Query(value =
        "UPDATE inventory_product ip " +
        "SET ip.stock = GREATEST(0, COALESCE(" +
        "  (SELECT SUM(pqh.quantity) FROM product_quantity_history pqh WHERE pqh.product_id = ip.id), 0))",
        nativeQuery = true)
    int backfillStockFromLedger();
}
