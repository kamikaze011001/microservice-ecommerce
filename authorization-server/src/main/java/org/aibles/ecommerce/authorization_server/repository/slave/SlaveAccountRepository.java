package org.aibles.ecommerce.authorization_server.repository.slave;

import org.aibles.ecommerce.authorization_server.entity.Account;
import org.aibles.ecommerce.authorization_server.repository.projection.AccountUserProjection;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public interface SlaveAccountRepository extends JpaRepository<Account, String> {

    boolean existsByUsername(String username);

    @Query("select a from Account a left join User u on a.userId = u.id where u.email = :email")
    Optional<Account> findbyEmail(String email);

    @Query(
            """
                            select u.id as userId,
                            a.id as accountId,
                            u.email as email,
                            a.username as username,
                            a.password as password,
                            a.isActivated as isActivated
                            from Account a join User u on a.userId = u.id
                            where a.username = :username
                    """
    )
    Optional<AccountUserProjection> findByUsername(String username);

    @Query("""
            select r.name from Account a join AccountRole ar on a.id = ar.accountId join Role r on ar.roleId = r.id where a.id = :id
            """)
    List<String> findRolesById(String id);

    @Query("""
        select r.name from Account a join AccountRole ar on a.id = ar.accountId join Role r on ar.roleId = r.id where a.userId = :userId
       """)
    List<String> findRolesByUserId(String userId);

    Optional<Account> findByUserId(String userId);
}
