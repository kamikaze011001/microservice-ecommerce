package org.aibles.ecommerce.core_kafka_consumer;

/** Naming rule shared by the error handler, the replayer and topics.txt. */
public final class DeadLetterTopics {

    public static final String SUFFIX = ".DLT";

    /** Header names Spring's DeadLetterPublishingRecoverer adds; stripped on replay. */
    public static final String DLT_HEADER_PREFIX = "kafka_dlt-";

    private DeadLetterTopics() {
    }

    public static String of(String topic) {
        return topic + SUFFIX;
    }
}
