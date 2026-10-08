package org.aibles.ecommerce.product_service.listener;

import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.product_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.DuplicateKeyException;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatNoException;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class ProductQuantityUpdatedListenerTest {

    ProductQuantityHistoryRepo repo;
    ProductQuantityUpdatedListener listener;
    ProductQuantityUpdated delta = ProductQuantityUpdated.newBuilder().setProductId("p-1").setQuantity(-2).build();

    @BeforeEach
    void setUp() {
        repo = mock(ProductQuantityHistoryRepo.class);
        listener = new ProductQuantityUpdatedListener(repo);
    }

    @Test
    void ledgerRowId_isTheSourceEventId_whenTheHeaderIsPresent() {
        listener.handle(delta, "cdc-3-99".getBytes(StandardCharsets.UTF_8), "t.qty", 5, 10L);

        ProductQuantityHistory row = inserted();
        assertThat(row.getId()).isEqualTo("cdc-3-99");
        assertThat(row.getProductId()).isEqualTo("p-1");
        assertThat(row.getQuantity()).isEqualTo(-2);
        assertThat(row.getCreatedAt()).isNotNull();
    }

    @Test
    void ledgerRowId_fallsBackToThisRecordsCoordinates() {
        listener.handle(delta, null, "t.qty", 5, 10L);

        assertThat(inserted().getId()).isEqualTo("t.qty-5-10");
    }

    @Test
    void redelivery_hitsTheDuplicateId_andIsSkippedWithoutError() {
        when(repo.insert(any(ProductQuantityHistory.class))).thenThrow(new DuplicateKeyException("E11000"));

        assertThatNoException().isThrownBy(() -> listener.handle(delta, null, "t.qty", 5, 10L));
    }

    @Test
    void neverUsesSave_whichWouldSilentlyOverwriteInsteadOfDetectingTheDuplicate() {
        listener.handle(delta, null, "t.qty", 5, 10L);

        verify(repo, never()).save(any());
    }

    private ProductQuantityHistory inserted() {
        ArgumentCaptor<ProductQuantityHistory> captor = ArgumentCaptor.forClass(ProductQuantityHistory.class);
        verify(repo).insert(captor.capture());
        return captor.getValue();
    }
}
