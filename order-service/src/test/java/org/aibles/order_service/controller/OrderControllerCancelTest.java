package org.aibles.order_service.controller;

import org.aibles.ecommerce.common_dto.exception.OrderAlreadyCanceledException;
import org.aibles.ecommerce.common_dto.exception.OrderNotCancellableException;
import org.aibles.ecommerce.core_exception_api.configuration.CoreApiExceptionConfiguration;
import org.aibles.ecommerce.core_exception_api.configuration.MessageResourcesProperties;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderCancelResponse;
import org.aibles.order_service.service.OrderService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = OrderController.class,
    excludeAutoConfiguration = {
        org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration.class,
        org.springframework.boot.autoconfigure.security.servlet.SecurityFilterAutoConfiguration.class
    })
@Import({CoreApiExceptionConfiguration.class, MessageResourcesProperties.class})
@AutoConfigureMockMvc(addFilters = false)
class OrderControllerCancelTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private OrderService orderService;

    @Test
    void cancelHappyPath_returnsCanceled() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o1")))
            .thenReturn(OrderCancelResponse.builder()
                .orderId("o1").status(OrderStatus.CANCELED).build());

        mvc.perform(patch("/v1/orders/o1:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.order_id").value("o1"))
            .andExpect(jsonPath("$.data.status").value("CANCELED"));
    }

    @Test
    void cancelNotCancellable_returns409() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o2")))
            .thenThrow(new OrderNotCancellableException());

        mvc.perform(patch("/v1/orders/o2:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isConflict());
    }

    @Test
    void cancelAlreadyCanceled_returns409() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o3")))
            .thenThrow(new OrderAlreadyCanceledException());

        mvc.perform(patch("/v1/orders/o3:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isConflict());
    }
}
