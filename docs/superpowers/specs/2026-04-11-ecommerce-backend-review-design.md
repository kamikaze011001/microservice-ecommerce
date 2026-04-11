
# E-Commerce Backend Review — Gap Analysis & Microfrontend Alignment Design

**Date:** 2026-04-11
**Context:** Learning project demonstrating microservice patterns (Saga, gRPC, CDC, master-slave DB, event-driven architecture) paired with a microfrontend frontend.
**Goal:** Identify what's implemented, what's missing to support each MFE, and the top risks to address.

---

## 1. What's Implemented

### Infrastructure
- Kafka + Avro + Schema Registry — event streaming with schema enforcement
- MongoDB CDC → Kafka Connect pipeline — change data capture triggering Saga
- Master-slave MySQL (GTID replication, 1 master + 2 slaves) — read/write routing
- HashiCorp Vault — centralized secrets management
- Eureka + Spring Cloud Gateway — service discovery and unified API entry point with aggregated Swagger

### Architectural Patterns Demonstrated
- **Saga orchestration** — distributed transaction across order, inventory, and payment services with compensation and retry (3 strikes, 30-minute TTL)
- **gRPC** — inventory stock validation called synchronously from orchestrator
- **Event-driven** — Kafka producers/consumers with Avro serialization across all services
- **DB read/write routing** — `@EnableRoutingDatasource` with separate master/slave EntityManagers
- **JWT/OAuth2** — RS256 signing, role-based access control, OTP-based activation

### Business Features
| Feature | Service | Status |
|---|---|---|
| Register / activate (OTP) / login | authorization-server | ✅ |
| Password reset (OTP) | authorization-server | ✅ |
| User profile management | authorization-server | ✅ |
| Admin user management | authorization-server | ✅ |
| Product CRUD (MongoDB) | product-service | ✅ |
| Inventory stock management | inventory-service | ✅ |
| Inventory gRPC read endpoint | inventory-service | ✅ |
| Shopping cart (add/update/remove/list) | order-service | ✅ |
| Order creation + lifecycle (PENDING → COMPLETED/FAILED/CANCELED) | order-service | ✅ |
| PayPal payment initiation + IPN callbacks | payment-service | ✅ |
| Saga orchestration with compensation | orchestrator-service | ✅ |

---

## 2. Microfrontend App Map & Backend API Gaps

The frontend is decomposed into 5 micro-apps. Each app's backend requirements are mapped below.

### MFE 1 — Shell App
**Purpose:** Host application, routing, auth state, navigation
**Backend needs:** Login, register, token refresh, user profile
**Status:** ✅ Fully covered — no backend changes needed

---

### MFE 2 — Product Browsing MFE
**Purpose:** Product catalog, keyword search, category filtering, product detail with stock status

| Needed API | Status | Gap Detail |
|---|---|---|
| List products (paginated) | ✅ `GET /v1/products` | Available |
| Get product by ID | ✅ `GET /v1/products/{id}` | Available |
| Search products by keyword | ❌ Missing | No search endpoint; list is pagination-only |
| Filter by category | ❌ Missing | Product entity has no category field |
| Product detail + stock availability | ❌ Missing | Requires aggregating product-service + inventory-service; no combined endpoint |

**Decision:** Add `category` field to Product entity. Add `GET /v1/products?search=&category=` query params. Add BFF aggregate endpoint for product detail + stock.

---

### MFE 3 — Cart & Checkout MFE
**Purpose:** Cart management, checkout flow, payment initiation, order confirmation

| Needed API | Status | Gap Detail |
|---|---|---|
| Cart CRUD | ✅ `/v1/shopping-carts*` | Fully implemented |
| Order creation | ✅ `POST /v1/orders` | Available |
| Payment initiation | ✅ `POST /v1/payments?orderId=` | Available |
| Stock check at add-to-cart | ❌ Missing | Items added without inventory validation |
| Price sync on cart items | ❌ Missing | Stale prices possible if product price changes |

**Decision:** Stock validation at add-to-cart is a P2 concern — acceptable to defer for a learning project. Price staleness is low risk for demo purposes. No blocking gaps for this MFE.

---

### MFE 4 — Account MFE
**Purpose:** User profile, order history, order detail, order status tracking

