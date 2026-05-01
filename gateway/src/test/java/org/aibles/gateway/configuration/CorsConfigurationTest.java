package org.aibles.gateway.configuration;

import org.aibles.gateway.repository.ApiRoleRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.reactive.server.WebTestClient;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT,
    properties = {
        "spring.cloud.vault.enabled=false",
        "spring.cloud.vault.kv.enabled=false",
        "spring.cloud.vault.fail-fast=false",
        "eureka.client.enabled=false",
        "eureka.client.register-with-eureka=false",
        "eureka.client.fetch-registry=false",
        "spring.config.import=optional:vault://",
        "application.jwk-set-uri=http://authorization-server/authorization-server/v1/.well-known/jwks.json",
        "application.gateway.cors.allowed-origins=http://localhost:3000"
    })
class CorsConfigurationTest {


    @MockBean
    private ApiRoleRepository apiRoleRepository;

    @Autowired
    private WebTestClient client;

    @Test
    void preflightFromAllowedOriginReturnsCorsHeaders() {
        client.options().uri("/authorization-server/v1/auth:login")
            .header("Origin", "http://localhost:3000")
            .header("Access-Control-Request-Method", "POST")
            .header("Access-Control-Request-Headers", "Authorization,Content-Type")
            .exchange()
            .expectHeader().valueEquals("Access-Control-Allow-Origin", "http://localhost:3000")
            .expectHeader().valueEquals("Access-Control-Allow-Credentials", "true")
            .expectHeader().value("Access-Control-Allow-Methods", methods ->
                assertThat(methods).contains("POST"));
    }

    @Test
    void preflightFromDisallowedOriginIsRejected() {
        client.options().uri("/authorization-server/v1/auth:login")
            .header("Origin", "http://evil.example.com")
            .header("Access-Control-Request-Method", "POST")
            .exchange()
            .expectHeader().doesNotExist("Access-Control-Allow-Origin");
    }
}
