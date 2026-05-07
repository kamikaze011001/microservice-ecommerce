# core-paypal

PayPal REST SDK wrapper. Used by payment-service.

## Layout
- `configuration/` — PayPal HTTP client bean (mode + credentials from Vault)
- `service/` — facade methods (create order, capture, refund)
- `dto/paypal/` — PayPal API request/response types
- `dto/` — internal DTOs the wrapper exposes

## Convention
Don't import `com.paypal.*` directly outside this module. If you need a PayPal call payment-service can't already make, add the method here and expose it via the existing service.

## Modes
`sandbox` vs `live` selected via Vault, not application.yml. Switching environments is a Vault-only change.
