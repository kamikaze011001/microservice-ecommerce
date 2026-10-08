package org.aibles.ecommerce.core_kafka_consumer;

import io.confluent.kafka.serializers.KafkaAvroSerializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.apache.kafka.common.serialization.Serializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.serializer.DelegatingByTypeSerializer;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The producer the error handler publishes dead letters with.
 *
 * A dead letter's value is one of two things, and both must survive the trip:
 * - the record's raw bytes, when it could not be deserialized (ErrorHandlingDeserializer
 *   hands them over as byte[]) — written back verbatim, never re-wrapped as Avro "bytes";
 * - the deserialized Avro value, when the listener itself failed — re-serialized as Avro.
 *
 * Deliberately NOT a KafkaTemplate / ProducerFactory bean: Spring Boot only creates its
 * own KafkaTemplate when none exists, and the services' saga producers depend on it.
 */
public class DeadLetterTemplate implements DisposableBean {

    private final DefaultKafkaProducerFactory<String, Object> producerFactory;
    private final KafkaTemplate<String, Object> template;

    public DeadLetterTemplate(Map<String, Object> producerProperties) {
        Map<Class<?>, Serializer<?>> byType = new LinkedHashMap<>();
        byType.put(byte[].class, new ByteArraySerializer());   // checked first
        byType.put(Object.class, new KafkaAvroSerializer());   // everything else
        this.producerFactory = new DefaultKafkaProducerFactory<>(producerProperties,
                new StringSerializer(), new DelegatingByTypeSerializer(byType, true));
        this.template = new KafkaTemplate<>(producerFactory);
    }

    public KafkaTemplate<String, Object> template() {
        return template;
    }

    @Override
    public void destroy() {
        producerFactory.destroy();
    }
}
