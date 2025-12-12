package org.aibles.order_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_routing_db.configuration.EnableDatasourceRouting;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.repository.ProcessedPaymentEventRepository;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartItemRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartRepo;
import org.aibles.order_service.repository.slave.SlaveShoppingCartRepo;
import org.aibles.order_service.service.OrderService;
import org.aibles.order_service.service.ShoppingCartService;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.aibles.order_service.service.impl.ShoppingCartServiceImpl;
import org.redisson.api.RedissonClient;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableCoreExceptionApi
@EnableDatasourceRouting
@EnableDiscoveryClient
@EnableCoreRedis
@EnableJpaAuditing
@EnableMongoAuditing
@EnableAsync
public class OrderServiceConfiguration {

    @Bean
    public ShoppingCartService shoppingCartService(MasterShoppingCartRepo masterShoppingCartRepo,
                                                   SlaveShoppingCartRepo slaveShoppingCartRepo,
                                                   MasterShoppingCartItemRepo masterShoppingCartItemRepo) {
        return new ShoppingCartServiceImpl(masterShoppingCartRepo, slaveShoppingCartRepo, masterShoppingCartItemRepo);
    }

    @Bean
    public OrderService orderService(InventoryGrpcClientService inventoryGrpcClientService,
                                     RedisRepository redisRepository,
                                     MasterOrderRepo masterOrderRepo,
                                     MasterOrderItemRepo masterOrderItemRepo,
                                     RedissonClient redissonClient,
                                     ProcessedPaymentEventRepository processedPaymentEventRepository) {
        return new OrderServiceImpl(inventoryGrpcClientService,
                redisRepository,
                masterOrderRepo,
                masterOrderItemRepo,
                redissonClient,
                processedPaymentEventRepository);
    }
}
