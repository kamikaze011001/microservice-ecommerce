package org.aibles.order_service.service;

import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.repository.master.MasterShoppingCartItemRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartRepo;
import org.aibles.order_service.repository.slave.SlaveShoppingCartRepo;
import org.aibles.order_service.service.impl.ShoppingCartServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;

class ShoppingCartServiceTest {

    private MasterShoppingCartRepo masterShoppingCartRepo;
    private SlaveShoppingCartRepo slaveShoppingCartRepo;
    private MasterShoppingCartItemRepo masterShoppingCartItemRepo;
    private ShoppingCartService sut;

    @BeforeEach
    void setUp() {
        masterShoppingCartRepo = mock(MasterShoppingCartRepo.class);
        slaveShoppingCartRepo = mock(SlaveShoppingCartRepo.class);
        masterShoppingCartItemRepo = mock(MasterShoppingCartItemRepo.class);
        sut = new ShoppingCartServiceImpl(
                masterShoppingCartRepo, slaveShoppingCartRepo, masterShoppingCartItemRepo);
    }

    @Test
    void addItem_usesAtomicUpsertsOnMaster_only() {
        ShoppingCartAddRequest request = new ShoppingCartAddRequest("prod-1", 2L, 65.0);

        sut.addItem("user-1", request);

        // cart header upserted on master (no slave existence check)
        verify(masterShoppingCartRepo).upsertCart("user-1");

        // item upserted on master with a generated UUID id
        ArgumentCaptor<String> idCaptor = ArgumentCaptor.forClass(String.class);
        verify(masterShoppingCartItemRepo)
                .upsertItem(idCaptor.capture(), eq("user-1"), eq("prod-1"), eq(2L), eq(65.0));
        assertDoesNotThrow(() -> java.util.UUID.fromString(idCaptor.getValue()));

        // the old read-merge-write path is gone
        verifyNoMoreInteractions(masterShoppingCartItemRepo, masterShoppingCartRepo);
        verifyNoInteractions(slaveShoppingCartRepo);
    }
}
