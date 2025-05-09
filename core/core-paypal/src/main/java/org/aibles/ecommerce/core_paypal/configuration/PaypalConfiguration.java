package org.aibles.ecommerce.core_paypal.configuration;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties("application.paypal")
@Data
public class PaypalConfiguration {

    private String clientId;
    private String clientSecret;
    private String baseUrl;
    private String tunnelUrl;
    private String successPath;
    private String cancelPath;
}
