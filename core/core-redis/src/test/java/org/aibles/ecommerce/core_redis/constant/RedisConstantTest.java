package org.aibles.ecommerce.core_redis.constant;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class RedisConstantTest {

    @Test
    void availableProductKey_hasCorrectPrefix() {
        assertThat(RedisConstant.AVAILABLE_PRODUCT_KEY).isEqualTo("productAvailable:");
    }
}
