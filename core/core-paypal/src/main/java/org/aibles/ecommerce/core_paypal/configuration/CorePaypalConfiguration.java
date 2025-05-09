package org.aibles.ecommerce.core_paypal.configuration;

import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.ecommerce.core_paypal.service.PaypalServiceImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.ResponseErrorHandler;
import org.springframework.web.client.RestTemplate;

@Configuration
public class CorePaypalConfiguration {

    @Bean
    public PaypalService paypalService(RestTemplate restTemplate, PaypalConfiguration paypalConfiguration) {
        return new PaypalServiceImpl(restTemplate, paypalConfiguration);
    }

    @Bean
    public RestTemplateErrorHandler restTemplateErrorHandler() {
        return new RestTemplateErrorHandler();
    }

    @Bean
    public ResponseErrorHandler errorHandler() {
        return new RestTemplateErrorHandler();
    }
}
