package org.aibles.mockpaypal.web;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.mockpaypal.dto.PaypalLink;
import org.aibles.mockpaypal.dto.RefundResponse;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
public class RefundController {

    @PostMapping("/v2/payments/captures/{captureId}/refund")
    public RefundResponse refund(@PathVariable String captureId, @RequestBody(required = false) JsonNode body) {
        String customId = body != null && body.hasNonNull("custom_id")
                ? body.get("custom_id").asText() : null;
        double amount = 0.0;
        if (body != null && body.has("amount") && body.get("amount").hasNonNull("value")) {
            amount = Double.parseDouble(body.get("amount").get("value").asText());
        }
        String refundId = "MOCKREFUND-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        return new RefundResponse(refundId, "COMPLETED", customId, amount,
                List.of(new PaypalLink("/v2/payments/refunds/" + refundId, "self", "GET")));
    }
}
