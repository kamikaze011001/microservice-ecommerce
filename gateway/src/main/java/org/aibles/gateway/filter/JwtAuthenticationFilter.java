package org.aibles.gateway.filter;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.JWKSet;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import lombok.extern.slf4j.Slf4j;
import org.aibles.core_jwt_util.util.JwtUtil;
import org.aibles.ecommerce.common_dto.exception.InternalErrorException;
import org.aibles.ecommerce.common_dto.exception.UnauthorizedException;
import org.apache.http.HttpHeaders;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextImpl;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;
import reactor.util.retry.Retry;

import java.nio.charset.StandardCharsets;
import java.text.ParseException;
import java.time.Duration;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

@Slf4j
public class JwtAuthenticationFilter implements WebFilter {

    // Constants
    private static final String ERROR_CODE_FIELD_KEY = "error_code";
    private static final String BEARER_PREFIX = "Bearer ";

    // Injected properties
    private final WebClient lbWebClient;

    @Value("${application.jwk-set-uri}")
    private String jwksUri;

    @Value("${jwt.token.retry.max-attempts:3}")
    private int maxRetries;

    @Value("${jwt.token.retry.delay:500}")
    private long retryDelayMillis;

    @Value("${jwt.token.cache.refresh-minutes:30}")
    private long cacheRefreshMinutes;

    @Value("${jwt.token.cache.force-refresh-threshold:5}")
    private int forceRefreshThreshold;

    // Cache state
    private final AtomicReference<JWKSet> cachedJWKSet = new AtomicReference<>();
    private final AtomicLong lastRefreshTimestamp = new AtomicLong(0);
    private final AtomicLong failedValidationCount = new AtomicLong(0);
    private final AtomicReference<Mono<JWKSet>> currentRefreshOperation = new AtomicReference<>();

    // Scheduler for periodic tasks
    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();

    // Constructor
    public JwtAuthenticationFilter(WebClient lbWebClient) {
        this.lbWebClient = lbWebClient;
    }

    @PostConstruct
    public void init() {
        log.info("(init) Initializing JwtAuthenticationFilter with JWK cache");

        // Initial JWK fetch without blocking
        fetchAndUpdateCache()
                .subscribeOn(Schedulers.boundedElastic())
                .subscribe(
                        this::onCacheRefreshSuccess,
                        error -> log.error("(init) Error during initial JWK Set fetch: {}", error.getMessage())
                );

        // Schedule periodic refresh
        scheduler.scheduleAtFixedRate(
                this::scheduledRefresh,
                cacheRefreshMinutes,
                cacheRefreshMinutes,
                TimeUnit.MINUTES
        );

        log.info("(init) JWK cache refresh scheduled every {} minutes", cacheRefreshMinutes);
    }

    private void scheduledRefresh() {
        log.info("(scheduledRefresh) Scheduled JWK refresh triggered");
        fetchAndUpdateCache()
                .subscribeOn(Schedulers.boundedElastic())
                .subscribe(
                        this::onCacheRefreshSuccess,
                        error -> log.error("(scheduledRefresh) Error refreshing JWK Set: {}", error.getMessage())
                );
    }

    private void onCacheRefreshSuccess(JWKSet jwkSet) {
        log.info("(onCacheRefreshSuccess) JWK Set refreshed successfully with {} keys",
                jwkSet.getKeys().size());
        lastRefreshTimestamp.set(System.currentTimeMillis());
        failedValidationCount.set(0);
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        String path = request.getPath().value();
        log.debug("(filter) Processing request for path: {}", path);

        String authHeader = request.getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
        if (authHeader == null || !authHeader.startsWith(BEARER_PREFIX)) {
            log.debug("(filter) No Bearer token present, skipping authentication");
            return chain.filter(exchange);
        }

        String token = authHeader.substring(BEARER_PREFIX.length());

        return authenticateToken(token)
                .flatMap(auth -> processWithAuthentication(exchange, auth, chain))
                .onErrorResume(throwable -> handleFilterError(exchange, throwable));
    }

