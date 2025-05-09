package org.aibles.payment_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_paypal.configuration.EnableCorePaypal;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_routing_db.configuration.EnableDatasourceRouting;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.aibles.payment_service.service.PaymentService;
import org.aibles.payment_service.service.PaymentServiceImpl;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableCoreExceptionApi
@EnableDatasourceRouting
@EnableCorePaypal
@EnableCoreRedis
@EnableJpaAuditing
@EnableMongoAuditing
@EnableAsync
public class PaymentServiceConfiguration {

    @Bean
    public PaymentService paymentService(PaypalService paypalService,
                                         RedisRepository redisRepository,
                                         MasterPaymentRepo masterPaymentRepo,
                                         ApplicationEventPublisher eventPublisher) {
        return new PaymentServiceImpl(paypalService, redisRepository, masterPaymentRepo, eventPublisher);
    }
}
