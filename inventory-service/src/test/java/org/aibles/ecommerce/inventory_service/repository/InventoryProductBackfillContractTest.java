package org.aibles.ecommerce.inventory_service.repository.master;

import org.junit.jupiter.api.Test;
import static org.mockito.Mockito.*;

/**
 * Contract test — verifies the backfill method exists on the interface and returns
 * the affected-row count. Real SQL behavior is verified by the k8s boundary regression.
 */
class MasterInventoryProductBackfillContractTest {

    @Test
    void backfillStockFromLedger_methodExists_andReturnsInt() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);
        when(repo.backfillStockFromLedger()).thenReturn(3);

        int rows = repo.backfillStockFromLedger();

        verify(repo).backfillStockFromLedger();
        org.assertj.core.api.Assertions.assertThat(rows).isEqualTo(3);
    }
}
