package org.aibles.ecommerce.authorization_server.repository.projection;

public interface AccountUserProjection {

    String getUserId();
    String getAccountId();
    String getEmail();
    String getUsername();
    String getPassword();
    Boolean getIsActivated();
}
