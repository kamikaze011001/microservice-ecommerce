package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(OAuthController.class)
class OAuthControllerTest {

    @Autowired MockMvc mvc;

    @Test
    void token_returnsMockAccessToken() throws Exception {
        mvc.perform(post("/v1/oauth2/token")
                        .contentType("application/x-www-form-urlencoded")
                        .content("grant_type=client_credentials"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.access_token").value("mock-access-token"))
                .andExpect(jsonPath("$.token_type").value("Bearer"));
    }
}
