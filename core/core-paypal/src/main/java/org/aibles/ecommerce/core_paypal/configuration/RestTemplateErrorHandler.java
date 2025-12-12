package org.aibles.ecommerce.core_paypal.configuration;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalErrorResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRestTemplateException;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.client.ClientHttpResponse;
import org.springframework.web.client.ResponseErrorHandler;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

@Slf4j
public class RestTemplateErrorHandler implements ResponseErrorHandler {

    /**
     * DEFENSIVE FIX: Added try-catch to handle HttpRetryException from streaming mode
     *
     * Issue: When HttpURLConnection is in streaming mode and encounters authentication
     * errors, calling getStatusCode() triggers getResponseCode() which may throw
     * HttpRetryException: "cannot retry due to server authentication, in streaming mode"
     *
     * Solution: Catch IOException and treat as error. This works in conjunction with
     * BufferingClientHttpRequestFactory to handle authentication retries gracefully.
     */
    @Override
    public boolean hasError(ClientHttpResponse response) throws IOException {
        try {
            HttpStatusCode statusCode = response.getStatusCode();
            return statusCode.is5xxServerError() || statusCode.is4xxClientError();
        } catch (IOException e) {
            // Handle streaming mode authentication retry exception
            log.error("(hasError) Error reading response status code (likely streaming mode auth issue): {}",
                    e.getMessage());
            // Treat as error so handleError() can process it
            return true;
        }
    }

    /**
     * CRITICAL FIX: Improved error handling to expose root cause
     *
     * The HttpRetryException "cannot retry due to server authentication, in streaming mode"
     * is a SYMPTOM masking the real problem: PayPal returned 401 (invalid credentials).
     *
     * This happens when:
     * 1. PAYPAL_CLIENT_ID or PAYPAL_CLIENT_SECRET is wrong/expired
     * 2. PayPal returns 401 Unauthorized
     * 3. HttpURLConnection tries to retry authentication
     * 4. Retry fails in streaming mode → HttpRetryException thrown
     * 5. Real PayPal error message is lost
     *
     * Solution: Log the actual error before trying to read response details.
     */
    @Override
    public void handleError(ClientHttpResponse response) throws IOException {
        ObjectMapper mapper = new ObjectMapper();

        HttpStatusCode statusCode = null;
        String responseBody = null;

        // Try to read status code and response body
        try {
            statusCode = response.getStatusCode();
            log.error("(handleError) PayPal returned error status: {}", statusCode);
        } catch (IOException e) {
            log.error("(handleError) Could not read status code: {}", e.getMessage());
        }

        try {
            responseBody = new String(response.getBody().readAllBytes(), StandardCharsets.UTF_8);
            log.error("(handleError) PayPal response body: {}", responseBody);
        } catch (IOException e) {
            log.error("(handleError) Could not read response body: {}", e.getMessage());
        }

        // If we couldn't read anything, throw generic error
        if (statusCode == null) {
            throw new PaypalRestTemplateException(
                    401,
                    "AUTHENTICATION_ERROR",
                    "PayPal authentication failed. This usually means PAYPAL_CLIENT_ID or PAYPAL_CLIENT_SECRET is invalid/expired. " +
                    "Check your environment variables and PayPal sandbox credentials.");
        }

        // Parse and throw specific error
        if (!statusCode.equals(HttpStatus.UNAUTHORIZED) && responseBody != null) {
            try {
                PaypalErrorResponse errorResponse = mapper.readValue(responseBody, PaypalErrorResponse.class);
                throw new PaypalRestTemplateException(
                        statusCode.value(),
                        errorResponse.getName(),
                        errorResponse.getMessage());
            } catch (Exception e) {
                log.warn("(handleError) Could not parse PayPal error response: {}", e.getMessage());
            }
        }

        // 401 or couldn't parse response
        throw new PaypalRestTemplateException(
                statusCode.value(),
                "UNAUTHORIZED",
                "PayPal authentication failed. Check PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET environment variables.");
    }
}
