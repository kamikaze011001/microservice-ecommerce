# mock-paypal-service

Mocks PayPal's REST API so k6 stress runs and the local frontend can exercise the full
payment flow (success / cancel / fail) without touching real PayPal. Port `8585`.

## Java 25 — not 17
This is the one module that does **not** target Java 17. Build and run it with a JDK 25
toolchain (`JAVA_HOME=25.0.3-tem` via sdkman). Java 24 is EOL and will not install.

## Switching payment-service onto the mock
Config-only — no code change. Point `application.paypal.base-url` at:

```
http://<host>:8585/mock-paypal-service
```

## Choosing the outcome
The approve / cancel / fail decision is made by the caller, not the service:
- Browser: chosen on the `/checkout` page
- k6: via the `?decision=` query parameter

`fail` returns **HTTP 422** from capture, which is what triggers `PaymentFailed` downstream.

## Single replica by design
Token state is held in memory per-token. Do not scale this to more than one replica —
a second instance won't recognise the first's tokens.

See `README.md` in this directory for the endpoint list.
