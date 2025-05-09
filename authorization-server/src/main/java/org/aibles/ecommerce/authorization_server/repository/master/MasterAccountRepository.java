package org.aibles.ecommerce.authorization_server.repository.master;

import org.aibles.ecommerce.authorization_server.entity.Account;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterAccountRepository extends JpaRepository<Account, String> {

    @Query("""
        delete from AccountRole ar where ar.accountId = :id
        """)
    @Modifying
    void deleteRolesById(String id);

    @Modifying
    @Query(value = """
        update account a inner join user u on a.user_id = u.id 
        set a.password = :newPassword where u.email = :email
        """, nativeQuery = true)
    void resetPasswordByEmail(String email, String newPassword);
}
