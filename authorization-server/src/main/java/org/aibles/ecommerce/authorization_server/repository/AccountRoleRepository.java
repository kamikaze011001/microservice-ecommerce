package org.aibles.ecommerce.authorization_server.repository.master;

import org.aibles.ecommerce.authorization_server.entity.AccountRole;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterAccountRoleRepository extends JpaRepository<AccountRole, String> {
}
