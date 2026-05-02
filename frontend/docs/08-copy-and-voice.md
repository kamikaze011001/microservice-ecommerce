# Copy & voice — Issue Nº01

The storefront reads like a printed risograph zine catalog. Copy is the second-loudest expression of that identity (after type). Words count.

## Voice

- **Present tense, declarative.** "Loading." not "Just a moment, we're loading the products for you!"
- **Condensed and concrete.** "0 lots." beats "There are no products available at this time."
- **Title case for stamps and CTAs, sentence case for body.** Exception: page numerals and section headers are SCREAMING CAPS.
- **Mono font for IDs, prices, timestamps, kicker labels.** Body font for human prose.
- **Never sentimental.** No "Oops!", "Whoops!", "Looks like…", "We're sorry but…".
- **Print-shop voice over tech voice.** "Pressed" not "Submitted". "Out of stock" stamps as "SOLD OUT".

The voice is **printer-shop deadpan**. Like the kind of text you'd see on a packing slip from a small-batch zine maker.

## Copy bank

### Empty states

| Where                 | Copy                                                |
| --------------------- | --------------------------------------------------- |
| Empty product catalog | "Issue Nº01 coming soon."                           |
| Empty cart            | "Your cart is empty. Browse the lots."              |
| Empty orders          | "No orders yet. Start at issue one."                |
| Empty search results  | "No matches for «{query}». Try another lot number." |

### Loading states

| Where                           | Copy                   |
| ------------------------------- | ---------------------- |
| Skeleton card label (a11y only) | "Loading lot."         |
| Submit-pending button           | "STAMPING…"            |
| Payment-verifying stamp         | "VERIFYING…"           |
| Saga/pollin'-for-paid           | "AWAITING IMPRESSION…" |

No spinners. Skeleton cards or stamp animations only.

### Error states

Match the API error taxonomy in [`04-api-conventions.md`](./04-api-conventions.md).

| Class                         | Default copy               |
| ----------------------------- | -------------------------- |
| `auth-required`               | (silent — redirect)        |
| `forbidden`                   | "Not allowed."             |
| `not-found` (route)           | "404 — lot not found."     |
| `not-found` (component)       | "Nothing here."            |
| `validation` (form, fallback) | server-provided message    |
| `server`                      | "Server error. Try again." |
| `network`                     | "Connection lost. Retry?"  |

### Status stamps

Order status renders as `<BStamp>`. Copy is uppercase, mono.

| Status     | Stamp        |
| ---------- | ------------ |
| PROCESSING | "PROCESSING" |
| PAID       | "PAID"       |
| SHIPPED    | "SHIPPED"    |
| DELIVERED  | "DELIVERED"  |
| CANCELED   | "CANCELED"   |
| FAILED     | "FAILED"     |

Inventory:

| Inventory | Stamp       |
| --------- | ----------- |
| > 10      | "IN STOCK"  |
| 1–10      | "LOW STOCK" |
| 0         | "SOLD OUT"  |

### CTAs

Always uppercase, present-tense imperative.

| Action                  | Copy                        |
| ----------------------- | --------------------------- |
| Add to cart (logged in) | "ADD TO CART"               |
| Add to cart (guest)     | "LOGIN TO BUY"              |
| Place order             | "PLACE ORDER" → "STAMPING…" |
| Retry payment           | "RETRY PAYMENT"             |
| Cancel order            | "CANCEL ORDER"              |
| Log in                  | "LOG IN"                    |
| Register                | "REGISTER"                  |
| Log out                 | "LOG OUT"                   |
| View order              | "VIEW ORDER"                |

### Toasts

Toasts are short. One sentence, no period required.

| Trigger                                  | Copy                            |
| ---------------------------------------- | ------------------------------- |
| Add-to-cart success                      | "Added to cart"                 |
| Cancel-order conflict 409                | "Already canceled — refreshed." |
| Server 5xx                               | "Server error — try again"      |
| Network error                            | "Connection lost"               |
| Logout in another tab (this tab notices) | "Signed out in another tab"     |

## Hard rules

- New screen → add its empty / loading / error / CTA copy here before merging.
- Banned words: "Oops", "Whoops", "Sorry", "We", "Our team", "Please", "Just".
- ID-like strings (order IDs, SKUs, prices, timestamps) render in `var(--font-mono)`.
- If you find yourself writing a complete sentence inside a button, stop.
