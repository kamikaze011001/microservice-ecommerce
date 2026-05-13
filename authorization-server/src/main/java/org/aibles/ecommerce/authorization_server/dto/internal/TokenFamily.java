package org.aibles.ecommerce.authorization_server.dto.internal;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class TokenFamily implements Serializable {
    private String userId;
    private String currentToken;
    private long createdAt;   // epoch ms — login time
    private long expiresAt;   // epoch ms — hard cap, set at login
}
