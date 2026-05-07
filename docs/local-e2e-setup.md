# Local E2E setup — register-with-email + checkout-with-PayPal

This doc walks you through everything needed, on a fresh dev box, to exercise
two flows end-to-end:

1. **Register a new account → receive activation email → activate → log in.**
2. **Add items to cart → checkout → pay with PayPal sandbox → return to app
   with order marked PAID.**

Pre-req: `make bootstrap && make up` is green and `make status` shows all nine
JVM services running.

---

## 1. Gmail SMTP (activation email)

The auth-server reads `spring.mail.*` from Vault `secret/ecommerce`. Out of
the box those are placeholder values, so the SMTP send silently fails after
register and no email arrives.

### 1.1 Create a Gmail App Password

You need an App Password — Gmail will reject the regular account password
over SMTP when 2FA is on (and it must be on).

1. https://myaccount.google.com/security → enable **2-Step Verification** if
   it isn't already.
2. https://myaccount.google.com/apppasswords → "App name" = anything (e.g.
   `ecommerce-dev`) → **Create**. Copy the 16-character value (no spaces).

### 1.2 Patch Vault and restart auth-server

```bash
# replace the two values below
docker exec \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  dev-vault \
  vault kv patch secret/ecommerce \
    spring.mail.username='you@gmail.com' \
    spring.mail.password='abcdefghijklmnop'

bash scripts/services/stop.sh authorization-server
bash scripts/services/start.sh authorization-server
```

> `${VAULT_TOKEN}` is the dev-mode root token from `docker/.env`. Source the
> file (`set -a; source docker/.env; set +a`) or paste the value inline.
> Never commit the literal token to git.

### 1.3 Sanity check

`tail -f logs/authorization-server.log` while you hit register; you want a
`MailSender` line, not `AuthenticationFailedException`.

---

## 2. PayPal sandbox credentials

Payment-service reads `application.paypal.client-id` /
`application.paypal.client-secret` from Vault `secret/payment-service`. Those
are also placeholders.

### 2.1 Create the sandbox app

1. https://developer.paypal.com → sign in (any PayPal account works; create
   a free one if needed — no real bank info required for sandbox).
2. Top nav → **Apps & Credentials** → switch the toggle to **Sandbox**
   (not Live).
3. There's a pre-created "Default Application" — click it. Copy:
   - **Client ID**
   - **Secret** (hit "Show")

### 2.2 Grab a sandbox buyer login

Same site → **Testing Tools → Sandbox Accounts**. Two accounts are pre-made:

| Type     | Use                                                          |
| -------- | ------------------------------------------------------------ |
| Business | This is the merchant ("you") — money lands here. Don't log in with this. |
| Personal | The **buyer** — use this email + password on the PayPal approve page during checkout. |

Click the Personal account → "..." → **View/Edit Account** → password tab to
reveal the password. Note both email and password.

### 2.3 Patch `.env` and Vault, restart payment-service

```bash
# .env — for any local consumers that read directly from .env
sed -i '' \
  -e 's|^PAYPAL_CLIENT_ID=.*|PAYPAL_CLIENT_ID=<paste client id>|' \
  -e 's|^PAYPAL_CLIENT_SECRET=.*|PAYPAL_CLIENT_SECRET=<paste secret>|' \
  docker/.env

# Vault — payment-service reads from here at boot
docker exec \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  dev-vault \
  vault kv patch secret/payment-service \
    application.paypal.client-id='<paste client id>' \
    application.paypal.client-secret='<paste secret>'

bash scripts/services/stop.sh payment-service
bash scripts/services/start.sh payment-service
```

---

## 3. Public tunnel (PayPal callback)

PayPal redirects the buyer back to `${tunnel-url}/payment-service/v1/paypal:success`
after approval, and hits the same host for cancel. That URL must be reachable
from the public internet — `localhost` won't do. Without this step the buyer
approves payment but the order stays `PENDING` forever (capture never runs).

The tunnel must point at the **gateway port `6868`**, not at payment-service
directly, because the callback path includes `/payment-service/...` which the
gateway routes via context-path.

### 3.1 Pick a tunnel tool

Either ngrok or cloudflared. Both are free for dev.

```bash
# Option A — ngrok (sign up once, copy auth token, then run anywhere)
brew install ngrok
ngrok config add-authtoken <YOUR_NGROK_TOKEN>
ngrok http 6868

# Option B — cloudflared (no signup for quick tunnels)
brew install cloudflared
cloudflared tunnel --url http://localhost:6868
```

