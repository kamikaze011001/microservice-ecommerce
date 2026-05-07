# core-email

Transactional email via Spring Mail + Thymeleaf templates. Used primarily by authorization-server (OTP, registration confirms).

## Layout
- `framework/configuration/` — `JavaMailSender` bean wiring (host/port/credentials from Vault)
- `framework/repository/` + `adapter/repository/` — outbound email persistence (audit/retry)
- `business/email/` — service interfaces and impls
- `resources/otp-template/` — Thymeleaf HTML templates

## Convention
SMTP credentials live in Vault, not application.yml. A service that pulls in this module **must** include readiness `mail` in its actuator config (authorization-server is the reference).

## Templates
HTML in `resources/otp-template/`. Variables passed as a `Map<String, Object>`. Localization isn't built in — add a locale param if you need multi-language.
