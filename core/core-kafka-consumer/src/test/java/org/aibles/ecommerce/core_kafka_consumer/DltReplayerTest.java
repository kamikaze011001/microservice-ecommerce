package org.aibles.ecommerce.core_kafka_consumer;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.MockConsumer;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.consumer.OffsetResetStrategy;
import org.apache.kafka.clients.producer.MockProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.Node;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.header.internals.RecordHeader;
import org.apache.kafka.common.header.internals.RecordHeaders;
import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class DltReplayerTest {

    static final String TOPIC = "order-service.order.failed-status";
    static final String DLT = TOPIC + ".DLT";
    static final TopicPartition P0 = new TopicPartition(DLT, 0);

    MockConsumer<byte[], byte[]> consumer;
    boolean closed;
    MockProducer<byte[], byte[]> producer;
    DltReplayer replayer;

    @BeforeEach
    void setUp() {
        // close() only records the call, so the test can still read committed offsets
        consumer = new MockConsumer<>(OffsetResetStrategy.EARLIEST) {
            @Override
            public synchronized void close() {
                closed = true;
            }
        };
        producer = new MockProducer<>(true, new ByteArraySerializer(), new ByteArraySerializer());
        replayer = new DltReplayer(() -> consumer, () -> producer, Duration.ofMillis(10));
        Node node = new Node(0, "localhost", 9092);
        consumer.updatePartitions(DLT, List.of(new PartitionInfo(DLT, 0, node, new Node[]{node}, new Node[]{node})));
        consumer.updateBeginningOffsets(Map.of(P0, 0L));
    }

    @Test
    void replaysBytesAndKeyUnchanged_dropsDltHeaders_keepsTheRest() {
        byte[] poison = {0x00, (byte) 0xFF, 0x13, 0x37};   // not valid Avro — must come back verbatim
        consumer.updateEndOffsets(Map.of(P0, 1L));
        consumer.schedulePollTask(() -> consumer.addRecord(dead(0, "order-1", poison,
                new RecordHeader("kafka_dlt-exception-message", "boom".getBytes(StandardCharsets.UTF_8)),
                new RecordHeader("traceparent", "t-1".getBytes(StandardCharsets.UTF_8)))));

        long replayed = replayer.replay(TOPIC);

        assertThat(replayed).isEqualTo(1);
        ProducerRecord<byte[], byte[]> back = producer.history().get(0);
        assertThat(back.topic()).isEqualTo(TOPIC);
        assertThat(back.partition()).as("partition chosen by key hash, like the original").isNull();
        assertThat(new String(back.key(), StandardCharsets.UTF_8)).isEqualTo("order-1");
        assertThat(back.value()).isEqualTo(poison);
        assertThat(back.headers().lastHeader("kafka_dlt-exception-message")).isNull();
        assertThat(back.headers().lastHeader("traceparent")).isNotNull();
        assertThat(consumer.committed(java.util.Set.of(P0)).get(P0).offset()).isEqualTo(1);
        assertThat(closed).as("consumer closed after the replay").isTrue();
    }

    @Test
    void resumesAfterTheLastCommittedReplay_neverReplaysARecordTwice() {
        consumer.commitSync(Map.of(P0, new OffsetAndMetadata(1)));   // offset 0 was replayed earlier
        consumer.updateEndOffsets(Map.of(P0, 2L));
        consumer.schedulePollTask(() -> consumer.addRecord(dead(1, "order-2", new byte[]{1}, new RecordHeader[0])));

        long replayed = replayer.replay(TOPIC);

        assertThat(replayed).isEqualTo(1);
        assertThat(new String(producer.history().get(0).key(), StandardCharsets.UTF_8)).isEqualTo("order-2");
    }

    @Test
    void emptyDlt_replaysNothing() {
        consumer.updateEndOffsets(Map.of(P0, 0L));

        assertThat(replayer.replay(TOPIC)).isZero();
        assertThat(producer.history()).isEmpty();
    }

    @Test
    void missingDlt_replaysNothing() {
        assertThat(replayer.replay("never-dead-lettered")).isZero();
    }

    private static ConsumerRecord<byte[], byte[]> dead(long offset, String key, byte[] value, RecordHeader... headers) {
        return new ConsumerRecord<>(DLT, 0, offset, 0L, TimestampType.CREATE_TIME, 0, 0,
                key.getBytes(StandardCharsets.UTF_8), value, new RecordHeaders(headers), Optional.empty());
    }
}
