package org.aibles.order_service.repository.master;

import org.aibles.order_service.entity.ShoppingCart;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterShoppingCartRepo extends JpaRepository<ShoppingCart, String> {

    // user_id is the PK, so this is a no-op touch when the cart already exists —
    // replaces the lag-prone existsById check on the slave.
    @Modifying
    @Query(value = """
            INSERT INTO shopping_cart (user_id, created_at, updated_at)
            VALUES (:userId, NOW(6), NOW(6))
            ON DUPLICATE KEY UPDATE updated_at = NOW(6)
            """, nativeQuery = true)
    void upsertCart(String userId);
}
