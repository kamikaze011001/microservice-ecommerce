package org.aibles.order_service.repository.master;

import org.aibles.order_service.entity.ShoppingCartItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterShoppingCartItemRepo extends JpaRepository<ShoppingCartItem, String> {

    @Modifying
    @Query("update ShoppingCartItem sci set sci.quantity = :quantity where sci.id = :itemId")
    void updateItem(String itemId, Long quantity);
}
