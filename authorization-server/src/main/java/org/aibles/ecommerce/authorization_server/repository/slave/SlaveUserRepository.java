package org.aibles.ecommerce.authorization_server.repository.slave;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface SlaveUserRepository extends JpaRepository<User, String>, UserRepositoryCustom {

    boolean existsByEmail(String email);
}
