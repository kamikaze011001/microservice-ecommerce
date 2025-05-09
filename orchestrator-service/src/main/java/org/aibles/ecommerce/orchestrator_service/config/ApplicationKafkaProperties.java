package org.aibles.ecommerce.orchestrator_service.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

import java.util.Map;

@ConfigurationProperties("application.kafka")
@Configuration
@Data
public class ApplicationKafkaProperties {

    private Map<String, String> topics;
}
