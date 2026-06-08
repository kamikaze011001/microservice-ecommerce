package org.aibles.ecommerce.inventory_service.configuration;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;

import java.util.List;

/**
 * On inventory-service startup: (1) backfills the materialized `inventory_product.stock`
 * column from the product_quantity_history ledger, then (2) seeds the Redis
 * `available:{productId}` counters from that stock.
 *
 * Reads and writes go through the MASTER repository on purpose: the backfill writes
 * master, and the subsequent read of `stock` must see that write. Reading from a slave
 * could miss it due to replication lag and seed `available = 0`.
 *
 * On Redis loss/restart, this runner reseeds all counters from the DB floor,
 * restoring reservation capability without manual intervention.
 *
 * Wired as a manual @Bean in InventoryServiceConfiguration (no @Component).
 */
@Slf4j
public class AvailableStockSeeder implements ApplicationRunner {

    private final MasterInventoryProductRepository masterInventoryProductRepository;
    private final RedisRepository redisRepository;

    public AvailableStockSeeder(MasterInventoryProductRepository masterInventoryProductRepository,
                                RedisRepository redisRepository) {
        this.masterInventoryProductRepository = masterInventoryProductRepository;
        this.redisRepository = redisRepository;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        int backfilled = masterInventoryProductRepository.backfillStockFromLedger();
        log.info("(AvailableStockSeeder) Backfilled stock from ledger for {} rows", backfilled);

        log.info("(AvailableStockSeeder) Seeding productAvailable counters from inventory_product.stock");

        List<InventoryProduct> products = masterInventoryProductRepository.findAll();

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
