package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.dto.CreateOrderRequest;
import org.aibles.mockpaypal.dto.OrderResponse;
import org.aibles.mockpaypal.dto.PaypalLink;
import org.aibles.mockpaypal.model.OrderState;
import org.aibles.mockpaypal.store.OrderStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
public class OrdersController {

    private final OrderStore store;
    private final String publicBaseUrl;

    public OrdersController(OrderStore store,
                            @Value("${mock.public-base-url}") String publicBaseUrl) {
        this.store = store;
        this.publicBaseUrl = publicBaseUrl;
    }

    @PostMapping("/v2/checkout/orders")
    public OrderResponse createOrder(@RequestBody CreateOrderRequest req) {
        CreateOrderRequest.PurchaseUnit pu = req.getPurchaseUnits().get(0);
        CreateOrderRequest.ExperienceContext ctx =
                req.getPaymentSource().getPaypal().getExperienceContext();

        OrderState state = store.create(
                pu.getCustomId(),
                pu.getAmount().getCurrencyCode(),
                pu.getAmount().getValue(),
                ctx.getReturnUrl(),
                ctx.getCancelUrl());

        String approveHref = publicBaseUrl + "/checkout?token=" + state.getToken();
        List<PaypalLink> links = List.of(
                new PaypalLink(publicBaseUrl + "/v2/checkout/orders/" + state.getToken(), "self", "GET"),
                new PaypalLink(approveHref, "approve", "GET"),
                new PaypalLink(approveHref, "payer-action", "GET"));

        return new OrderResponse(state.getToken(), "PAYER_ACTION_REQUIRED", links);
    }
}
