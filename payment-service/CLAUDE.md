# payment-service

Payment lifecycle. PayPal integration via `core-paypal`. Emits `PaymentSuccess/Failed/Canceled` events.

## Port & path
- App: `8484`
- Context path: `/payment-service`
- Vault: PayPal client id/secret live here

## Layout
- `controller/` — `/v1/payments` (create, capture, webhook return URLs)
- `service/` — payment orchestration (manual `@Bean` wiring)
- `repository/master/` + `repository/slave/`
- `entity/` — payment records
- `listener/` — Kafka consumers (order events)

## Flow
1. Order-service publishes order created → orchestrator triggers payment
2. payment-service creates PayPal order, returns approve URL
3. User approves on PayPal → return URL → capture
4. Service emits `PaymentSuccessEvent` / `PaymentFailedEvent` / `PaymentCanceledEvent`
5. order-service listener updates order status

## Notes
- PayPal SDK lives in `core/core-paypal` — don't pull the raw SDK here.
- Sandbox vs live mode toggled in Vault, not application.yml.
- Webhook return URLs are configured per environment; in local dev they point at the gateway, which routes back to this service.
