package org.aibles.ecommerce.authorization_server.repository;

import org.aibles.ecommerce.authorization_server.entity.AccountRole;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface AccountRoleRepository extends JpaRepository<AccountRole, String> {
}
