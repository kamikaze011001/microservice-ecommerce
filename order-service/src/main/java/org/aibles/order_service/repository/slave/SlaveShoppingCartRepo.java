package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.ShoppingCart;
import org.aibles.order_service.entity.ShoppingCartItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface SlaveShoppingCartRepo extends JpaRepository<ShoppingCart, String> {

    @Query("""
                 select sci from ShoppingCart sc inner join ShoppingCartItem sci
                 on sc.userId = sci.shoppingCartId where sc.userId = :id
            """)
    List<ShoppingCartItem> getItemsById(String id);
}
