package org.aibles.ecommerce.core_paypal.service;

import org.aibles.ecommerce.core_paypal.dto.CreatePaypalOrderRequest;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRefundResponse;

import java.util.List;

public interface PaypalService {

    /**
     * Creates a PayPal order for the specified amount and links it to the system's order ID.
     *
     * @param createPaypalOrderRequests List of order need to purchase
     * @return The PayPal order response with details of the created order.
     */
    PaypalOrderSimple createOrder(List<CreatePaypalOrderRequest> createPaypalOrderRequests);

    /**
     * Captures a PayPal order to finalize the payment.
     *
     * @param paypalToken The PayPal order ID.
     */
    PaypalCaptureResponse captureOrder(String paypalToken);

    /**
     * Retrieves the details of a PayPal order.
     *
     * @param paypalToken The PayPal order ID.
     * @return The details of the PayPal order.
     */
    PaypalOrderDetail getOrderDetails(String paypalToken);

    /**
     * Refund a purchase unit by capture id
     * @param captureId - Capture id from payments portion
     * @param orderId - From custom id
     * @param refundAmount - Amount of this order
     * @return
     */
    PaypalRefundResponse refundPayment(String captureId, String orderId, double refundAmount);
}
