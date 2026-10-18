package org.aibles.order_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_order_cache.configuration.EnableOrderCache;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_replica_routing.EnableReplicaRouting;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.repository.OrderItemRepository;
import org.aibles.order_service.repository.OrderRepository;
import org.aibles.order_service.repository.ShoppingCartItemRepository;
import org.aibles.order_service.repository.ShoppingCartRepository;
import org.aibles.order_service.service.OrderService;
import org.aibles.order_service.service.ShoppingCartService;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.aibles.order_service.service.impl.ShoppingCartServiceImpl;
import org.redisson.api.RedissonClient;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.aibles.ecommerce.core_kafka_consumer.EnableKafkaConsumerResilience;
import org.aibles.ecommerce.core_mongo_event.configuration.EnableMongoEvent;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableCoreExceptionApi
@EnableReplicaRouting
@EnableDiscoveryClient
@EnableCoreRedis
@EnableOrderCache
@EnableJpaAuditing
@EnableMongoAuditing
@EnableMongoEvent
@EnableKafkaConsumerResilience
@EnableAsync
public class OrderServiceConfiguration {

    @Bean
    public ShoppingCartService shoppingCartService(ShoppingCartRepository shoppingCartRepository,
                                                   ShoppingCartItemRepository shoppingCartItemRepository) {
        return new ShoppingCartServiceImpl(shoppingCartRepository, shoppingCartItemRepository);
    }

    @Bean
    public OrderService orderService(InventoryGrpcClientService inventoryGrpcClientService,
                                     RedisRepository redisRepository,
                                     PendingOrderCacheRepository pendingOrderCacheRepository,
                                     OrderRepository orderRepository,
                                     OrderItemRepository orderItemRepository,
                                     RedissonClient redissonClient,
                                     ApplicationEventPublisher eventPublisher) {
        return new OrderServiceImpl(inventoryGrpcClientService,
                redisRepository,
                pendingOrderCacheRepository,
                orderRepository,
                orderItemRepository,
                redissonClient,
                eventPublisher);
    }
}
