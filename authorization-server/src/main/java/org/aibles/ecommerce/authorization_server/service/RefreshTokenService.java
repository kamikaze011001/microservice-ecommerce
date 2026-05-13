package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.dto.internal.TokenFamily;

public interface RefreshTokenService {

    /** Generate an opaque RT, persist a new family for the user. */
    String issueForUser(String userId);

    /**
     * Look up the incoming raw token, verify it is the family's current token,
     * rotate to a new RT. Throws TokenInvalidException if unknown / revoked /
     * reuse-detected.
     */
    String rotate(String incomingToken);

    /** Revoke the family the given RT belongs to. No-op if already revoked. */
    void revokeByToken(String incomingToken);

    /** Revoke every family for the user (logout-all / password-change). */
    void revokeAllForUser(String userId);

    /** Resolve userId from an RT — used by /auth:logout to know who to log. */
    String userIdForToken(String incomingToken);
}
