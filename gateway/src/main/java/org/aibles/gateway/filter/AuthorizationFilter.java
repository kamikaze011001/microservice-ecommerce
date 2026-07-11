package org.aibles.gateway.filter;

import lombok.extern.slf4j.Slf4j;
import org.aibles.gateway.entity.ApiRole;
import org.aibles.gateway.repository.ApiRoleRepository;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.util.AntPathMatcher;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;

import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
public class AuthorizationFilter implements WebFilter {

    private static final String ROLE_PERMIT_ALL = "PERMIT_ALL";
    private static final String ROLE_AUTHORIZED = "AUTHORIZED";

    private final ApiRoleRepository apiRoleRepository;
    private final AntPathMatcher pathMatcher = new AntPathMatcher();

    public AuthorizationFilter(ApiRoleRepository apiRoleRepository) {
        this.apiRoleRepository = apiRoleRepository;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String path = exchange.getRequest().getPath().toString();
        String method = exchange.getRequest().getMethod().toString();
        log.info("(filter)path: {}, method: {}", path, method);

        // Actuator endpoints (k8s liveness/readiness probes, prometheus scrape)
        // are internal-only and not in the api_role registry. Skip them here —
        // this filter is a global WebFilter that runs on the management port too,
        // and would otherwise 403 the probes ("path not registered"), failing
        // liveness and getting the pod killed in a loop. See k8s/CLAUDE.md.
        if (path.startsWith("/actuator")) {
            return chain.filter(exchange);
        }

        return apiRoleRepository.findAll()
                .filter(apiRole -> pathMatcher.match(apiRole.getPath(), path))
                .filter(apiRole -> apiRole.getMethod() == null || apiRole.getMethod().contains(method))
                .collectList()
                .flatMap(apiRoles -> handleAuthorization(apiRoles, exchange, chain))
                .onErrorResume(e -> {
                    log.error("(filter)Authorization error occurred: {}", e.getMessage(), e);
                    
                    // Categorize the exception type
                    if (e instanceof IllegalStateException) {
                        return handleError(exchange, HttpStatus.BAD_REQUEST, "common.bad_request", ErrorResponseWriter.MSG_BAD_REQUEST);
                    } else if (e instanceof IllegalArgumentException) {
                        return handleError(exchange, HttpStatus.BAD_REQUEST, "common.bad_request", ErrorResponseWriter.MSG_BAD_REQUEST);
                    } else if (e.getMessage() != null && e.getMessage().contains("timeout")) {
                        return handleError(exchange, HttpStatus.GATEWAY_TIMEOUT, "common.timeout", ErrorResponseWriter.MSG_TIMEOUT);
                    } else {
                        return handleError(exchange, HttpStatus.INTERNAL_SERVER_ERROR, "common.internal_error", ErrorResponseWriter.MSG_INTERNAL);
                    }
                });
    }

    private Mono<Void> handleAuthorization(List<ApiRole> apiRoles, ServerWebExchange exchange, WebFilterChain chain) {
        if (apiRoles.isEmpty()) {
            log.info("(handleAuthorization) API path is not registered in the system");
            return handleError(exchange, HttpStatus.FORBIDDEN, "auth.forbidden", ErrorResponseWriter.MSG_FORBIDDEN);
        }

        Set<String> allowedRoles = apiRoles.stream()
                .flatMap(apiRole -> apiRole.getRoles().stream())
                .collect(Collectors.toSet());

        if (allowedRoles.contains(ROLE_PERMIT_ALL)) {
            log.info("(handleAuthorization) API path has PERMIT_ALL access");
            return chain.filter(exchange);
        }

        return ReactiveSecurityContextHolder.getContext()
                .switchIfEmpty(Mono.defer(() -> {
                    log.warn("(handleAuthorization) No security context found for authenticated request");
                    return Mono.error(new IllegalStateException("Security context not available"));
                }))
                .map(SecurityContext::getAuthentication)
                .flatMap(auth -> validateUserRoles(auth, allowedRoles, exchange, chain))
                .onErrorResume(e -> {
                    log.error("(handleAuthorization) Error during security context processing: {}", e.getMessage());
                    return handleError(exchange, HttpStatus.UNAUTHORIZED, "auth.token_missing", ErrorResponseWriter.MSG_TOKEN_MISSING);
                });
    }

    private Mono<Void> validateUserRoles(Authentication auth, Set<String> allowedRoles, ServerWebExchange exchange, WebFilterChain chain) {
        if (auth == null) {
            log.error("(validateUserRoles) Authentication object is null");
            return handleError(exchange, HttpStatus.UNAUTHORIZED, "auth.token_missing", ErrorResponseWriter.MSG_TOKEN_MISSING);
        }

        if (allowedRoles.contains(ROLE_AUTHORIZED)) {
            log.info("(validateUserRoles) API path requires basic authorization only");
            return chain.filter(exchange);
        }

        Collection<? extends GrantedAuthority> authorities = auth.getAuthorities();
        if (authorities == null || authorities.isEmpty()) {
            log.error("(validateUserRoles) User has no authorities: {}", auth.getPrincipal());
            return handleError(exchange, HttpStatus.FORBIDDEN, "auth.forbidden", ErrorResponseWriter.MSG_FORBIDDEN);
        }

        Set<String> userRoles = authorities.stream()
                .map(GrantedAuthority::getAuthority)
                .collect(Collectors.toSet());

        boolean hasRequiredRoles = userRoles.stream().anyMatch(allowedRoles::contains);
        if (!hasRequiredRoles) {
            log.error("(validateUserRoles) User '{}' lacks required roles. Has: {}, Required any of: {}",
                     auth.getPrincipal(), userRoles, allowedRoles);
            return handleError(exchange, HttpStatus.FORBIDDEN, "auth.forbidden", ErrorResponseWriter.MSG_FORBIDDEN);
        }

        log.info("(filter) User '{}' authorized for path: {}", auth.getPrincipal(), exchange.getRequest().getPath());
        return chain.filter(exchange);
    }

    private Mono<Void> handleError(ServerWebExchange exchange, HttpStatus status, String dottedCode, String humanMessage) {
        return ErrorResponseWriter.write(exchange, status, dottedCode, humanMessage);
    }
}