    private Mono<Authentication> authenticateToken(String token) {
        log.debug("(authenticateToken) Authenticating token");

        return getJWKSet()
                .flatMap(jwkSet -> validateTokenWithJWKSet(token, jwkSet))
                .onErrorResume(UnauthorizedException.class, e -> {
                    // Check if we should try with fresh keys
                    if (shouldRefreshKeysOnFailure()) {
                        log.info("(authenticateToken) Initial validation failed, attempting with fresh keys");
                        return refreshAndRetryValidation(token);
                    }
                    return Mono.error(e);
                });
    }

    private boolean shouldRefreshKeysOnFailure() {
        long timeSinceLastRefresh = System.currentTimeMillis() - lastRefreshTimestamp.get();
        long refreshThresholdMs = TimeUnit.MINUTES.toMillis(cacheRefreshMinutes / 2);
        return timeSinceLastRefresh > refreshThresholdMs;
    }

    private Mono<Authentication> refreshAndRetryValidation(String token) {
        return fetchAndUpdateCache()
                .flatMap(newJwkSet -> validateTokenWithJWKSet(token, newJwkSet))
                .onErrorResume(e -> {
                    log.warn("(refreshAndRetryValidation) Validation failed even with fresh keys");
                    return Mono.error(new UnauthorizedException());
                });
    }

    private Mono<Authentication> validateTokenWithJWKSet(String token, JWKSet jwkSet) {
        try {
            if (!JwtUtil.verifyToken(jwkSet, token)) {
                log.warn("(validateTokenWithJWKSet) Token verification failed");
                trackFailedValidation();
                return Mono.error(new UnauthorizedException());
            }

            String userId = JwtUtil.getSubjectFromToken(token);
            String email = JwtUtil.getSubjectFromToken(token);
            Collection<SimpleGrantedAuthority> roles = getAuthorities(JwtUtil.getRolesFromToken(token));

            log.debug("(validateTokenWithJWKSet) Token validated successfully for user: {}", email);
            return Mono.just(new UsernamePasswordAuthenticationToken(email, userId, roles));
        } catch (ParseException e) {
            log.error("(validateTokenWithJWKSet) Error parsing token: {}", e.getMessage());
            return Mono.error(e);
        } catch (JOSEException e) {
            log.error("(validateTokenWithJWKSet) JOSE exception during token validation: {}", e.getMessage());
            trackFailedValidation();
            return Mono.error(e);
        } catch (Exception e) {
            log.error("(validateTokenWithJWKSet) Unexpected error during token validation: {}", e.getMessage());
            return Mono.error(new InternalErrorException());
        }
    }

    private void trackFailedValidation() {
        long currentFailCount = failedValidationCount.incrementAndGet();
        log.debug("(trackFailedValidation) Failed validation count: {}", currentFailCount);

        if (currentFailCount >= forceRefreshThreshold) {
            log.warn("(trackFailedValidation) Failure threshold reached ({}), scheduling refresh",
                    forceRefreshThreshold);

            // Trigger refresh asynchronously on bounded elastic scheduler to avoid blocking
            fetchAndUpdateCache()
                    .subscribeOn(Schedulers.boundedElastic())
                    .subscribe();
        }
    }

    private Mono<Void> processWithAuthentication(ServerWebExchange exchange, Authentication auth, WebFilterChain chain) {
        log.debug("(processWithAuthentication) Adding authentication for user: {}", auth.getPrincipal());

        SecurityContext securityContext = new SecurityContextImpl(auth);
        ServerHttpRequest enrichedRequest = exchange.getRequest().mutate()
                .header("X-User-Id", auth.getCredentials().toString())
                .header("X-Email", auth.getPrincipal().toString())
                .build();

        ServerWebExchange enrichedExchange = exchange.mutate().request(enrichedRequest).build();

        return chain.filter(enrichedExchange)
                .contextWrite(ReactiveSecurityContextHolder.withSecurityContext(Mono.just(securityContext)));
    }

