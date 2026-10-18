package org.aibles.ecommerce.authorization_server.repository;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface UserRepository extends JpaRepository<User, String>, UserRepositoryCustom {

    boolean existsByEmail(String email);
}
