package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.dto.CaptureResponse;
import org.aibles.mockpaypal.dto.CreateOrderRequest;
import org.aibles.mockpaypal.dto.OrderDetailResponse;
import org.aibles.mockpaypal.dto.OrderResponse;
import org.aibles.mockpaypal.dto.PaypalErrorResponse;
import org.aibles.mockpaypal.dto.PaypalLink;
import org.aibles.mockpaypal.dto.PurchaseUnitView;
import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.aibles.mockpaypal.store.OrderStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

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

    @PostMapping("/v2/checkout/orders/{token}/capture")
    public ResponseEntity<?> capture(@PathVariable String token) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(new PaypalErrorResponse("RESOURCE_NOT_FOUND", "Unknown order " + token));
        }
        if (state.getDecision() == Decision.FAIL) {
            return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY)
                    .body(new PaypalErrorResponse("UNPROCESSABLE_ENTITY",
                            "The instrument presented was either declined by the processor or bank, or it can't be used for this payment."));
        }
        String captureId = "MOCKCAP-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        store.setCapture(token, captureId);
        return ResponseEntity.ok(new CaptureResponse(
                token, "COMPLETED", "CAPTURE",
                List.of(purchaseUnitView(state, captureId))));
    }

    @GetMapping("/v2/checkout/orders/{token}")
    public ResponseEntity<?> details(@PathVariable String token) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(new PaypalErrorResponse("RESOURCE_NOT_FOUND", "Unknown order " + token));
        }
        String status = state.getCaptureId() != null ? "COMPLETED" : "APPROVED";
        return ResponseEntity.ok(new OrderDetailResponse(
                token, "CAPTURE", status,
                List.of(purchaseUnitView(state, state.getCaptureId())),
                List.of()));
    }

    private PurchaseUnitView purchaseUnitView(OrderState state, String captureId) {
        PurchaseUnitView.Payments payments = null;
        if (captureId != null) {
            payments = new PurchaseUnitView.Payments(List.of(
                    new PurchaseUnitView.Capture(captureId, "COMPLETED", state.getOrderId())));
        }
        return new PurchaseUnitView(
                new PurchaseUnitView.Amount(state.getCurrencyCode(), state.getValue()),
                state.getOrderId(),
                payments);
    }
}
