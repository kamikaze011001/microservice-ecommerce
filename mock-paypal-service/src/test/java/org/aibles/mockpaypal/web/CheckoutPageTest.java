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
class CheckoutPageTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper om;

    private static final String BODY = """
        {"intent":"CAPTURE",
         "purchase_units":[{"amount":{"currency_code":"USD","value":"5.00"},"custom_id":"o-1"}],
         "payment_source":{"paypal":{"experience_context":{
           "return_url":"http://gw/ok","cancel_url":"http://gw/no"}}}}
        """;

    private String createTokenAndGet() throws Exception {
        MvcResult r = mvc.perform(post("/v2/checkout/orders")
                .contentType("application/json").content(BODY)).andReturn();
        JsonNode n = om.readTree(r.getResponse().getContentAsString());
        return n.get("id").asText();
    }

    @Test
    void checkoutPage_html_hasThreeButtons() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token))
                .andExpect(status().isOk())
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=approve")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=cancel")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=fail")));
    }

    @Test
    void decisionApprove_redirectsToReturnUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"))
                .andExpect(status().isFound())
                .andExpect(header().string("Location", "http://gw/ok"));
    }

    @Test
    void decisionFail_redirectsToReturnUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "fail"))
                .andExpect(status().isFound())
                .andExpect(header().string("Location", "http://gw/ok"));
    }

    @Test
    void decisionCancel_redirectsToCancelUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "cancel"))
                .andExpect(status().isFound())
                .andExpect(header().string("Location", "http://gw/no"));
    }

    @Test
    void unknownToken_returns404() throws Exception {
        mvc.perform(get("/checkout").param("token", "MOCKORDER-DOESNOTEXIST"))
                .andExpect(status().isNotFound());
    }

    @Test
    void unknownDecision_returns400() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "bogus"))
                .andExpect(status().isBadRequest());
    }
}
