package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.exception.InvalidRoleIdException;
import org.aibles.ecommerce.authorization_server.repository.RoleRepository;
import org.aibles.ecommerce.authorization_server.service.RoleService;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
public class RoleServiceImpl implements RoleService {

    private final RoleRepository roleRepository;

    public RoleServiceImpl(RoleRepository roleRepository) {
        this.roleRepository = roleRepository;
    }

    // Primary, NOT @ReplicaRead: it runs inside AuthFacadeServiceImpl.updateRole's
    // read-write transaction and gates the account_role insert (check-then-write).
    @Override
    @Transactional(readOnly = true)
    public void validateRoleList(List<String> roles) {
        log.info("(validateRoleList)roles: {}", roles);
        int count = roleRepository.countRoleIn(roles);
        if (count < roles.size()) {
            log.error("(validateRoleList)roles: {} is invalid", roles);
            throw new InvalidRoleIdException();
        }
    }
}
