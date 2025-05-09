package org.aibles.ecommerce.core_exception_api.configuration;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

import java.util.ArrayList;
import java.util.List;

@Configuration
@ConfigurationProperties(prefix = "application.i18n")
@Data
public class MessageResourcesProperties {
  private List<String> resources =  new ArrayList<>();
}
