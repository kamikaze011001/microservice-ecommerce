package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.dto.TokenResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OAuthController {

    @PostMapping("/v1/oauth2/token")
    public TokenResponse token() {
        return new TokenResponse("mock-access-token", "Bearer", 32400L);
    }
}
