package org.aibles.ecommerce.core_kafka_consumer;

import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.test.EmbeddedKafkaBroker;
import org.springframework.kafka.test.context.EmbeddedKafka;
import org.springframework.kafka.test.utils.KafkaTestUtils;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

/**
 * The whole error path against a real (embedded) broker, with the same consumer
 * settings the services use: ErrorHandlingDeserializer → KafkaAvroDeserializer
 * (mock schema registry), the shared error handler, and the DLT publisher.
 */
@SpringBootTest(classes = KafkaConsumerResilienceIT.App.class, properties = {
        "spring.kafka.bootstrap-servers=${spring.embedded.kafka.brokers}",
        "spring.kafka.properties.schema.registry.url=mock://resilience-it",
        "spring.kafka.producer.key-serializer=org.apache.kafka.common.serialization.StringSerializer",
        "spring.kafka.producer.value-serializer=io.confluent.kafka.serializers.KafkaAvroSerializer",
        "spring.kafka.consumer.key-deserializer=org.apache.kafka.common.serialization.StringDeserializer",
        "spring.kafka.consumer.value-deserializer=org.springframework.kafka.support.serializer.ErrorHandlingDeserializer",
        "spring.kafka.consumer.properties.spring.deserializer.value.delegate.class=io.confluent.kafka.serializers.KafkaAvroDeserializer",
        "spring.kafka.consumer.properties.partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor",
        "spring.kafka.consumer.auto-offset-reset=earliest",
        "application.kafka.retry.max-retries=2",
        "application.kafka.retry.initial-interval-ms=10",
        "application.kafka.retry.max-interval-ms=20"
})
@EmbeddedKafka(partitions = 3, topics = {KafkaConsumerResilienceIT.TOPIC, KafkaConsumerResilienceIT.DLT})
class KafkaConsumerResilienceIT {

    static final String TOPIC = "it.orders";
    static final String DLT = TOPIC + ".DLT";
    static final Schema SCHEMA = new Schema.Parser().parse(
            "{\"type\":\"record\",\"name\":\"ItOrder\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}");

    @Autowired KafkaTemplate<String, Object> kafkaTemplate;
    @Autowired EmbeddedKafkaBroker broker;
    @Autowired Listener listener;
    @Autowired DltReplayer replayer;

    @Test
    void listenerFailure_isRetriedInPlace_thenDeadLettered_andTheKeyKeepsFlowing() throws Exception {
        kafkaTemplate.send(TOPIC, "order-boom", order("boom")).get();
        kafkaTemplate.send(TOPIC, "order-boom", order("after-boom")).get();   // same key → same partition

        ConsumerRecord<byte[], byte[]> dead = awaitDeadLetter("order-boom");
        // 1 delivery + 2 retries, all before anything else on that partition
        assertThat(listener.attemptsFor("boom")).isEqualTo(3);
        assertThat(header(dead, "kafka_dlt-exception-message")).contains("downstream down");
        // the record after the poison one was not overtaken and still got processed
        await().atMost(10, TimeUnit.SECONDS).until(() -> listener.processed.contains("after-boom"));
        assertThat(listener.processed.indexOf("after-boom")).isGreaterThanOrEqualTo(0);
    }

    @Test
    void undeserializableRecord_skipsRetries_andIsDeadLetteredByteForByte() throws Exception {
        byte[] garbage = "definitely not avro".getBytes(StandardCharsets.UTF_8);
        try (KafkaProducer<byte[], byte[]> raw = new KafkaProducer<>(Map.of(
                "bootstrap.servers", broker.getBrokersAsString(),
                "key.serializer", ByteArraySerializer.class, "value.serializer", ByteArraySerializer.class))) {
            raw.send(new ProducerRecord<>(TOPIC, "order-garbage".getBytes(StandardCharsets.UTF_8), garbage)).get();
        }

        ConsumerRecord<byte[], byte[]> dead = awaitDeadLetter("order-garbage");

        assertThat(dead.value()).as("raw bytes, not re-wrapped as Avro").isEqualTo(garbage);
        assertThat(header(dead, "kafka_dlt-exception-fqcn")).contains("DeserializationException");
    }

    @Test
    void replay_putsDeadLettersBackOnTheOriginalTopic() throws Exception {
        kafkaTemplate.send(TOPIC, "order-replay", order("boom")).get();
        awaitDeadLetter("order-replay");
        int before = listener.attemptsFor("boom");

        long replayed = replayer.replay(TOPIC);

        assertThat(replayed).isGreaterThanOrEqualTo(1);
        // the listener sees the replayed record again (it still fails, so it is retried again)
        await().atMost(15, TimeUnit.SECONDS).until(() -> listener.attemptsFor("boom") > before);
    }

    private ConsumerRecord<byte[], byte[]> awaitDeadLetter(String key) {
        Map<String, Object> props = KafkaTestUtils.consumerProps("dlt-reader-" + key, "false", broker);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        try (Consumer<String, byte[]> reader = new DefaultKafkaConsumerFactory<>(props,
                new StringDeserializer(), new ByteArrayDeserializer()).createConsumer()) {
            broker.consumeFromAnEmbeddedTopic(reader, DLT);
            long deadline = System.currentTimeMillis() + 20_000;
            while (System.currentTimeMillis() < deadline) {
                for (ConsumerRecord<String, byte[]> r : reader.poll(Duration.ofMillis(500))) {
                    if (key.equals(r.key())) {
                        return new ConsumerRecord<>(r.topic(), r.partition(), r.offset(), r.timestamp(),
                                r.timestampType(), 0, 0, r.key().getBytes(StandardCharsets.UTF_8), r.value(),
                                r.headers(), r.leaderEpoch());
                    }
                }
            }
        }
        throw new AssertionError("no dead letter for key " + key + " within 20 s");
    }

    private static String header(ConsumerRecord<?, ?> record, String name) {
        var h = record.headers().lastHeader(name);
        return h == null ? null : new String(h.value(), StandardCharsets.UTF_8);
    }

    private static GenericRecord order(String id) {
        GenericRecord r = new GenericData.Record(SCHEMA);
        r.put("id", id);
        return r;
    }

    @Configuration
    @EnableAutoConfiguration
    @EnableKafkaConsumerResilience
    static class App {
        @Bean
        Listener listener() {
            return new Listener();
        }
    }

    static class Listener {
        final List<String> processed = new CopyOnWriteArrayList<>();
        final List<String> attempts = new CopyOnWriteArrayList<>();

        @KafkaListener(topics = TOPIC, groupId = "resilience-it")
        void on(GenericRecord order) {
            String id = order.get("id").toString();
            attempts.add(id);
            if ("boom".equals(id)) {
                throw new IllegalStateException("downstream down");
            }
            processed.add(id);
        }

        int attemptsFor(String id) {
            return (int) attempts.stream().filter(id::equals).count();
        }
    }
}