    private Mono<Void> handleFilterError(ServerWebExchange exchange, Throwable error) {
        HttpStatus status;
        String message;
        Map<String, Object> additionalInfo;

        if (error instanceof UnauthorizedException) {
            status = HttpStatus.UNAUTHORIZED;
            message = "Invalid or expired token";
            additionalInfo = Map.of(ERROR_CODE_FIELD_KEY, "invalid_token");
        } else if (error instanceof ParseException) {
            status = HttpStatus.BAD_REQUEST;
            message = "Malformed token";
            additionalInfo = Map.of(ERROR_CODE_FIELD_KEY, "malformed_token");
        } else if (error instanceof JOSEException) {
            status = HttpStatus.UNAUTHORIZED;
            message = "Token validation failed";
            additionalInfo = Map.of(ERROR_CODE_FIELD_KEY, "validation_failed");
        } else if (error instanceof WebClientResponseException webClientResponseException) {
            status = HttpStatus.SERVICE_UNAVAILABLE;
            message = "Authentication service unavailable";
            additionalInfo = Map.of(
                    ERROR_CODE_FIELD_KEY, "auth_service_error",
                    "status", webClientResponseException.getStatusCode().value()
            );
        } else if (error instanceof InternalErrorException) {
            status = HttpStatus.INTERNAL_SERVER_ERROR;
            message = "Internal authentication error";
            additionalInfo = Map.of(ERROR_CODE_FIELD_KEY, "internal_error");
        } else {
            status = HttpStatus.INTERNAL_SERVER_ERROR;
            message = "Unexpected authentication error";
            additionalInfo = Map.of(ERROR_CODE_FIELD_KEY, "unexpected_error");
        }

        log.error("(handleFilterError) Authentication error: {} - {}", error.getClass().getSimpleName(), error.getMessage());
        return createErrorResponse(exchange, status, message, additionalInfo);
    }

    /**
     * Gets the JWKSet from cache if available, or fetches it if not
     */
    private Mono<JWKSet> getJWKSet() {
        JWKSet jwkSet = cachedJWKSet.get();

        if (jwkSet != null) {
            log.debug("(getJWKSet) Using cached JWK Set");
            return Mono.just(jwkSet);
        }

        log.info("(getJWKSet) Cache miss, fetching JWK Set");
        return fetchAndUpdateCache();
    }

    /**
     * Fetches and caches the JWK Set - using a shared Mono to prevent multiple refreshes
     */
    private Mono<JWKSet> fetchAndUpdateCache() {
        // Check if there's already a refresh operation in progress
        Mono<JWKSet> existingOperation = currentRefreshOperation.get();
        if (existingOperation != null) {
            log.debug("(fetchAndUpdateCache) Reusing in-progress refresh operation");
            return existingOperation;
        }

        // Create a new refresh operation
        Mono<JWKSet> newOperation = fetchJWKSet()
                .doOnNext(jwkSet -> {
                    cachedJWKSet.set(jwkSet);
                    log.info("(fetchAndUpdateCache) JWK Set cached with {} keys", jwkSet.getKeys().size());
                })
                .doFinally(signalType ->
                    // Clear the current operation reference when done
                    // No circular reference because we're not using the variable inside the lambda
                    currentRefreshOperation.compareAndSet(currentRefreshOperation.get(), null)
                )
                .cache(); // Make it shared so multiple subscribers get the same result

        // Try to store our operation - use CAS to ensure only one thread succeeds
        if (currentRefreshOperation.compareAndSet(null, newOperation)) {
            log.debug("(fetchAndUpdateCache) Created new refresh operation");
            return newOperation;
        } else {
            // Another thread set an operation first, use that one instead
            log.debug("(fetchAndUpdateCache) Using refresh operation set by another thread");
            return currentRefreshOperation.get();
        }
    }

