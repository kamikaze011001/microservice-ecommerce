package org.aibles.order_service.repository.master;

import org.aibles.order_service.entity.ShoppingCart;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterShoppingCartRepo extends JpaRepository<ShoppingCart, String> {
}
