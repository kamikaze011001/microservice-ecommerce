package org.aibles.ecommerce.inventory_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_order_cache.configuration.EnableOrderCache;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_replica_routing.EnableReplicaRouting;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.InventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.ProductQuantityHistoryRepository;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.aibles.ecommerce.inventory_service.service.InventoryServiceImpl;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.aibles.ecommerce.core_kafka_consumer.EnableKafkaConsumerResilience;
import org.aibles.ecommerce.core_mongo_event.configuration.EnableMongoEvent;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableReplicaRouting
@EnableCoreExceptionApi
@EnableAsync
@EnableMongoAuditing
@EnableMongoEvent
@EnableKafkaConsumerResilience
@EnableCoreRedis
@EnableOrderCache
@EnableJpaAuditing
public class InventoryServiceConfiguration {

    @Bean
    public AvailableStockSeeder availableStockSeeder(
            InventoryProductRepository inventoryProductRepository,
            RedisRepository redisRepository) {
        return new AvailableStockSeeder(inventoryProductRepository, redisRepository);
    }

    @Bean
    public InventoryService inventoryService(InventoryProductRepository inventoryProductRepository,
                                             ProductQuantityHistoryRepository productQuantityHistoryRepository,
                                             ApplicationEventPublisher applicationEventPublisher,
                                             RedisRepository redisRepository,
                                             PendingOrderCacheRepository pendingOrderCacheRepository,
                                             RedissonClient redissonClient,
                                             ProcessedPaymentEventRepository processedPaymentEventRepository) {
        return new InventoryServiceImpl(inventoryProductRepository,
                productQuantityHistoryRepository,
                applicationEventPublisher,
                redisRepository,
                pendingOrderCacheRepository,
                redissonClient,
                processedPaymentEventRepository);
    }
}
