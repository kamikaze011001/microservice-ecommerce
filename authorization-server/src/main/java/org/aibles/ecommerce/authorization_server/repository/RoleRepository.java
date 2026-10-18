package org.aibles.ecommerce.authorization_server.repository.slave;

import org.aibles.ecommerce.authorization_server.entity.Role;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface SlaveRoleRepository extends JpaRepository<Role, String> {

    @Query("select count(r) from Role r where r.id in :roles")
    int countRoleIn(List<String> roles);
}
