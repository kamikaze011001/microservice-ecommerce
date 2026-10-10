package org.aibles.ecommerce.devbox_portal.controller;

import jakarta.validation.ConstraintViolationException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;

import java.util.Map;

/** Every error reaches the page as {@code {"error": "<one sentence>"}} with a real status. */
@Slf4j
@RestControllerAdvice
public class PortalExceptionHandler {

    @ExceptionHandler(PortalException.class)
    public ResponseEntity<Map<String, String>> portal(PortalException e) {
        if (e.status() == HttpStatus.BAD_GATEWAY) {
            log.error("platform dependency failed. reason={}", e.getMessage(), e);
        }
        return ResponseEntity.status(e.status()).body(Map.of("error", e.getMessage()));
    }

    @ExceptionHandler({IllegalArgumentException.class, ConstraintViolationException.class,
            MethodArgumentNotValidException.class, HandlerMethodValidationException.class})
    public ResponseEntity<Map<String, String>> badRequest(Exception e) {
        return ResponseEntity.badRequest().body(Map.of("error", "invalid request: " + e.getMessage()));
    }
}