    /**
     * Fetches the JWK Set from the remote server
     */
    private Mono<JWKSet> fetchJWKSet() {
        log.info("(fetchJWKSet) Fetching JWK Set from: {}", jwksUri);

        return lbWebClient.get()
                .uri(jwksUri)
                .retrieve()
                .bodyToMono(String.class)
                .retryWhen(createRetrySpec())
                .doOnError(error -> log.error("(fetchJWKSet) Error retrieving JWK Set: {}", error.getMessage()))
                .flatMap(this::parseJWKSet);
    }

    private Retry createRetrySpec() {
        return Retry.backoff(maxRetries, Duration.ofMillis(retryDelayMillis))
                .filter(throwable -> throwable instanceof WebClientResponseException webClientResponseException &&
                        webClientResponseException.getStatusCode().is5xxServerError())
                .doBeforeRetry(signal ->
                        log.warn("(fetchJWKSet) Retrying JWK fetch after error: {}, attempt: {}",
                                signal.failure().getMessage(), signal.totalRetries() + 1));
    }

    private Mono<JWKSet> parseJWKSet(String jwkSetString) {
        log.debug("(parseJWKSet) Parsing JWK Set");

        try {
            JWKSet jwkSet = JWKSet.parse(jwkSetString);
            log.info("(parseJWKSet) Successfully parsed JWK Set with {} keys", jwkSet.getKeys().size());
            return Mono.just(jwkSet);
        } catch (ParseException e) {
            log.error("(parseJWKSet) Failed to parse JWK Set: {}", e.getMessage());
            return Mono.error(new InternalErrorException());
        }
    }

    private Collection<SimpleGrantedAuthority> getAuthorities(List<String> roles) {
        return roles.stream()
                .map(role -> new SimpleGrantedAuthority(role.toUpperCase()))
                .toList();
    }

    private Mono<Void> createErrorResponse(ServerWebExchange exchange, HttpStatus status, String message, Map<String, Object> additionalInfo) {
        exchange.getResponse().setStatusCode(status);
        exchange.getResponse().getHeaders().setContentType(MediaType.APPLICATION_JSON);

        String errorJson = buildErrorJson(status, message, exchange.getRequest().getPath().value(), additionalInfo);
        byte[] bytes = errorJson.getBytes(StandardCharsets.UTF_8);
        DataBuffer buffer = exchange.getResponse().bufferFactory().wrap(bytes);

        log.warn("(createErrorResponse) Returning error response: {}", errorJson);
        return exchange.getResponse().writeWith(Mono.just(buffer));
    }

    private String buildErrorJson(HttpStatus status, String message, String path, Map<String, Object> additionalInfo) {
        StringBuilder jsonBuilder = new StringBuilder();
        jsonBuilder.append("{");
        jsonBuilder.append("\"status\":").append(status.value()).append(",");
        jsonBuilder.append("\"error\":\"").append(status.getReasonPhrase()).append("\",");
        jsonBuilder.append("\"message\":\"").append(message).append("\",");
        jsonBuilder.append("\"path\":\"").append(path).append("\"");

        // Add any additional info
        if (additionalInfo != null && !additionalInfo.isEmpty()) {
            for (Map.Entry<String, Object> entry : additionalInfo.entrySet()) {
                jsonBuilder.append(",");
                jsonBuilder.append("\"").append(entry.getKey()).append("\":");

                Object value = entry.getValue();
                if (value instanceof String) {
                    jsonBuilder.append("\"").append(value).append("\"");
                } else {
                    jsonBuilder.append(value);
                }
            }
        }

        jsonBuilder.append("}");
        return jsonBuilder.toString();
    }

    @PreDestroy
    public void destroy() {
        log.info("(destroy) Shutting down JwtAuthenticationFilter resources");
        try {
            scheduler.shutdown();
            if (!scheduler.awaitTermination(5, TimeUnit.SECONDS)) {
                log.warn("(destroy) Scheduler did not terminate in time, forcing shutdown");
                scheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.error("(destroy) Scheduler shutdown interrupted");
            scheduler.shutdownNow();
        }
    }
}