package org.aibles.ecommerce.core_kafka_consumer;

import org.springframework.context.annotation.Import;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Blocking retry → {@code <topic>.DLT} for every @KafkaListener, plus the
 * {@code dltreplay} actuator endpoint. Pair it with the consumer YAML in each service:
 * ErrorHandlingDeserializer around the Avro deserializer (so a bad record reaches the
 * error handler instead of failing every poll) and the cooperative-sticky assignor.
 */
@Import(KafkaConsumerResilienceConfiguration.class)
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface EnableKafkaConsumerResilience {
}
