package org.aibles.ecommerce.bff_service.exception;

import feign.FeignException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.common_dto.response.ErrorData;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.nio.charset.StandardCharsets;

/**
 * What a caller gets when a service bff calls (over Feign) answers with an error.
 *
 * <p>Before this, nothing handled {@link FeignException}, so every downstream
 * error — including a 400 for the caller's own bad input — surfaced as a raw
 * 500 from Spring's default error page, and the validation detail was lost.
 * Found by api-tests/03 Cart/add-item-invalid-400.bru: `cart:add-item` without
 * `price` got 500, while order-service had answered 400 with
 * {@code errors.price}.
 *
 * <ul>
 *   <li><b>Downstream 4xx</b> — the caller's mistake: pass it through with the
 *       downstream status and body. Every service answers with the same
 *       {@code BaseResponse} shape, so the body is already what a client of
 *       bff expects.</li>
 *   <li><b>Downstream 5xx or unreachable</b> — not the caller's fault and not
 *       bff's either: 502 Bad Gateway, without echoing internal URLs.</li>
 * </ul>
 */
@Slf4j
@RestControllerAdvice
public class DownstreamExceptionHandler {

    @ExceptionHandler(FeignException.class)
    public ResponseEntity<Object> handle(FeignException ex) {
        int status = ex.status();
        if (status >= 400 && status < 500) {
            byte[] body = ex.content();
            if (body != null && body.length > 0) {
                return ResponseEntity.status(status)
                        .contentType(MediaType.APPLICATION_JSON)
                        .body(new String(body, StandardCharsets.UTF_8));
            }
            HttpStatus resolved = HttpStatus.resolve(status);
            return ResponseEntity.status(status).body(BaseResponse.from(status,
                    resolved != null ? resolved.getReasonPhrase() : "Client Error",
                    ErrorData.of("downstream.rejected", "The request was rejected by a downstream service.")));
        }

        // status() is -1 when the call never got an HTTP answer (refused, timeout).
        log.error("downstream call failed. method={} status={}", ex.request() != null
                ? ex.request().httpMethod() + " " + ex.request().url() : "unknown", status, ex);
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(BaseResponse.from(
                HttpStatus.BAD_GATEWAY.value(), HttpStatus.BAD_GATEWAY.getReasonPhrase(),
                ErrorData.of("downstream.unavailable", "A service this request depends on is unavailable.")));
    }
}
