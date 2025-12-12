package org.aibles.ecommerce.inventory_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_routing_db.configuration.EnableDatasourceRouting;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.aibles.ecommerce.inventory_service.service.InventoryServiceImpl;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableDatasourceRouting
@EnableCoreExceptionApi
@EnableAsync
@EnableMongoAuditing
@EnableCoreRedis
@EnableJpaAuditing
public class InventoryServiceConfiguration {

    @Bean
    public InventoryService inventoryService(MasterInventoryProductRepository masterInventoryProductRepository,
                                             SlaveInventoryProductRepository slaveInventoryProductRepository,
                                             MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo,
                                             SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo,
                                             ApplicationEventPublisher applicationEventPublisher,
                                             RedisRepository redisRepository,
                                             RedissonClient redissonClient,
                                             ProcessedPaymentEventRepository processedPaymentEventRepository) {
        return new InventoryServiceImpl(masterInventoryProductRepository,
                slaveInventoryProductRepository,
                masterProductQuantityHistoryRepo,
                slaveProductQuantityHistoryRepo,
                applicationEventPublisher,
                redisRepository,
                redissonClient,
                processedPaymentEventRepository);
    }
}
