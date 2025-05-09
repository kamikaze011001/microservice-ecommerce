package org.aibles.ecommerce.authorization_server.service;

import java.util.List;

public interface RoleService {

    void validateRoleList(List<String> roles);
}
