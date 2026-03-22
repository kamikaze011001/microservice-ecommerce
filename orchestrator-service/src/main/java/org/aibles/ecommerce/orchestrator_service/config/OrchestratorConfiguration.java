package org.aibles.ecommerce.orchestrator_service.config;

import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@EnableCoreRedis   // provides RedissonClient bean via core-redis module
@EnableJpaAuditing
@EnableScheduling
public class OrchestratorConfiguration {
}
