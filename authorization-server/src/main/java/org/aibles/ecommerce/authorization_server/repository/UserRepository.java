package org.aibles.ecommerce.authorization_server.repository.master;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterUserRepository extends JpaRepository<User, String> {
}
