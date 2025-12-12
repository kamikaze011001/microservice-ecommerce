package org.aibles.core_jwt_util.dto;

import lombok.Builder;
import lombok.Getter;

import java.util.List;

/**
 * Value object containing all extracted JWT token claims.
 * Used to avoid multiple token parsing operations.
 */
@Getter
@Builder
public class TokenClaims {

    /**
     * User ID extracted from JWT subject claim.
     */
    private final String userId;

    /**
     * Email extracted from JWT email claim.
     */
    private final String email;

    /**
     * Roles extracted from JWT roles claim.
     */
    private final List<String> roles;

    /**
     * Validates that all required claims are present.
     *
     * @return true if userId, email, and roles are all non-null
     */
    public boolean isValid() {
        return userId != null && email != null && roles != null;
    }
}
