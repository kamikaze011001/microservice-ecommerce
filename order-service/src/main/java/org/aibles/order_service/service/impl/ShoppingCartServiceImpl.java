package org.aibles.order_service.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.dto.response.ShoppingCartListResponse;
import org.aibles.order_service.dto.response.ShoppingCartResponse;
import org.aibles.order_service.entity.ShoppingCart;
import org.aibles.order_service.entity.ShoppingCartItem;
import org.aibles.order_service.repository.master.MasterShoppingCartItemRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartRepo;
import org.aibles.order_service.repository.slave.SlaveShoppingCartRepo;
import org.aibles.order_service.service.ShoppingCartService;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
@RequiredArgsConstructor
public class ShoppingCartServiceImpl implements ShoppingCartService {

    private final MasterShoppingCartRepo masterShoppingCartRepo;

    private final SlaveShoppingCartRepo slaveShoppingCartRepo;

    private final MasterShoppingCartItemRepo masterShoppingCartItemRepo;


    @Override
    @Transactional
    public void addItem(String userId, ShoppingCartAddRequest request) {
        log.info("(addItem)userId: {} request: {}", userId, request);

        if (!slaveShoppingCartRepo.existsById(userId)) {
            masterShoppingCartRepo.save(new ShoppingCart(userId));
        }

        ShoppingCartItem shoppingCartItem = ShoppingCartItem.builder()
                .shoppingCartId(userId)
                .price(request.getPrice())
                .productId(request.getProductId())
                .quantity(request.getQuantity())
                .build();

        masterShoppingCartItemRepo.save(shoppingCartItem);
    }

    @Override
    @Transactional(readOnly = true)
    public ShoppingCartListResponse list(String userId) {
        log.info("(list)userId: {}", userId);
        List<ShoppingCartItem> shoppingCartItems = slaveShoppingCartRepo.getItemsById(userId);
        ShoppingCartListResponse shoppingCartListResponse = new ShoppingCartListResponse();
        shoppingCartListResponse.setShoppingCarts(shoppingCartItems.stream()
                .map(sci -> ShoppingCartResponse.builder()
                        .id(sci.getId())
                        .quantity(sci.getQuantity())
                        .price(sci.getPrice())
                        .productId(sci.getProductId())
                        .build()).toList());
        return shoppingCartListResponse;
    }

    @Override
    @Transactional
    public void updateItem(String itemId, Long quantity) {
        log.info("(updateItem)itemId: {}, quantity: {}", itemId, quantity);
        masterShoppingCartItemRepo.updateItem(itemId, quantity);
    }

    @Override
    @Transactional
    public void deleteItem(String itemId) {
        log.info("(deleteItem)itemId: {}", itemId);
        masterShoppingCartItemRepo.deleteById(itemId);
    }
}
