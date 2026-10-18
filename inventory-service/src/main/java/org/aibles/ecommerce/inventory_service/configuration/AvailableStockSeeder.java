package org.aibles.ecommerce.inventory_service.configuration;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.repository.InventoryProductRepository;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;

import java.util.List;

/**
 * On inventory-service startup: (1) backfills the materialized `inventory_product.stock`
 * column from the product_quantity_history ledger, then (2) seeds the Redis
 * `available:{productId}` counters from that stock.
 *
 * Reads and writes go to the PRIMARY on purpose (never @ReplicaRead): the subsequent
 * read of `stock` must see the backfill's write. A replica could miss it due to
 * replication lag and seed `available = 0`.
 *
 * On Redis loss/restart, this runner reseeds all counters from the DB floor,
 * restoring reservation capability without manual intervention.
 *
 * Wired as a manual @Bean in InventoryServiceConfiguration (no @Component).
 */
@Slf4j
public class AvailableStockSeeder implements ApplicationRunner {

    private final InventoryProductRepository inventoryProductRepository;
    private final RedisRepository redisRepository;

    public AvailableStockSeeder(InventoryProductRepository inventoryProductRepository,
                                RedisRepository redisRepository) {
        this.inventoryProductRepository = inventoryProductRepository;
        this.redisRepository = redisRepository;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        int backfilled = inventoryProductRepository.backfillStockFromLedger();
        log.info("(AvailableStockSeeder) Backfilled stock from ledger for {} rows", backfilled);

        log.info("(AvailableStockSeeder) Seeding productAvailable counters from inventory_product.stock");

        List<InventoryProduct> products = inventoryProductRepository.findAll();

        for (InventoryProduct product : products) {
            long stock = product.getStock() != null ? Math.max(0L, product.getStock()) : 0L;
            String key = RedisConstant.AVAILABLE_PRODUCT_KEY + product.getId();

            redisRepository.delete(key);

            if (stock > 0) {
                redisRepository.incr(key, stock);
            }
        }

        log.info("(AvailableStockSeeder) Seeded available counters for {} products", products.size());
    }
}
