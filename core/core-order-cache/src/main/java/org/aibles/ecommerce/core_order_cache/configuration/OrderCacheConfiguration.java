package org.aibles.ecommerce.core_order_cache.configuration;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_order_cache.repository.impl.PendingOrderCacheRepositoryImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.core.RedisTemplate;

@Configuration
public class OrderCacheConfiguration {

    @Bean
    public PendingOrderCacheRepository pendingOrderCacheRepository(
            RedisTemplate<String, Object> redisTemplate,
            ObjectMapper objectMapper) {
        return new PendingOrderCacheRepositoryImpl(redisTemplate, objectMapper);
    }
}
