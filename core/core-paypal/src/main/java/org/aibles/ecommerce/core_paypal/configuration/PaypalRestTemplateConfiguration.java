package org.aibles.ecommerce.core_paypal.configuration;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestTemplate;

@Configuration
public class PaypalRestTemplateConfiguration {

    private final RestTemplateErrorHandler errorHandler;

    public PaypalRestTemplateConfiguration(RestTemplateErrorHandler errorHandler) {
        this.errorHandler = errorHandler;
    }

    @Bean
    public RestTemplate paypalRestTemplate() {
        RestTemplate restTemplate = new RestTemplate();
        restTemplate.setErrorHandler(errorHandler);
        return restTemplate;
    }
}
