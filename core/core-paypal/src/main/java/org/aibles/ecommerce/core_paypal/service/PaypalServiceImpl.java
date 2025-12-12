package org.aibles.ecommerce.core_paypal.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_paypal.configuration.PaypalConfiguration;
import org.aibles.ecommerce.core_paypal.dto.CreatePaypalOrderRequest;
import org.aibles.ecommerce.core_paypal.dto.paypal.*;
import org.aibles.ecommerce.core_paypal.dto.paypal.payment.PaymentExperienceContext;
import org.aibles.ecommerce.core_paypal.dto.paypal.payment.PaypalDetail;
import org.springframework.http.*;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestTemplate;

import java.util.Base64;
import java.util.List;
import java.util.Objects;

@Service
@Slf4j
public class PaypalServiceImpl implements PaypalService {


    private final RestTemplate restTemplate;

    private final PaypalConfiguration paypalConfiguration;


    public PaypalServiceImpl(RestTemplate paypalRestTemplate, PaypalConfiguration paypalConfiguration) {
        this.restTemplate = paypalRestTemplate;
        this.paypalConfiguration = paypalConfiguration;
    }

    @Override
    public PaypalOrderSimple createOrder(List<CreatePaypalOrderRequest> createPaypalOrderRequests) {
        String accessToken = getAccessToken();
        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth(accessToken);
        headers.setContentType(MediaType.APPLICATION_JSON);

        List<PurchaseUnit> purchaseUnits = getPurchaseUnits(createPaypalOrderRequests);

        PaymentSource paymentSource = getPaymentSource();


        PaypalOrderRequest paypalOrderRequest = new PaypalOrderRequest("CAPTURE",
                purchaseUnits,
                paymentSource);
        log.info("(createOrder)orderRequest {}", paypalOrderRequest);
        HttpEntity<PaypalOrderRequest> entity = new HttpEntity<>(paypalOrderRequest, headers);

        ResponseEntity<PaypalOrderSimple> response = restTemplate.postForEntity(
                paypalConfiguration.getBaseUrl() + "/v2/checkout/orders",
                entity,
                PaypalOrderSimple.class
        );

        return response.getBody();
    }

    private List<PurchaseUnit> getPurchaseUnits(List<CreatePaypalOrderRequest> createPaypalOrderRequests) {
        return createPaypalOrderRequests.stream().map(orderReq -> {
            PaypalAmount amount = new PaypalAmount("USD", String.format("%.2f", orderReq.getAmount()));
            PurchaseUnit purchaseUnit = new PurchaseUnit();
            purchaseUnit.setAmount(amount);
            purchaseUnit.setCustomId(orderReq.getOrderId());
            return purchaseUnit;
        }).toList();
    }

    private PaymentSource getPaymentSource() {
        String successUrl = paypalConfiguration.getTunnelUrl() + paypalConfiguration.getSuccessPath();
        String cancelUrl = paypalConfiguration.getTunnelUrl() + paypalConfiguration.getCancelPath();

        PaymentSource paymentSource = new PaymentSource();

        PaypalDetail paypalDetail = new PaypalDetail();
        PaymentExperienceContext paypalContext = new PaymentExperienceContext();
        paypalContext.setReturnUrl(successUrl);
        paypalContext.setCancelUrl(cancelUrl);
        paypalDetail.setExperienceContext(paypalContext);

        paymentSource.setPaypal(paypalDetail);
        return paymentSource;
    }


    @Override
    public PaypalCaptureResponse captureOrder(String paypalToken) {
        String accessToken = getAccessToken();

        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth(accessToken);
        headers.setContentType(MediaType.APPLICATION_JSON);

        HttpEntity<Void> entity = new HttpEntity<>(headers);

        ResponseEntity<PaypalCaptureResponse> response = restTemplate.exchange(
                paypalConfiguration.getBaseUrl() + "/v2/checkout/orders/" + paypalToken + "/capture",
                HttpMethod.POST,
                entity,
                PaypalCaptureResponse.class
        );
        return response.getBody();
    }

    @Override
    public PaypalOrderDetail getOrderDetails(String paypalToken) {
        String accessToken = getAccessToken();

        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth(accessToken);
        headers.setContentType(MediaType.APPLICATION_JSON);

        HttpEntity<Void> entity = new HttpEntity<>(headers);

        ResponseEntity<PaypalOrderDetail> response = restTemplate.exchange(
                paypalConfiguration.getBaseUrl() + "/v2/checkout/orders/" + paypalToken,
                HttpMethod.GET,
                entity,
                PaypalOrderDetail.class
        );

        return response.getBody();
    }

    @Override
    public PaypalRefundResponse refundPayment(String captureId, String orderId, double refundAmount) {
        String accessToken = getAccessToken();

        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth(accessToken);
        headers.setContentType(MediaType.APPLICATION_JSON);

        PaypalRefundRequest refundRequest = getPaypalRefundRequest(orderId, refundAmount);

        HttpEntity<PaypalRefundRequest> entity = new HttpEntity<>(refundRequest, headers);

        ResponseEntity<PaypalRefundResponse> response = restTemplate.exchange(
                paypalConfiguration.getBaseUrl() + "/v2/payments/captures/" + captureId + "/refund",
                HttpMethod.POST,
                entity,
                PaypalRefundResponse.class
        );

        return response.getBody();
    }

    private PaypalRefundRequest getPaypalRefundRequest(String orderId, double refundAmount) {
        PaypalRefundRequest refundRequest = new PaypalRefundRequest();
        PaypalAmount amount = new PaypalAmount("USD", String.format("%.2f", refundAmount));
        refundRequest.setAmount(amount);
        refundRequest.setCustomId(orderId);
        return refundRequest;
    }

    private String getAccessToken() {
        String clientId = paypalConfiguration.getClientId();
        String clientSecret = paypalConfiguration.getClientSecret();
        String baseUrl = paypalConfiguration.getBaseUrl();

        // Mask sensitive data in logs
        String maskedClientId = clientId != null && clientId.length() > 8
            ? clientId.substring(0, 8) + "..."
            : "NOT_SET";
        String maskedClientSecret = clientSecret != null && !clientSecret.isEmpty()
            ? "****" + clientSecret.substring(clientSecret.length() - 4)
            : "NOT_SET";

        log.info("(getAccessToken) Attempting PayPal OAuth with clientId: {}, clientSecret: {}, baseUrl: {}",
                clientId, clientSecret, baseUrl);

        if (clientId == null || clientId.isEmpty() || clientSecret == null || clientSecret.isEmpty()) {
            log.error("(getAccessToken) CRITICAL: PayPal credentials not set! Check PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET environment variables");
            throw new IllegalStateException("PayPal credentials not configured");
        }

        String auth = clientId + ":" + clientSecret;
        String encodedAuth = Base64.getEncoder().encodeToString(auth.getBytes());

        HttpHeaders headers = new HttpHeaders();
        headers.set("Authorization", "Basic " + encodedAuth);
        headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);

        HttpEntity<String> entity = new HttpEntity<>("grant_type=client_credentials", headers);

        log.info("(getAccessToken) Sending OAuth request to: {}", baseUrl + "/v1/oauth2/token");

        ResponseEntity<AuthPaypalResponse> response = restTemplate.postForEntity(
                baseUrl + "/v1/oauth2/token",
                entity,
                AuthPaypalResponse.class
        );

        log.info("(getAccessToken) Successfully obtained PayPal access token");
        return Objects.requireNonNull(response.getBody()).getAccessToken();
    }
}
