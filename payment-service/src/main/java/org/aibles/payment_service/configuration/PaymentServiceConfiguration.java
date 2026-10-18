package org.aibles.payment_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_order_cache.configuration.EnableOrderCache;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_paypal.configuration.EnableCorePaypal;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_replica_routing.EnableReplicaRouting;
import org.aibles.payment_service.repository.PaymentRepository;
import org.aibles.payment_service.service.PaymentRecorder;
import org.aibles.payment_service.service.PaymentService;
import org.aibles.payment_service.service.PaymentServiceImpl;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.aibles.ecommerce.core_mongo_event.configuration.EnableMongoEvent;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableCoreExceptionApi
@EnableReplicaRouting
@EnableCorePaypal
@EnableCoreRedis
@EnableOrderCache
@EnableJpaAuditing
@EnableMongoAuditing
@EnableMongoEvent
@EnableAsync
public class PaymentServiceConfiguration {

    @Bean
    public PaymentRecorder paymentRecorder(PaymentRepository paymentRepository,
                                           ApplicationEventPublisher eventPublisher) {
        return new PaymentRecorder(paymentRepository, eventPublisher);
    }

    @Bean
    public PaymentService paymentService(PaypalService paypalService,
                                         PendingOrderCacheRepository pendingOrderCacheRepository,
                                         PaymentRepository paymentRepository,
                                         PaymentRecorder paymentRecorder) {
        return new PaymentServiceImpl(paypalService, pendingOrderCacheRepository, paymentRepository, paymentRecorder);
    }
}
