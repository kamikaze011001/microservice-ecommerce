package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.repository.projection.AccountUserProjection;

import java.util.List;

public interface AccountService {

    boolean isExistedByUsername(String username);

    void save(String userId, String username, String password);

    void activateByEmail(String email);

    AccountUserProjection findByUsername(String username);

    List<String> getRolesById(String id);

    List<String> getRolesByUserId(String userId);

    void deleteRoles(String id);

    void addRoles(String accountId, List<String> roles);

    boolean isExistedById(String id);

    void resetPasswordByEmail(String email, String newPassword);

    void updatePassword(String userId, String oldPassword, String newPassword);
}
