package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.ShoppingCartItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface SlaveShoppingCartItemRepo extends JpaRepository<ShoppingCartItem, String> {

    Optional<ShoppingCartItem> findByShoppingCartIdAndProductId(String shoppingCartId, String productId);
}
