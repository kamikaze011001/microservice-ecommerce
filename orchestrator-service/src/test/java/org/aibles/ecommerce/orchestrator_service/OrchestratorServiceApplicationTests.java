package org.aibles.ecommerce.orchestrator_service;

import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;

@SpringBootTest
class OrchestratorServiceApplicationTests {

	@MockBean
	RedissonClient redissonClient;

	@Test
	void contextLoads() {
	}

}
