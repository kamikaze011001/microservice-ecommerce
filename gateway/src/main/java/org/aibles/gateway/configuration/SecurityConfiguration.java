package org.aibles.gateway.configuration;

import org.aibles.gateway.filter.AuthorizationFilter;
import org.aibles.gateway.filter.JwtAuthenticationFilter;
import org.aibles.gateway.repository.ApiRoleRepository;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.SecurityWebFiltersOrder;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.web.reactive.function.client.WebClient;

@Configuration
@EnableWebFluxSecurity
public class SecurityConfiguration {

    @Bean
    public JwtAuthenticationFilter jwtAuthenticationFilter(WebClient lbWebClient) {
        return new JwtAuthenticationFilter(lbWebClient);
    }

    @Bean
    public AuthorizationFilter authorizationFilter(ApiRoleRepository apiRoleRepository) {
        return new AuthorizationFilter(apiRoleRepository);
    }
    @Bean
    public SecurityWebFilterChain springSecurityFilterChain(ServerHttpSecurity http,
                                                            JwtAuthenticationFilter jwtAuthenticationFilter,
                                                            AuthorizationFilter authorizationFilter) {
        return http.cors(Customizer.withDefaults())
                .csrf(ServerHttpSecurity.CsrfSpec::disable)
                .addFilterAt(jwtAuthenticationFilter, SecurityWebFiltersOrder.AUTHENTICATION)
                .addFilterAt(authorizationFilter, SecurityWebFiltersOrder.AUTHORIZATION)
                .build();
    }
}