Either prints a public https URL, e.g. `https://abc-123.ngrok-free.app` or
`https://random-words.trycloudflare.com`. Copy it (no trailing slash).

### 3.2 Patch `.env` and Vault, restart payment-service

```bash
TUNNEL_URL='https://abc-123.ngrok-free.app'   # the value you just copied

sed -i '' "s|^PAYPAL_TUNNEL_URL=.*|PAYPAL_TUNNEL_URL=${TUNNEL_URL}|" docker/.env

docker exec \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  dev-vault \
  vault kv patch secret/payment-service \
    application.paypal.tunnel-url="${TUNNEL_URL}"

bash scripts/services/stop.sh payment-service
bash scripts/services/start.sh payment-service
```

### 3.3 Smoke-check the tunnel

Visit `${TUNNEL_URL}/gateway/actuator/health` (or just hit the root and expect
the gateway 404 page) from a browser **outside** your machine, or:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "${TUNNEL_URL}"
```

Anything other than `000` / connection-refused means the tunnel is alive.

> **Tunnel URLs change every restart** for free ngrok/cloudflared. If your
> tunnel restarts, you must repeat 3.2 — payment-service caches the value
> at boot.

---

## 4. Run the two flows

### 4.1 Flow A — Register + activate

1. Open http://localhost:5173/register.
2. Fill name / email / password. **Use a real Gmail inbox you can read.**
3. Submit. Frontend hits `POST /authorization-server/v1/auth:register`, the
   server saves the user as inactive and triggers `MailService.send()`.
4. Check the inbox of the email you registered with — there should be an
   activation code (subject usually contains "activation"). It can take a
   few seconds.
5. Open http://localhost:5173/activate, paste the code, submit. Server hits
   `POST /authorization-server/v1/auth:activate` and flips the user active.
6. Log in at http://localhost:5173/login.

If no email arrives:

- Check `logs/authorization-server.log` for SMTP errors. Common ones:
  - `535 5.7.8 Username and Password not accepted` → Vault has the wrong
    password, or 2FA isn't on, or you used the regular password instead of
    the App Password.
  - `Could not connect to SMTP host` → outbound port 587 blocked (corp VPN?).

### 4.2 Flow B — Shop + pay

1. While logged in, browse http://localhost:5173/products. Add a product
   whose seeded stock is non-zero (e.g. the first product in the manifest is
   30; product `…004` is intentionally 0 and will be blocked).
2. Click **CART** in the nav. The badge shows total quantity.
3. Hit checkout → http://localhost:5173/checkout. The frontend places the
   order via order-service (`POST /order-service/v1/orders`), gets back an
   `orderId`.
4. CheckoutPage immediately calls `POST /payment-service/v1/payments?orderId=…`.
   Payment-service calls PayPal `POST /v2/checkout/orders` with your sandbox
   creds, gets back an `approve` link, returns it. Frontend redirects there.
5. On the PayPal sandbox page, log in with the **Personal** sandbox account
   from §2.2. Approve the payment.
6. PayPal redirects to `${PAYPAL_TUNNEL_URL}/payment-service/v1/paypal:success?token=…`.
   Tunnel forwards to gateway → payment-service. Payment-service calls PayPal
   `POST /v2/checkout/orders/{id}/capture`, publishes a `PaymentSuccess`
   Kafka event.
7. Inventory listener decrements `product_quantity_history`. Order moves to
   PAID. Browser lands on http://localhost:5173/payment/success.
8. The order shows up at http://localhost:5173/orders.

If you click cancel on the PayPal page, you land on `/payment/cancel` and
the order stays PENDING (eventually expired by the saga timer).

---

## Quick reference

| Need to change             | Where                                                                 | Restart                |
| -------------------------- | --------------------------------------------------------------------- | ---------------------- |
| Gmail App Password         | Vault `secret/ecommerce` → `spring.mail.username` / `spring.mail.password` | authorization-server   |
| PayPal client id/secret    | `.env` + Vault `secret/payment-service` → `application.paypal.client-id` / `client-secret` | payment-service        |
| PayPal tunnel URL          | `.env` `PAYPAL_TUNNEL_URL` + Vault `secret/payment-service` → `application.paypal.tunnel-url` | payment-service        |

The dev-mode root Vault token lives in `docker/.env` as `VAULT_TOKEN`. If you
recreate the Vault container, the token rotates — re-read the env file before
patching.
