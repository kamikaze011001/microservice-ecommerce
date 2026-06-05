package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(RefundController.class)
class RefundControllerTest {

    @Autowired MockMvc mvc;

    @Test
    void refund_returnsCompleted() throws Exception {
        mvc.perform(post("/v2/payments/captures/CAP-1/refund")
                        .contentType("application/json")
                        .content("{\"custom_id\":\"o-1\",\"amount\":{\"currency_code\":\"USD\",\"value\":\"5.00\"}}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.custom_id").value("o-1"));
    }
}