| Needed API | Status | Gap Detail |
|---|---|---|
| Get/update user profile | ✅ `/v1/users/self` | Available |
| List user's orders | ❌ Missing | No `GET /v1/orders` endpoint in order-service |
| Get single order detail | ❌ Missing | No `GET /v1/orders/{id}` endpoint |
| Order status | ❌ Missing | Status is stored in DB but not exposed via API |

**Decision:** This MFE is completely blocked. Adding `GET /v1/orders` and `GET /v1/orders/{id}` to order-service is **P1 — highest priority**.

---

### MFE 5 — Admin MFE
**Purpose:** Product management, inventory dashboard, order management, user management

| Needed API | Status | Gap Detail |
|---|---|---|
| Product create/read/update | ✅ | Available |
| Product delete | ❌ Missing | No `DELETE /v1/products/{id}` |
| User list/filter/role management | ✅ | Available |
| Inventory list all products | ❌ Missing | Can update stock but no list endpoint |
| Admin order list | ❌ Missing | No admin-facing order endpoints |

**Decision:** Product delete and inventory list are P3. Admin order list is P2 (needed to manage order disputes).

---

## 3. BFF Service

**Why:** Each MFE currently needs to make multiple parallel API calls to compose a single view (e.g., product detail + stock requires hitting product-service and inventory-service separately). A BFF service aggregates these into a single UI-optimized response per MFE.

**What it introduces as a learning pattern:** BFF (Backend for Frontend) — a service layer between the gateway and MFEs that tailors responses to frontend needs rather than domain boundaries.

**Proposed aggregate endpoints:**
- `GET /bff/products/{id}` — product detail + current stock quantity
- `GET /bff/orders/{id}` — order detail + payment status
- `GET /bff/carts` — cart items enriched with current product prices and stock status

**Implementation approach:** New Spring Boot service (`bff-service`) registered with Eureka, routed through the gateway. Calls product-service via REST (Feign client) and inventory-service via gRPC (reusing the existing `InventoryService` proto contract).

---

## 4. Top 3 Risks

### Risk 1 — No order read API (Critical)
**Problem:** Order service creates and updates orders via Kafka events but exposes zero GET endpoints. The Account MFE (order history, order detail, order tracking) cannot render anything.
**Fix:** Add `GET /v1/orders` (list by userId, paginated) and `GET /v1/orders/{id}` to order-service. Route reads to slave DB.
**Effort:** Low — existing `Order` entity, existing master-slave routing infrastructure.

### Risk 2 — PayPal tunnel URL dependency (High for demos)
**Problem:** PayPal IPN callback URLs (success/cancel) point to a local tunnel (ngrok/localtunnel). Every tunnel restart invalidates the URL and payment callbacks break silently — the payment saga gets stuck with no success/cancel event.
**Fix:** Use a static tunnel domain (ngrok paid plan with reserved domain, or deploy payment-service to a cloud VM for demos). Alternatively, add a `/v1/paypal:simulate-success` endpoint for demo purposes only.
**Effort:** Low-medium depending on deployment choice.

### Risk 3 — No product search or categories (Blocks Product Browsing MFE)
**Problem:** Product list is pagination-only. No keyword search, no category field, no filter parameters. The Product Browsing MFE renders a flat paginated grid with no discovery mechanism — the most user-visible part of an e-commerce site.
**Fix:** Add `category` field to Product entity. Add search/filter query params to `GET /v1/products`. For a learning project, simple database LIKE queries are acceptable before adding Elasticsearch.
**Effort:** Low — schema migration + query param handling in product-service.

---

## 5. Implementation Priority

| Priority | Task | Blocks | Effort |
|---|---|---|---|
| P1 | `GET /v1/orders` + `GET /v1/orders/{id}` in order-service | Account MFE | Low |
| P2 | Product `category` field + search/filter query params | Product Browsing MFE | Low |
| P3 | BFF service with aggregate endpoints | All MFEs (performance) | Medium |
| P4 | Stable PayPal callback URL strategy | Payment demos | Low-Medium |
| P5 | `DELETE /v1/products/{id}` + inventory list endpoint | Admin MFE | Low |

---

## 6. Out of Scope (Deferred)

These are real production concerns but intentionally excluded from this learning project's scope:

- Elasticsearch / full-text search engine
- Email notifications for order events (only auth OTP emails currently wired)
- Returns/refunds workflow
- Discounts and coupons
- Shipping/logistics integration
- Wishlist and recommendations
- Sales analytics and reporting
- Comprehensive test coverage
