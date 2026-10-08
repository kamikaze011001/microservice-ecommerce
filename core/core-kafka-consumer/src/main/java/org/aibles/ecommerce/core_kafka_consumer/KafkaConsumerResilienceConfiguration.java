package org.aibles.ecommerce.core_kafka_consumer;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.kafka.KafkaProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.listener.CommonErrorHandler;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.kafka.support.ExponentialBackOffWithMaxRetries;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

/**
 * Error handling for every @KafkaListener in the service. Spring Boot wires a single
 * {@link CommonErrorHandler} bean into its default listener container factory.
 *
 * On a listener exception the record is retried IN PLACE (blocking) with exponential
 * backoff, then published to {@code <topic>.DLT} on the same partition number and its
 * offset committed. Blocking is the point: non-blocking retry topics (@RetryableTopic)
 * let later records of the same key overtake the failed one, breaking per-order order.
 * The cost is that one poison record stalls its partition for the retry window (~15 s
 * by default), well inside max.poll.interval.ms (5 min).
 *
 * Exceptions that can never succeed on retry — DeserializationException,
 * MessageConversionException, ConversionException, MethodArgumentResolutionException,
 * NoSuchMethodException, ClassCastException — skip the retries and go straight to the
 * DLT (DefaultErrorHandler's built-in not-retryable list).
 *
 * DLTs need at least as many partitions as their source topic (same partition number);
 * topics.txt gives them 12.
 */
@Configuration
public class KafkaConsumerResilienceConfiguration {

    @Bean
    public DeadLetterTemplate deadLetterTemplate(KafkaProperties kafkaProperties) {
        return new DeadLetterTemplate(kafkaProperties.buildProducerProperties(null));
    }

    @Bean
    public CommonErrorHandler kafkaErrorHandler(
            DeadLetterTemplate deadLetterTemplate,
            @Value("${application.kafka.retry.max-retries:4}") int maxRetries,
            @Value("${application.kafka.retry.initial-interval-ms:1000}") long initialIntervalMs,
            @Value("${application.kafka.retry.max-interval-ms:10000}") long maxIntervalMs) {
        DeadLetterPublishingRecoverer recoverer = new DeadLetterPublishingRecoverer(deadLetterTemplate.template(),
                (record, ex) -> new TopicPartition(DeadLetterTopics.of(record.topic()), record.partition()));

        ExponentialBackOffWithMaxRetries backOff = new ExponentialBackOffWithMaxRetries(maxRetries);
        backOff.setInitialInterval(initialIntervalMs);
        backOff.setMultiplier(2.0);
        backOff.setMaxInterval(maxIntervalMs);

        return new DefaultErrorHandler(recoverer, backOff);
    }

    @Bean
    public DltReplayer dltReplayer(KafkaProperties kafkaProperties) {
        Map<String, Object> consumerProps = new HashMap<>(kafkaProperties.buildConsumerProperties(null));
        consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, ByteArrayDeserializer.class);
        consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, ByteArrayDeserializer.class);
        consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "dlt-replay");
        consumerProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
        consumerProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        Map<String, Object> producerProps = new HashMap<>(kafkaProperties.buildProducerProperties(null));
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class);

        return new DltReplayer(
                () -> new KafkaConsumer<>(consumerProps),
                () -> new KafkaProducer<>(producerProps),
                Duration.ofSeconds(2));
    }

    @Bean
    public DltReplayEndpoint dltReplayEndpoint(DltReplayer dltReplayer, KafkaListenerEndpointRegistry registry) {
        return new DltReplayEndpoint(dltReplayer, registry);
    }
}
