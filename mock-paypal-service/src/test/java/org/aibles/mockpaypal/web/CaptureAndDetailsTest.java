package org.aibles.mockpaypal.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
class CaptureAndDetailsTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper om;

    private static final String BODY = """
        {"intent":"CAPTURE",
         "purchase_units":[{"amount":{"currency_code":"USD","value":"5.00"},"custom_id":"o-cap"}],
         "payment_source":{"paypal":{"experience_context":{
           "return_url":"http://gw/ok","cancel_url":"http://gw/no"}}}}
        """;

    private String newToken() throws Exception {
        MvcResult r = mvc.perform(post("/v2/checkout/orders")
                .contentType("application/json").content(BODY)).andReturn();
        return om.readTree(r.getResponse().getContentAsString()).get("id").asText();
    }

    @Test
    void capture_afterApprove_returnsCompletedWithCaptureId() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"))
                .andExpect(status().isFound());

        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.purchase_units[0].custom_id").value("o-cap"))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].id",
                        org.hamcrest.Matchers.startsWith("MOCKCAP-")))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].status").value("COMPLETED"));
    }

    @Test
    void capture_afterFail_returns422WithErrorName() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "fail"))
                .andExpect(status().isFound());

        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.name").value("UNPROCESSABLE_ENTITY"));
    }

    @Test
    void details_afterCapture_exposesCustomIdAndCaptureId() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"))
                .andExpect(status().isFound());
        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"))
                .andExpect(status().isOk());

        mvc.perform(get("/v2/checkout/orders/" + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.purchase_units[0].custom_id").value("o-cap"))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].id",
                        org.hamcrest.Matchers.startsWith("MOCKCAP-")));
    }
}
