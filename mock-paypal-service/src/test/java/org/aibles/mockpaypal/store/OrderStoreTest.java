package org.aibles.mockpaypal.store;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OrderStoreTest {

    @Test
    void create_thenGet_returnsStoredState() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-1", "USD", "99.99",
                "https://r/success", "https://r/cancel");

        assertThat(s.getToken()).isNotBlank();
        assertThat(s.getOrderId()).isEqualTo("order-1");
        assertThat(s.getDecision()).isEqualTo(Decision.PENDING);
        assertThat(store.get(s.getToken())).isSameAs(s);
    }

    @Test
    void setDecision_updatesState() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-2", "USD", "10.00", "r", "c");

        store.setDecision(s.getToken(), Decision.FAIL);

        assertThat(store.get(s.getToken()).getDecision()).isEqualTo(Decision.FAIL);
    }

    @Test
    void setCapture_recordsCaptureId() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-3", "USD", "10.00", "r", "c");

        store.setCapture(s.getToken(), "cap-123");

        assertThat(store.get(s.getToken()).getCaptureId()).isEqualTo("cap-123");
    }

    @Test
    void get_unknownToken_returnsNull() {
        assertThat(new OrderStore().get("nope")).isNull();
    }
}
