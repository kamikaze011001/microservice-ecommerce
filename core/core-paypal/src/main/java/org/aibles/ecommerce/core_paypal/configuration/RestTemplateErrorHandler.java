package org.aibles.ecommerce.core_paypal.configuration;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalErrorResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRestTemplateException;
import org.springframework.http.HttpStatus;
import org.springframework.http.client.ClientHttpResponse;
import org.springframework.web.client.ResponseErrorHandler;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

@Slf4j
public class RestTemplateErrorHandler implements ResponseErrorHandler {

    @Override
    public boolean hasError(ClientHttpResponse response) throws IOException {
        return response.getStatusCode().is5xxServerError() ||
                response.getStatusCode().is4xxClientError();
    }

    @Override
    public void handleError(ClientHttpResponse response) throws IOException {
        ObjectMapper mapper = new ObjectMapper();
        String responseStr = new String(response.getBody().readAllBytes(), StandardCharsets.UTF_8);
        if (!response.getStatusCode().equals(HttpStatus.UNAUTHORIZED)) {
            PaypalErrorResponse errorResponse = mapper.readValue(responseStr, PaypalErrorResponse.class);
            throw new PaypalRestTemplateException(
                    response.getStatusCode().value(),
                    errorResponse.getName(),
                    errorResponse.getMessage());
        }
        throw new PaypalRestTemplateException(response.getStatusCode().value(),
                response.getStatusText(),
                "You are not authorized to perform this request");
    }
}
