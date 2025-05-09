package org.aibles.ecommerce.authorization_server.configuration;

import org.aibles.ecommerce.authorization_server.filter.AuthenticationErrorHandler;
import org.aibles.ecommerce.authorization_server.filter.JwtAuthenticationFilter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.context.SecurityContextHolderFilter;

@Configuration
@EnableWebSecurity
public class SecurityConfiguration {

    private final AuthenticationErrorHandler authenticationErrorHandler;

    private final JwtAuthenticationFilter jwtAuthenticationFilter;

    public SecurityConfiguration(AuthenticationErrorHandler authenticationErrorHandler, JwtAuthenticationFilter jwtAuthenticationFilter) {
        this.authenticationErrorHandler = authenticationErrorHandler;
        this.jwtAuthenticationFilter = jwtAuthenticationFilter;
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http.cors(Customizer.withDefaults())
                .csrf(AbstractHttpConfigurer::disable)
                .authorizeHttpRequests(authorizeRequest ->
                        authorizeRequest.requestMatchers(
                                        "/v3/api-docs**",
                                        "/v3/api-docs/**",
                                        "/.well-known/jwks.json",
                                        "/v1/auth**",
                                        "/v1/auth/**")
                                .permitAll()
                                .requestMatchers(
                                        "/v1/users**", "/v1/users/**"
                                ).authenticated()
                                .requestMatchers("/v1/admin**", "/v1/admin/**")
                                .hasAnyAuthority("ADMIN")
                )
                .addFilterAfter(jwtAuthenticationFilter, SecurityContextHolderFilter.class)
                .exceptionHandling(httpSecurityExceptionHandlingConfigurer ->
                        httpSecurityExceptionHandlingConfigurer.authenticationEntryPoint(authenticationErrorHandler))
                .sessionManagement(sessionManagement ->
                        sessionManagement.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .build();
    }
}
