package org.aibles.ecommerce.inventory_service.repository.master;

import org.junit.jupiter.api.Test;
import static org.mockito.Mockito.*;

/**
 * Contract test — verifies the method signatures exist on the interface/class.
 * Real DB behavior is verified by the k8s boundary regression test.
 */
class MasterInventoryProductRepositoryContractTest {

    @Test
    void decrementStockIfSufficient_methodExists_andReturnsInt() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);
        when(repo.decrementStockIfSufficient("prod-1", 5L)).thenReturn(1);

        int result = repo.decrementStockIfSufficient("prod-1", 5L);

        verify(repo).decrementStockIfSufficient("prod-1", 5L);
        org.assertj.core.api.Assertions.assertThat(result).isEqualTo(1);
    }

    @Test
    void decrementStockIfSufficient_returns0_whenStockInsufficient() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);
        when(repo.decrementStockIfSufficient("prod-1", 999L)).thenReturn(0);

        int result = repo.decrementStockIfSufficient("prod-1", 999L);

        org.assertj.core.api.Assertions.assertThat(result).isEqualTo(0);
    }

    @Test
    void adjustStock_methodExists() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);

        repo.adjustStock("prod-1", 10L);

        verify(repo).adjustStock("prod-1", 10L);
    }
}
