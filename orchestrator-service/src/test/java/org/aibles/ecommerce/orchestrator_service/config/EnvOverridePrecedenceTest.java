package org.aibles.ecommerce.orchestrator_service.config;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Configuration;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The devbox gives each env its own topic names, group ids and databases by
 * setting SPRING_APPLICATION_JSON (rendered by the apps chart from the env
 * repo's springConfig) on top of the shared Vault config.
 *
 * Why JSON and not plain env vars: topics bind into a Map whose keys contain
 * dots AND dashes. APPLICATION_KAFKA_TOPICS_ORDER_SERVICE_ORDER_FAILED_STATUS
 * would bind the key "order.service.order.failed.status" — a new entry next to
 * Vault's, which keeps winning. JSON keeps the key exact.
 *
 * This pins the three things the design relies on: JSON beats config data
 * (Vault's tier), it overrides map entries one by one instead of replacing the
 * map, and @Value placeholders (@KafkaListener groupId/topics) see it too.
 */
class EnvOverridePrecedenceTest {

    @Configuration
    @EnableConfigurationProperties(ApplicationKafkaProperties.class)
    static class Ctx {
    }

    @AfterEach
    void clear() {
        System.clearProperty("spring.application.json");
    }

    private ConfigurableApplicationContext start() {
        return new SpringApplicationBuilder(Ctx.class)
                .web(WebApplicationType.NONE)
                .properties("spring.config.name=env-override-test")
                .run();
    }

    @Test
    void springApplicationJsonOverridesVaultTierMapEntriesKeyByKey() {
        System.setProperty("spring.application.json", """
                {"application":{"kafka":{
                  "topics":{"order-service.order.failed-status":"preview-x.order-service.order.failed-status"},
                  "group-id":{"mongo.event":"preview-x.mongo-event-group"}}}}
                """);

        try (ConfigurableApplicationContext ctx = start()) {
            var topics = ctx.getBean(ApplicationKafkaProperties.class).getTopics();

            assertThat(topics)
                    .as("the dashed+dotted key is overridden exactly, not added as a look-alike")
                    .containsEntry("order-service.order.failed-status", "preview-x.order-service.order.failed-status")
                    .as("entries the JSON doesn't mention keep the Vault-tier value")
                    .containsEntry("order-service.order.canceled-status", "order-service.order.canceled-status")
                    .containsEntry("mongo.event", "ecommerce_db.ecommerce_inventory.event")
                    .hasSize(3);
            assertThat(ctx.getEnvironment().resolvePlaceholders("${application.kafka.group-id.mongo.event}"))
                    .as("@KafkaListener(groupId = \"${...}\") resolves the override")
                    .isEqualTo("preview-x.mongo-event-group");
        }
    }

    @Test
    void withoutJsonTheVaultTierValuesStand() {
        try (ConfigurableApplicationContext ctx = start()) {
            assertThat(ctx.getBean(ApplicationKafkaProperties.class).getTopics())
                    .containsEntry("order-service.order.failed-status", "order-service.order.failed-status");
            assertThat(ctx.getEnvironment().resolvePlaceholders("${application.kafka.group-id.mongo.event}"))
                    .isEqualTo("mongo-event-group");
        }
    }
}
