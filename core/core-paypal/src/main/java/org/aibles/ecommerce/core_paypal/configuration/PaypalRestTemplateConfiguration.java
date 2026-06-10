package org.aibles.ecommerce.core_paypal.configuration;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestTemplate;

@Configuration
public class PaypalRestTemplateConfiguration {

    private final RestTemplateErrorHandler errorHandler;

    public PaypalRestTemplateConfiguration(RestTemplateErrorHandler errorHandler) {
        this.errorHandler = errorHandler;
    }

    @Bean
    public RestTemplate paypalRestTemplate() {
        // No timeout = a stalled PayPal call parks a Tomcat thread forever.
        // Timeouts surface as ResourceAccessException (NOT PaypalRestTemplateException
        // — the error handler only sees responses that arrived); callers must catch it.
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(3_000);
        requestFactory.setReadTimeout(10_000);
        RestTemplate restTemplate = new RestTemplate(requestFactory);
        restTemplate.setErrorHandler(errorHandler);
        return restTemplate;
    }
}
