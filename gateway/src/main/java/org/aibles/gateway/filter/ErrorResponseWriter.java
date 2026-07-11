package org.aibles.gateway.filter;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Writes the gateway's error JSON in the shared contract shape:
 * {@code {status, code:<HTTP reason phrase>, data:{code:<dotted>, message:<human>}}}.
 *
 * The reactive gateway can't use core-exception-api's servlet @RestControllerAdvice,
 * so the same envelope is hand-written here. Human messages are inlined (the gateway
 * does not carry core-exception-api's message bundle on its classpath).
 */
@Slf4j
public final class ErrorResponseWriter {

    // Inlined copies of the base bundle's human messages (see
    // core/core-exception-api/src/main/resources/messages.properties).
    public static final String MSG_TOKEN_MISSING = "Authentication is required.";
    public static final String MSG_TOKEN_INVALID =
            "Your session is invalid or has expired. Please sign in again.";
    public static final String MSG_FORBIDDEN =
            "You do not have permission to access this resource.";
    public static final String MSG_INTERNAL = "Something went wrong on our end. Please try again.";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private ErrorResponseWriter() {}

    /** The response body map, in contract order. Package-private for unit testing. */
    static Map<String, Object> body(HttpStatus status, String code, String message) {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("code", code);
        data.put("message", message);

        Map<String, Object> root = new LinkedHashMap<>();
        root.put("status", status.value());
        root.put("code", status.getReasonPhrase());
        root.put("data", data);
        return root;
    }

    /** Serialize {@link #body} and write it to the response, with a plain-text fallback. */
    static Mono<Void> write(ServerWebExchange exchange, HttpStatus status,
                            String code, String message) {
        exchange.getResponse().setStatusCode(status);
        exchange.getResponse().getHeaders().setContentType(MediaType.APPLICATION_JSON);
        byte[] bytes;
        try {
            bytes = MAPPER.writeValueAsString(body(status, code, message))
                    .getBytes(StandardCharsets.UTF_8);
        } catch (JsonProcessingException e) {
            log.error("(write) failed to serialize gateway error body", e);
            bytes = ("{\"status\":" + status.value() + ",\"code\":\"" + status.getReasonPhrase()
                    + "\",\"data\":{\"code\":\"common.internal_error\",\"message\":\"" + MSG_INTERNAL + "\"}}")
                    .getBytes(StandardCharsets.UTF_8);
        }
        DataBuffer buffer = exchange.getResponse().bufferFactory().wrap(bytes);
        log.warn("(write) gateway error response status={} code={}", status.value(), code);
        return exchange.getResponse().writeWith(Mono.just(buffer));
    }
}
