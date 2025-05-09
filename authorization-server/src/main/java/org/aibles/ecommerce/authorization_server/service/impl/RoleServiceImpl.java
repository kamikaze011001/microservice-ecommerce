package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.exception.InvalidRoleIdException;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveRoleRepository;
import org.aibles.ecommerce.authorization_server.service.RoleService;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
public class RoleServiceImpl implements RoleService {

    private final SlaveRoleRepository slaveRoleRepository;

    public RoleServiceImpl(SlaveRoleRepository slaveRoleRepository) {
        this.slaveRoleRepository = slaveRoleRepository;
    }

    @Override
    @Transactional(readOnly = true)
    public void validateRoleList(List<String> roles) {
        log.info("(validateRoleList)roles: {}", roles);
        int count = slaveRoleRepository.countRoleIn(roles);
        if (count < roles.size()) {
            log.error("(validateRoleList)roles: {} is invalid", roles);
            throw new InvalidRoleIdException();
        }
    }
}
