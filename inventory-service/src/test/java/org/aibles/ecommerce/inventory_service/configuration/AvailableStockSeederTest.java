package org.aibles.ecommerce.inventory_service.configuration;

import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.repository.InventoryProductRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.boot.DefaultApplicationArguments;

import java.util.List;

import static org.mockito.Mockito.*;

class AvailableStockSeederTest {

    private InventoryProductRepository inventoryProductRepository;
    private RedisRepository redisRepository;
    private AvailableStockSeeder seeder;

    @BeforeEach
    void setUp() {
        inventoryProductRepository = mock(InventoryProductRepository.class);
        redisRepository = mock(RedisRepository.class);
        seeder = new AvailableStockSeeder(inventoryProductRepository, redisRepository);
    }

    @Test
    void run_backfillsStockBeforeReadingProducts() throws Exception {
        when(inventoryProductRepository.findAll()).thenReturn(List.of());

        seeder.run(new DefaultApplicationArguments());

        InOrder inOrder = inOrder(inventoryProductRepository);
        inOrder.verify(inventoryProductRepository).backfillStockFromLedger();
        inOrder.verify(inventoryProductRepository).findAll();
    }

    @Test
    void run_seedsAvailableCounterForEachProduct() throws Exception {
        InventoryProduct p1 = new InventoryProduct();
        p1.setId("prod-1");
        p1.setStock(60L);

        InventoryProduct p2 = new InventoryProduct();
        p2.setId("prod-2");
        p2.setStock(15L);

        when(inventoryProductRepository.findAll()).thenReturn(List.of(p1, p2));

        seeder.run(new DefaultApplicationArguments());

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1");
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 60L);

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2");
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2", 15L);
    }

    @Test
    void run_skipsIncrForZeroStockProduct() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-zero");
        p.setStock(0L);

        when(inventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-zero");
        verify(redisRepository, never()).incr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-zero"), anyLong());
    }

    @Test
    void run_clampsNegativeStockToZero() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-negative");
        p.setStock(-5L);

        when(inventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-negative");
        verify(redisRepository, never()).incr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-negative"), anyLong());
    }

    @Test
    void run_handlesNullStockGracefully() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-null-stock");
        p.setStock(null);

        when(inventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-null-stock");
        verify(redisRepository, never()).incr(any(), anyLong());
    }

    @Test
    void run_seedsNothingInRedisWhenNoProducts() throws Exception {
        when(inventoryProductRepository.findAll()).thenReturn(List.of());

        seeder.run(new DefaultApplicationArguments());

        verify(inventoryProductRepository).backfillStockFromLedger();
        verifyNoInteractions(redisRepository);
    }
}
