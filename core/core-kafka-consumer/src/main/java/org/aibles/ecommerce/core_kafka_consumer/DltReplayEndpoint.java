package org.aibles.ecommerce.core_kafka_consumer;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.actuate.endpoint.InvalidEndpointRequestException;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.Selector;
import org.springframework.boot.actuate.endpoint.annotation.WriteOperation;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;

import java.util.Arrays;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * {@code POST /actuator/dltreplay/{topic}} on the management port (internal only — the
 * gateway never routes /actuator/**). Replays {@code <topic>.DLT} back onto {@code <topic>}.
 *
 * Only topics THIS service consumes are accepted, so an operator can't use one service
 * to push another service's dead letters around.
 * Run it once the cause of the failures is fixed — otherwise the records just fail and
 * return to the DLT.
 */
@Slf4j
@Endpoint(id = "dltreplay")
public class DltReplayEndpoint {

    private final DltReplayer replayer;
    private final KafkaListenerEndpointRegistry registry;

    public DltReplayEndpoint(DltReplayer replayer, KafkaListenerEndpointRegistry registry) {
        this.replayer = replayer;
        this.registry = registry;
    }

    @WriteOperation
    public Map<String, Object> replay(@Selector String topic) {
        Set<String> consumed = consumedTopics();
        if (!consumed.contains(topic)) {
            throw new InvalidEndpointRequestException(
                    "this service does not consume " + topic + "; it consumes " + consumed, "unknown topic");
        }
        long replayed = replayer.replay(topic);
        log.warn("dead letters replayed. topic={} count={}", topic, replayed);
        return Map.of("topic", topic, "deadLetterTopic", DeadLetterTopics.of(topic), "replayed", replayed);
    }

    private Set<String> consumedTopics() {
        return registry.getListenerContainers().stream()
                .map(c -> c.getContainerProperties().getTopics())
                .filter(Objects::nonNull)
                .flatMap(Arrays::stream)
                .collect(Collectors.toSet());
    }
}
