package org.aibles.order_service.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.dto.response.ShoppingCartListResponse;
import org.aibles.order_service.dto.response.ShoppingCartResponse;
import org.aibles.order_service.entity.ShoppingCartItem;
import org.aibles.order_service.repository.master.MasterShoppingCartItemRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartRepo;
import org.aibles.order_service.repository.slave.SlaveShoppingCartRepo;
import org.aibles.order_service.service.ShoppingCartService;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

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

        // Atomic upserts on the MASTER. The old check-then-insert read the slave,
        // which lags under load (15s observed) — concurrent adds both saw "absent"
        // and inserted duplicates. The unique key on (shopping_cart_id, product_id)
        // plus ON DUPLICATE KEY UPDATE makes the merge race-free regardless of lag.
        masterShoppingCartRepo.upsertCart(userId);
        masterShoppingCartItemRepo.upsertItem(
                UUID.randomUUID().toString(),
                userId,
                request.getProductId(),
                request.getQuantity(),
                request.getPrice());
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
