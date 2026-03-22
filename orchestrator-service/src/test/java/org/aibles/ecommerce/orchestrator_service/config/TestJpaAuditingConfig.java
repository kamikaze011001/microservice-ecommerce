package org.aibles.ecommerce.orchestrator_service.config;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;

/**
 * Minimal test configuration that provides @EnableJpaAuditing
 * without pulling in Redis or Vault dependencies that are unavailable in @DataJpaTest.
 */
@TestConfiguration
@EnableJpaAuditing
public class TestJpaAuditingConfig {
}
