package org.aibles.ecommerce.core_kafka_consumer;

import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.header.internals.RecordHeaders;

import java.time.Duration;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.function.Supplier;

/**
 * Moves everything currently in {@code <topic>.DLT} back onto {@code <topic>}, byte for byte.
 *
 * - Raw bytes in, raw bytes out: no deserialization, so a record that was dead-lettered
 *   BECAUSE it could not be deserialized is replayed unchanged too.
 * - Same key, so the record lands on the same partition as its siblings.
 * - Spring's {@code kafka_dlt-*} headers are dropped; the original headers are kept.
 * - Progress is committed under a consumer group per call, so a second replay only
 *   moves dead letters that arrived since — never the same record twice.
 * - Stops at the end offsets observed when it started, so a record that fails again
 *   and is re-dead-lettered during the replay is not looped over.
 *
 * Replaying is safe because every consumer is idempotent: a record that was partly
 * applied before it failed is skipped by the consumer's own guard.
 */
@Slf4j
public class DltReplayer {

    private final Supplier<Consumer<byte[], byte[]>> consumers;
    private final Supplier<Producer<byte[], byte[]>> producers;
    private final Duration pollTimeout;

    public DltReplayer(Supplier<Consumer<byte[], byte[]>> consumers,
                       Supplier<Producer<byte[], byte[]>> producers,
                       Duration pollTimeout) {
        this.consumers = consumers;
        this.producers = producers;
        this.pollTimeout = pollTimeout;
    }

    /** @return how many dead letters were put back on {@code topic} */
    public long replay(String topic) {
        String dlt = DeadLetterTopics.of(topic);
        try (Consumer<byte[], byte[]> consumer = consumers.get();
             Producer<byte[], byte[]> producer = producers.get()) {

            List<PartitionInfo> infos = consumer.partitionsFor(dlt);
            if (infos == null || infos.isEmpty()) {
                return 0;
            }
            List<TopicPartition> partitions = infos.stream()
                    .map(p -> new TopicPartition(dlt, p.partition())).toList();
            consumer.assign(partitions);

            Map<TopicPartition, OffsetAndMetadata> committed = consumer.committed(new HashSet<>(partitions));
            for (TopicPartition tp : partitions) {
                OffsetAndMetadata done = committed.get(tp);
                if (done == null) {
                    consumer.seekToBeginning(List.of(tp));
                } else {
                    consumer.seek(tp, done.offset());
                }
            }
            Map<TopicPartition, Long> end = consumer.endOffsets(partitions);

            long replayed = 0;
            while (!reachedEnd(consumer, partitions, end)) {
                for (ConsumerRecord<byte[], byte[]> dead : consumer.poll(pollTimeout)) {
                    if (dead.offset() >= end.get(new TopicPartition(dead.topic(), dead.partition()))) {
                        continue;   // arrived after we started — leave it for the next replay
                    }
                    RecordHeaders headers = new RecordHeaders();
                    dead.headers().forEach(h -> {
                        if (!h.key().startsWith(DeadLetterTopics.DLT_HEADER_PREFIX)) {
                            headers.add(h);
                        }
                    });
                    producer.send(new ProducerRecord<>(topic, null, dead.key(), dead.value(), headers)).get();
                    replayed++;
                }
                // Commit only after every record polled so far is acknowledged by the broker.
                consumer.commitSync();
            }
            return replayed;
        } catch (ExecutionException e) {
            throw new IllegalStateException("replay of " + dlt + " stopped: broker rejected a record", e.getCause());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("replay of " + dlt + " interrupted", e);
        }
    }

    private static boolean reachedEnd(Consumer<?, ?> consumer, List<TopicPartition> partitions,
                                      Map<TopicPartition, Long> end) {
        for (TopicPartition tp : partitions) {
            if (consumer.position(tp) < end.get(tp)) {
                return false;
            }
        }
        return true;
    }
}
