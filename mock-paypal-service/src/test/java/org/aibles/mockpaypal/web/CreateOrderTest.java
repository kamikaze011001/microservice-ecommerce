package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@TestPropertySource(properties = "mock.public-base-url=http://mock.test/mock-paypal-service")
class CreateOrderTest {

    @Autowired MockMvc mvc;

    private static final String BODY = """
        {
          "intent":"CAPTURE",
          "purchase_units":[{"amount":{"currency_code":"USD","value":"99.99"},"custom_id":"order-777"}],
          "payment_source":{"paypal":{"experience_context":{
            "return_url":"http://gw/payment-service/v1/paypal:success",
            "cancel_url":"http://gw/payment-service/v1/paypal:cancel"}}}
        }
        """;

    @Test
    void createOrder_returnsApproveLinkToCheckoutPage() throws Exception {
        mvc.perform(post("/v2/checkout/orders")
                        .contentType("application/json").content(BODY))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id", startsWith("MOCKORDER-")))
                .andExpect(jsonPath("$.status").value("PAYER_ACTION_REQUIRED"))
                .andExpect(jsonPath("$.links[?(@.rel=='payer-action')].href",
                        hasItem(allOf(
                                startsWith("http://mock.test/mock-paypal-service/checkout?token=MOCKORDER-")))));
    }
}
