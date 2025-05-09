package org.aibles.ecommerce.product_service.configuration;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

import java.util.Map;

@Configuration
@ConfigurationProperties("application.kafka")
@Data
public class ApplicationKafkaProperties {

    private Map<String, String> topics;
}
