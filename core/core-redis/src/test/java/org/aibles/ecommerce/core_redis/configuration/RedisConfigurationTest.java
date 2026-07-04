package org.aibles.ecommerce.core_redis.configuration;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class RedisConfigurationTest {

    @Test
    void buildAddress_usesPlaintextScheme_whenSslDisabled() {
        assertThat(RedisConfiguration.buildAddress(false, "cache.example.com", 6379))
                .isEqualTo("redis://cache.example.com:6379");
    }

    @Test
    void buildAddress_usesTlsScheme_whenSslEnabled() {
        assertThat(RedisConfiguration.buildAddress(true, "cache.example.com", 6379))
                .isEqualTo("rediss://cache.example.com:6379");
    }
}
