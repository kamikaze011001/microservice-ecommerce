package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.aibles.mockpaypal.store.OrderStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;

@RestController
public class CheckoutPageController {

    private final OrderStore store;
    private final String publicBaseUrl;

    public CheckoutPageController(OrderStore store,
                                  @Value("${mock.public-base-url}") String publicBaseUrl) {
        this.store = store;
        this.publicBaseUrl = publicBaseUrl;
    }

    @GetMapping("/checkout")
    public ResponseEntity<String> checkout(@RequestParam String token,
                                           @RequestParam(required = false) String decision) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body("Unknown token: " + token);
        }

        if (decision == null) {
            return ResponseEntity.ok()
                    .contentType(MediaType.TEXT_HTML)
                    .body(renderPage(token, state));
        }

        return switch (decision) {
            case "approve" -> {
                store.setDecision(token, Decision.APPROVE);
                yield redirect(withReturnParams(state.getReturnUrl(), token));
            }
            case "fail" -> {
                store.setDecision(token, Decision.FAIL);
                yield redirect(withReturnParams(state.getReturnUrl(), token));
            }
            case "cancel" -> {
                store.setDecision(token, Decision.CANCEL);
                yield redirect(withReturnParams(state.getCancelUrl(), token));
            }
            default -> ResponseEntity.badRequest().body("Unknown decision: " + decision);
        };
    }

    // Real PayPal appends ?token=<order-id>&PayerID=<id> to the return/cancel URL
    // when it bounces the approver back to the merchant. payment-service's IPN
    // handlers read the order id from @RequestParam("token"), so redirecting to a
    // bare return URL fails with 400 (MissingServletRequestParameterException).
    // Mirror PayPal so the capture step can resolve the order.
    private String withReturnParams(String url, String token) {
        String sep = url.contains("?") ? "&" : "?";
        return url + sep + "token=" + token + "&PayerID=MOCKPAYERID";
    }

    private ResponseEntity<String> redirect(String location) {
        return ResponseEntity.status(HttpStatus.FOUND).location(URI.create(location)).build();
    }

    private String renderPage(String token, OrderState state) {
        String base = publicBaseUrl + "/checkout?token=" + token + "&decision=";
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <title>Mock PayPal Checkout</title></head>
            <body style="font-family:sans-serif;max-width:420px;margin:60px auto;text-align:center">
            <h2>Mock PayPal</h2>
            <p>Order <code>%s</code> &mdash; <b>%s %s</b></p>
            <p>
              <a href="%sapprove" style="display:inline-block;padding:12px 20px;background:#0070ba;color:#fff;text-decoration:none;border-radius:6px">Approve</a>
              <a href="%scancel"  style="display:inline-block;padding:12px 20px;background:#888;color:#fff;text-decoration:none;border-radius:6px">Cancel</a>
              <a href="%sfail"    style="display:inline-block;padding:12px 20px;background:#c0392b;color:#fff;text-decoration:none;border-radius:6px">Fail</a>
            </p></body></html>
            """.formatted(state.getOrderId(), state.getValue(), state.getCurrencyCode(),
                          base, base, base);
    }
}
