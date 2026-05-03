# Phase 6: Account & Order History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read the spec at `docs/superpowers/specs/2026-05-03-phase-6-account-orders-design.md` before starting any task — it carries the rationale this plan compresses.

**Goal:** Build the post-purchase account experience — profile management and order history — using a sidebar account shell at `/account` with three child routes.

**Architecture:** Snapshot product name/image into `order_item` rows at create time (decouples order history from product-service). Tighten BFF order detail to typed views, no product-service runtime call. Frontend account shell with nested routes, vue-query everywhere, VeeValidate+Zod for forms.

**Tech Stack:** Spring Boot 3.3.6 + Java 17 + MySQL 8 (order-service, bff-service); Vue 3 + TypeScript + Vite + Tailwind v4 + `@tanstack/vue-query` + VeeValidate 4.15 + Zod (frontend); Vitest + `@testing-library/vue` + `vi.mock` for FE tests (no MSW).

**Reference:** Phase 5 plan (`docs/superpowers/plans/2026-05-03-phase-5-buy-flow.md`) is the gold-standard for patterns — query module shape, page tests with `vi.mock`, VeeValidate setup, mutation chaining, BDialog usage, BImageFallback, useToast, primitives barrel imports. When this plan is terse on a "how", read the equivalent Phase 5 task.

**FE conventions to follow** (Phase 5 baked-in):
- Test commands: `pnpm test path/to/file.spec.ts`, `pnpm typecheck`, `pnpm lint`. Never `npm`.
- Primitives barrel: `@/components/primitives` exports `BButton`, `BCard`, `BDialog`, `BInput`, `BSelect`, `BTag`, `BStamp`, `BToast`, `BCropmarks`, `BMarginNumeral`. `BImageFallback` lives at `@/components/BImageFallback`. `useToast` lives at `@/composables/useToast`.
- Query layer pattern: `useXyzQuery` returns `useQuery({ queryKey, queryFn })`. Mutations call `queryClient.invalidateQueries({ queryKey })` on success.
- API responses are wrapped in `BaseResponse.data`. Use `apiFetch<T>(path, init)` from `@/api/client` to unwrap; openapi-fetch `client` for typed endpoints when payload casting is acceptable.
- Page tests mock the query module (`vi.mock('@/api/queries/...')`), provide stub `mutateAsync` + `isPending: { value: false }` refs, render via `@testing-library/vue` with `[router, [VueQueryPlugin, { queryClient: new QueryClient() }]]` plugins.

**BE conventions** (already established in repo):
- DTOs are records with `@JsonNaming(SnakeCaseStrategy.class)` — Java camelCase fields → JSON snake_case.
- Service impls are wired via `@Configuration` `@Bean` methods, **not** `@Service`. When you add a constructor parameter, update the bean in `OrderServiceConfiguration` / `BffServiceConfiguration`.
- JPA repositories live in `repository/master/` (writes) and `repository/slave/` (reads).
- BaseResponse factories: `BaseResponse.ok(data)` etc.
- Migrations in `src/main/resources/db/migration/V###__name.sql`. Number must be sequential per service.

**Visual Direction (BINDING):** Read the **Visual Direction** section of the spec before any FE task. The storefront is editorial / risograph-zine — outlined display numerals, `BStamp`, `BCropmarks`, `BMarginNumeral`, mono uppercase, single `--spot` accent. Phase 6 must match. Concrete deltas the spec mandates and this plan inherits:
- Account shell is a **horizontal masthead tab strip**, NOT a 240px sidebar. Tabs read `MASTHEAD · LEDGER · RECEIPT`.
- `OrderStatusStamp.vue` → renamed **`OrderStatusStamp.vue`**, wraps `BStamp` (no colored pill backgrounds).
- `OrderReceiptRow.vue` → renamed **`OrderReceiptRow.vue`**, full-width receipt row, not a card-with-shadow.
- Page titles: orders list = `THE LEDGER` with folio numeral; detail = `RECEIPT Nº{last8}`; profile sections = `01 — MASTHEAD`, `02 — COLOPHON`, `03 — CREDENTIALS`.
- Status vocabulary: `PENDING`, `IN PRESS`, `PAID`, `VOIDED`, `MISFIRE` (one `--spot` color only — no green/red/blue).
- Empty: `LEDGER UNPRINTED`. Loading: `INKING…` / `STAMPING…`. Cancel modal: `VOID THIS ORDER? STAMP IS PERMANENT.`
- Order detail items render as a typeset bill with leader dots; items block wrapped in `<BCropmarks>`; totals block reverses to ink-on-`--spot`.
- Pagination on orders list reuses `home__pager` mono-button treatment from `HomePage.vue` verbatim.

If a Phase 6 page doesn't use at least two of `BStamp` / `BCropmarks` / `BMarginNumeral` / outlined-numeral folio, it's wrong — push back before merging.

**Commit-message scopes used in repo:** `feat(order-service):`, `feat(bff):`, `feat(fe):`, `fix(fe):`, `refactor(bff):`, `test(order-service):`, `docs:`. Always end commits with HEREDOC and `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.

---

## Task 1: Cut feat/phase-6-account branch

**Files:** none.

- [ ] **Step 1:** Verify current state.

```bash
git status
git log --oneline -1
```

Expected: clean working tree on `main` at `aaf67db docs: add Phase 6 account & order history design spec` (or later — just confirm spec is in HEAD).

- [ ] **Step 2:** Update main and cut branch.

```bash
git checkout main && git pull --ff-only origin main && git checkout -b feat/phase-6-account
```

Expected: `Switched to a new branch 'feat/phase-6-account'`.

No commit. No tests.

---

## Task 2: order-service migration + OrderItem entity snapshot fields

**Goal:** Add nullable `product_name VARCHAR(255)` + `image_url VARCHAR(512)` columns to `order_item`, expose as fields on the JPA entity. Existing rows unaffected.

**Files:**
- Create: `order-service/src/main/resources/db/migration/V<NEXT>__order_item_snapshot_fields.sql` (find next number with `ls order-service/src/main/resources/db/migration/`)
- Modify: `order-service/src/main/java/**/entity/OrderItem.java` (find with `find order-service -name OrderItem.java -path '*/entity/*'`)
- Test: `order-service/src/test/java/**/repository/OrderItemRepositoryTest.java` (extend existing or create a focused new test if none exists)

**Steps:**

- [ ] **Step 1:** Find existing migrations and entity. `ls order-service/src/main/resources/db/migration/` and `find order-service -name 'OrderItem*.java'`. Read the latest migration's header style and the current `OrderItem` entity.

- [ ] **Step 2:** Write the migration:

```sql
-- V<NEXT>__order_item_snapshot_fields.sql
ALTER TABLE order_item
  ADD COLUMN product_name VARCHAR(255) NULL,
  ADD COLUMN image_url VARCHAR(512) NULL;
```

- [ ] **Step 3:** Add fields to `OrderItem` entity. Two new `@Column` fields:

```java
@Column(name = "product_name", length = 255)
private String productName;

@Column(name = "image_url", length = 512)
private String imageUrl;
```

Add Lombok getters/setters per existing entity style (likely `@Getter @Setter @Builder`).

- [ ] **Step 4:** Write a failing repository persistence test asserting that an `OrderItem` saved with `productName="Widget"` and `imageUrl="https://x/y.png"` reads back with the same values. Use whatever test bootstrap order-service uses — check `OrderRepositoryTest` for the pattern (likely `@DataJpaTest` against an in-memory or testcontainer DB). If order-service has no JPA repo tests yet, lean on the create-order service test in Task 3 instead and skip Step 4 here — note in the commit message.

- [ ] **Step 5:** `mvn -pl order-service test -Dtest=OrderItemRepositoryTest`. Expected: PASS.

- [ ] **Step 6:** Commit.

```bash
git add order-service/src/main/resources/db/migration/V<NEXT>__order_item_snapshot_fields.sql \
        order-service/src/main/java/**/entity/OrderItem.java \
        order-service/src/test/java/**/repository/OrderItemRepositoryTest.java
git commit -m "$(cat <<'EOF'
feat(order-service): add product snapshot columns to order_item

Adds nullable product_name + image_url columns. Decouples order history
from product-service availability. Legacy rows remain valid (null).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: order-service create-order snapshot at create time

**Goal:** When the create-order flow looks up each product for stock validation (already happens), capture `name` + `imageUrl` from the response and persist them onto each `OrderItem`.

**Files:**
- Modify: order-service create-order service impl. Find with `rtk grep -rn 'create.*order\|CreateOrder' order-service/src/main/java --include='*Service*.java'`. The impl wires manual through `OrderServiceConfiguration`.
- Modify: any product client / DTO inside order-service that already returns the product data used for stock validation. Likely an inventory or product Feign client / gRPC stub. Add `name` + `imageUrl` fields to its response DTO if missing.
- Test: order-service create-order service unit test. Find existing test class first; extend it.

**Steps:**

- [ ] **Step 1:** Trace the create-order flow. `rtk grep -rn 'public.*OrderResponse.*create\|@PostMapping' order-service/src/main/java/**/controller/OrderController.java` and follow into the service impl. Identify (a) where each line item's product is looked up, (b) the response shape returned by that lookup, (c) where `OrderItem` is built and persisted.

- [ ] **Step 2:** If the product lookup response already exposes `name` and `imageUrl`, skip to Step 3. If not, extend the relevant client DTO + verify the upstream service (likely inventory-service or product-service via Feign) returns those fields in its existing endpoint.

- [ ] **Step 3:** Write a failing service unit test that calls create-order with a fixture cart (1 product), stubs the product client to return `{ name: "Widget", imageUrl: "https://x/y.png", price: 9.99, stock: 10 }`, and asserts the persisted `OrderItem` carries `productName="Widget"` and `imageUrl="https://x/y.png"`.

- [ ] **Step 4:** `mvn -pl order-service test -Dtest=<OrderServiceImplTest>`. Expected: FAIL — fields are null.

- [ ] **Step 5:** Modify create-order to set `productName` + `imageUrl` on the `OrderItem` builder before persisting:

```java
OrderItem item = OrderItem.builder()
    .productId(productId)
    .price(productResponse.getPrice())
    .quantity(quantity)
    .productName(productResponse.getName())
    .imageUrl(productResponse.getImageUrl())
    .build();
```

- [ ] **Step 6:** Run test. Expected: PASS.

- [ ] **Step 7:** Run the full order-service test suite to confirm no regression: `mvn -pl order-service test`.

- [ ] **Step 8:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(order-service): snapshot product name + image_url at order create

Captures product display fields from the existing stock-validation lookup
and persists them on each OrderItem so order history renders without
product-service.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: OrderItemResponse + OrderDetailResponse expose snapshot fields

**Goal:** Surface `productName` + `imageUrl` (snake_case JSON via existing `@JsonNaming`) in the order detail response.

**Files:**
- Modify: `order-service/src/main/java/**/dto/response/OrderItemResponse.java` (find with `find order-service -name OrderItemResponse.java`).
- Modify: the entity→DTO mapper (look for `OrderMapper` or `OrderItemMapper` or hand-rolled toResponse method on the service).
- Test: existing mapper test class (find with `rtk grep -rn 'OrderItemResponse\|OrderMapper' order-service/src/test/java`).

**Steps:**

- [ ] **Step 1:** Read current `OrderItemResponse` shape and the mapper. Confirm snake_case JSON convention (likely `@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)`).

- [ ] **Step 2:** Write a failing mapper test:

```java
@Test
void toResponse_includes_snapshot_fields() {
    OrderItem entity = OrderItem.builder()
        .id("i1").productId("p1").price(BigDecimal.valueOf(9.99)).quantity(2)
        .productName("Widget").imageUrl("https://x/y.png").build();

    OrderItemResponse r = mapper.toResponse(entity);

    assertThat(r.productName()).isEqualTo("Widget");
    assertThat(r.imageUrl()).isEqualTo("https://x/y.png");
}
```

- [ ] **Step 3:** Run test. Expected: FAIL — fields don't exist on response.

- [ ] **Step 4:** Add `String productName` and `String imageUrl` to `OrderItemResponse` record, and propagate from entity in the mapper.

- [ ] **Step 5:** Run test. Expected: PASS.

- [ ] **Step 6:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(order-service): expose productName + imageUrl on OrderItemResponse

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: OrderSummaryResponse adds totalAmount + itemCount + firstItemImageUrl

**Goal:** Make the order list usable on the FE — it currently has no totals.

**Files:**
- Modify: `order-service/src/main/java/**/dto/response/OrderSummaryResponse.java`.
- Modify: the summary mapper.
- Test: summary mapper test.

**Steps:**

- [ ] **Step 1:** Read `OrderSummaryResponse` and its mapper. Decide the totalAmount type — `BigDecimal` matching `OrderItem.price`.

- [ ] **Step 2:** Write a failing mapper test with three fixtures (0 items, 1 item, 3 items):

```java
@Test
void summary_zeroItems_returnsZeroTotal() {
    Order o = orderWithItems(List.of());
    OrderSummaryResponse r = mapper.toSummary(o);
    assertThat(r.totalAmount()).isEqualByComparingTo(BigDecimal.ZERO);
    assertThat(r.itemCount()).isZero();
    assertThat(r.firstItemImageUrl()).isNull();
}

@Test
void summary_oneItem_sumsCorrectly() {
    Order o = orderWithItems(List.of(item("p1", 2, "9.99", "Widget", "https://x/1.png")));
    OrderSummaryResponse r = mapper.toSummary(o);
    assertThat(r.totalAmount()).isEqualByComparingTo("19.98");
    assertThat(r.itemCount()).isEqualTo(1);
    assertThat(r.firstItemImageUrl()).isEqualTo("https://x/1.png");
}

@Test
void summary_threeItems_sumsAndPicksFirstImage() {
    Order o = orderWithItems(List.of(
        item("p1", 1, "10.00", "A", "https://x/1.png"),
        item("p2", 3, "5.50", "B", "https://x/2.png"),
        item("p3", 2, "1.00", "C", null)));
    OrderSummaryResponse r = mapper.toSummary(o);
    assertThat(r.totalAmount()).isEqualByComparingTo("28.50");
    assertThat(r.itemCount()).isEqualTo(3);
    assertThat(r.firstItemImageUrl()).isEqualTo("https://x/1.png");
}
```

(`item(...)` and `orderWithItems(...)` are local test helpers. Inline them in the test class.)

- [ ] **Step 3:** Run test. Expected: FAIL — fields don't exist.

- [ ] **Step 4:** Add `BigDecimal totalAmount`, `int itemCount`, `String firstItemImageUrl` to `OrderSummaryResponse`. Update mapper:

```java
BigDecimal total = order.getItems().stream()
    .map(i -> i.getPrice().multiply(BigDecimal.valueOf(i.getQuantity())))
    .reduce(BigDecimal.ZERO, BigDecimal::add);
int count = order.getItems().size();
String firstImage = order.getItems().isEmpty() ? null : order.getItems().get(0).getImageUrl();
```

- [ ] **Step 5:** Run tests. Expected: PASS.

- [ ] **Step 6:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(order-service): add totalAmount + itemCount + firstItemImageUrl to OrderSummaryResponse

Makes the order list page render real totals + thumbnails without N+1
hydration on the client.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: bff-service typed views + drop product-service call

**Goal:** Tighten `OrderDetailBffResponse` from `{ Object order, Object payment }` to `{ OrderDetailView order, PaymentView payment }`. Aggregator stops calling product-service (snapshot fields from order-service are sufficient).

**Files:**
- Create: `bff-service/src/main/java/**/dto/response/OrderDetailView.java`
- Create: `bff-service/src/main/java/**/dto/response/OrderItemView.java`
- Create: `bff-service/src/main/java/**/dto/response/PaymentView.java`
- Modify: `OrderDetailBffResponse.java`
- Modify: aggregator service (find with `rtk grep -rn 'OrderDetailBff\|aggregat' bff-service/src/main/java`)
- Modify: `BffServiceConfiguration` if removing the product-service client from constructor args
- Test: aggregator unit test

**Steps:**

- [ ] **Step 1:** Read current `OrderDetailBffResponse`, the aggregator impl, and the existing aggregator test. Note which clients are wired.

- [ ] **Step 2:** Define the views. `OrderDetailView` mirrors order-service's `OrderDetailResponse` shape (id, status, address, phone_number, created_at, updated_at, items: List<OrderItemView>). `OrderItemView` carries id, product_id, product_name, image_url, price, quantity. `PaymentView` carries the payment fields the FE uses (status, type, captured_at — adjust to whatever payment-service exposes).

```java
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record OrderItemView(String id, String productId, String productName,
                             String imageUrl, BigDecimal price, int quantity) {}
```

- [ ] **Step 3:** Write a failing aggregator unit test (Mockito-style):

```java
@Test
void aggregate_returnsOrderAndPayment() {
    when(orderClient.get("o1")).thenReturn(orderFixture());
    when(paymentClient.byOrderId("o1")).thenReturn(paymentFixture());

    OrderDetailBffResponse r = service.getOrderDetail("o1", "u1");

    assertThat(r.order().id()).isEqualTo("o1");
    assertThat(r.payment().status()).isEqualTo("PAID");
    verifyNoInteractions(productClient); // no product-service call
}

@Test
void aggregate_paymentMissing_returnsNullPayment() {
    when(orderClient.get("o2")).thenReturn(orderFixture());
    when(paymentClient.byOrderId("o2")).thenReturn(null);

    OrderDetailBffResponse r = service.getOrderDetail("o2", "u1");

    assertThat(r.payment()).isNull();
}
```

If product-service client is currently injected, the second `verifyNoInteractions(productClient)` assertion drives Step 4.

- [ ] **Step 4:** Run test. Expected: FAIL — fields are still `Object`, product-service still called.

- [ ] **Step 5:** Update `OrderDetailBffResponse` to `record OrderDetailBffResponse(OrderDetailView order, PaymentView payment)`. Update aggregator: remove product-service injection + call, map order-service response into `OrderDetailView`, handle null payment defensively.

- [ ] **Step 6:** Update `BffServiceConfiguration` `@Bean` method to drop the product-service client constructor arg.

- [ ] **Step 7:** Run tests. Expected: PASS.

- [ ] **Step 8:** Run `mvn -pl bff-service test` for full bff suite. Confirm no regression.

- [ ] **Step 9:** Commit.

```bash
git commit -m "$(cat <<'EOF'
refactor(bff): type OrderDetailBffResponse and drop product-service call

Order-service now snapshots product name + image_url at create time, so
BFF detail no longer needs to fan out to product-service. Tightens
response to typed OrderDetailView + PaymentView records.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: FE AccountLayout + nested routes + header dropdown link

**Goal:** Stand up the `/account` shell so subsequent FE tasks have a place to land. Sidebar layout, nested children, requiresAuth.

**Files:**
- Create: `frontend/src/layouts/AccountLayout.vue`
- Create stubs (will be filled in later tasks): `frontend/src/pages/account/ProfilePage.vue`, `frontend/src/pages/account/OrdersPage.vue`, `frontend/src/pages/account/OrderDetailPage.vue`
- Modify: `frontend/src/router/index.ts`
- Modify: header/dropdown component — find with `rtk grep -rn 'Logout\|logout' frontend/src/components/layout/`
- Test: `frontend/tests/unit/router/account-routes.spec.ts`

**Steps:**

- [ ] **Step 1:** Identify the header user dropdown file. List `frontend/src/components/layout/` and grep for `Logout`. Note the spot to add an "Account" link.

- [ ] **Step 2:** Write a failing router test:

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { router } from '@/router';
import { useAuthStore } from '@/stores/auth';

describe('account routes', () => {
  beforeEach(() => setActivePinia(createPinia()));

  it('redirects /account to /account/profile when authed', async () => {
    useAuthStore().setTokens('access', 'refresh'); // adapt to actual auth store API
    await router.push('/account');
    await router.isReady();
    expect(router.currentRoute.value.path).toBe('/account/profile');
  });

  it('redirects unauthed user to /login with next', async () => {
    await router.push('/account/profile');
    await router.isReady();
    expect(router.currentRoute.value.path).toBe('/login');
    expect(router.currentRoute.value.query.next).toBe('/account/profile');
  });
});
```

(Read `frontend/src/stores/auth.ts` for the real method to seed a logged-in state — match Phase 5's `useAuthStore` API.)

- [ ] **Step 3:** Run test. Expected: FAIL — `/account` route doesn't exist.

- [ ] **Step 4:** Create `AccountLayout.vue` as a **horizontal masthead tab strip** (NOT a sidebar — see Visual Direction). Mirror the masthead/numeral treatment from `HomePage.vue` lines 113-218.

```vue
<script setup lang="ts">
import { RouterLink, RouterView } from 'vue-router';
</script>

<template>
  <main class="account">
    <header class="account__masthead">
      <span class="account__numeral" aria-hidden="true">02</span>
      <p class="account__kicker">Issue Nº02 — The Account</p>
    </header>
    <nav class="account__strip" aria-label="Account sections">
      <RouterLink to="/account/profile" class="account__link" active-class="account__link--active">MASTHEAD</RouterLink>
      <RouterLink to="/account/orders" class="account__link" active-class="account__link--active">LEDGER</RouterLink>
    </nav>
    <section class="account__main">
      <RouterView />
    </section>
  </main>
</template>

<style scoped>
.account {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  display: grid;
  gap: var(--space-6);
}
.account__masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
}
.account__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}
.account__kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}
.account__strip {
  display: flex;
  gap: var(--space-6);
  border-bottom: var(--border-thin);
  padding-bottom: var(--space-3);
}
.account__link {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--muted-ink);
  text-decoration: none;
  padding-bottom: var(--space-2);
  border-bottom: 4px solid transparent;
}
.account__link:hover { border-bottom-color: var(--spot); color: var(--ink); }
.account__link--active { color: var(--ink); border-bottom-color: var(--spot); }
</style>
```

The detail page (`/account/orders/:id`) uses the same `LEDGER` tab as active — no third tab. Order-detail's own header (`RECEIPT Nº…`) carries the page identity.

- [ ] **Step 5:** Create stub pages (1-line `<template><h1>...</h1></template>` each) so the router resolves. Tasks 9, 11, 12 replace them.

- [ ] **Step 6:** Add nested route to `frontend/src/router/index.ts`:

```ts
{
  path: '/account',
  component: AccountLayout,
  meta: { requiresAuth: true },
  children: [
    { path: '', redirect: '/account/profile' },
    { path: 'profile', component: ProfilePage },
    { path: 'orders', component: OrdersPage },
    { path: 'orders/:id', component: OrderDetailPage },
  ],
},
```

- [ ] **Step 7:** Add "Account" link to the header dropdown above "Logout":

```vue
<RouterLink to="/account" class="dropdown__item">ACCOUNT</RouterLink>
```

(Match the existing dropdown item class.)

- [ ] **Step 8:** Run tests. Expected: router tests PASS.

- [ ] **Step 9:** `pnpm typecheck` clean.

- [ ] **Step 10:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): add account shell with nested routes and header link

Stand up /account/{profile,orders,orders/:id} behind requiresAuth.
Pages are stubs to be filled in by subsequent tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: FE profile queries + zod schemas

**Goal:** Wire the data layer for the profile page. Five hooks + two schemas.

**Files:**
- Create: `frontend/src/api/queries/profile.ts`
- Modify: `frontend/src/lib/zod-schemas.ts`
- Test: `frontend/tests/unit/lib/zod-schemas.spec.ts` (extend; create if absent)
- Test: `frontend/tests/unit/api/queries/profile.spec.ts` (smoke test that hooks export)

**Steps:**

- [ ] **Step 1:** Read existing `frontend/src/lib/zod-schemas.ts` (`addressSchema` is the style ref) and `frontend/src/api/queries/cart.ts` (query/mutation pattern with `useQuery` + `useMutation` + `queryClient.invalidateQueries`).

- [ ] **Step 2:** Add schemas to `frontend/src/lib/zod-schemas.ts`:

```ts
import { z } from 'zod';

export const profileSchema = z.object({
  name: z.string().min(1, 'Name is required').max(100, 'Max 100 chars'),
  gender: z.enum(['MALE', 'FEMALE', 'OTHER']).nullable(),
  address: z.string().max(500, 'Max 500 chars').optional().or(z.literal('')),
});
export type ProfileInput = z.infer<typeof profileSchema>;

export const passwordSchema = z.object({
  oldPassword: z.string().min(1, 'Required'),
  newPassword: z.string().min(8, 'At least 8 chars'),
  confirmNewPassword: z.string(),
}).refine((d) => d.newPassword === d.confirmNewPassword, {
  message: 'Passwords do not match',
  path: ['confirmNewPassword'],
});
export type PasswordInput = z.infer<typeof passwordSchema>;
```

- [ ] **Step 3:** Write failing schema tests:

```ts
import { describe, it, expect } from 'vitest';
import { profileSchema, passwordSchema } from '@/lib/zod-schemas';

describe('profileSchema', () => {
  it('accepts valid input', () => {
    expect(profileSchema.safeParse({ name: 'Ada', gender: 'FEMALE', address: '12 Lane' }).success).toBe(true);
  });
  it('rejects empty name', () => {
    expect(profileSchema.safeParse({ name: '', gender: null, address: '' }).success).toBe(false);
  });
  it('rejects address > 500 chars', () => {
    expect(profileSchema.safeParse({ name: 'A', gender: null, address: 'x'.repeat(501) }).success).toBe(false);
  });
});

describe('passwordSchema', () => {
  it('accepts matching passwords', () => {
    expect(passwordSchema.safeParse({ oldPassword: 'old', newPassword: 'newpass1', confirmNewPassword: 'newpass1' }).success).toBe(true);
  });
  it('rejects mismatched confirm', () => {
    expect(passwordSchema.safeParse({ oldPassword: 'old', newPassword: 'newpass1', confirmNewPassword: 'newpass2' }).success).toBe(false);
  });
  it('rejects new < 8 chars', () => {
    expect(passwordSchema.safeParse({ oldPassword: 'old', newPassword: 'short', confirmNewPassword: 'short' }).success).toBe(false);
  });
});
```

- [ ] **Step 4:** `pnpm test tests/unit/lib/zod-schemas.spec.ts`. Expected: PASS (schemas already added in Step 2).

- [ ] **Step 5:** Create `frontend/src/api/queries/profile.ts`:

```ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';

export interface ProfileData {
  id: string;
  name: string;
  email: string;
  gender: 'MALE' | 'FEMALE' | 'OTHER' | null;
  address: string | null;
  avatar_url?: string | null;
}

const PROFILE_KEY = ['profile'] as const;

export function useProfileQuery() {
  return useQuery({
    queryKey: PROFILE_KEY,
    queryFn: () => apiFetch<ProfileData>('/authorization-server/v1/users/self', { method: 'GET' }),
  });
}

export function useUpdateProfileMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { name?: string; gender?: string | null; address?: string | null }) =>
      apiFetch<ProfileData>('/authorization-server/v1/users/self', {
        method: 'PUT', body: JSON.stringify(body),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROFILE_KEY }),
  });
}

export function useChangePasswordMutation() {
  return useMutation({
    mutationFn: (body: { old_password: string; new_password: string; confirm_new_password: string }) =>
      apiFetch<void>('/authorization-server/v1/users/self:update-password', {
        method: 'PATCH', body: JSON.stringify(body),
      }),
  });
}

export interface PresignResponse { upload_url: string; object_key: string; expires_at: string; }

export function useAvatarPresignMutation() {
  return useMutation({
    mutationFn: (body: { content_type: string; size_bytes: number }) =>
      apiFetch<PresignResponse>('/authorization-server/v1/users/self/avatar/presign', {
        method: 'POST', body: JSON.stringify(body),
      }),
  });
}

export function useAttachAvatarMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { object_key: string }) =>
      apiFetch<{ avatar_url: string }>('/authorization-server/v1/users/self/avatar', {
        method: 'PUT', body: JSON.stringify(body),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROFILE_KEY }),
  });
}
```

- [ ] **Step 6:** `pnpm typecheck` clean.

- [ ] **Step 7:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): add profile queries and zod schemas

Five hooks (profile, update, change password, avatar presign, attach)
plus profileSchema + passwordSchema for the upcoming ProfilePage.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: FE ProfilePage

**Goal:** Build the profile page — three stacked cards: avatar, profile form, change-password form.

**Files:**
- Replace stub: `frontend/src/pages/account/ProfilePage.vue`
- Optionally extract: `frontend/src/components/domain/ProfileAvatarCard.vue`, `ProfileForm.vue`, `PasswordChangeForm.vue` (only if ProfilePage exceeds ~200 lines).
- Test: `frontend/tests/unit/pages/ProfilePage.spec.ts`

**Steps:**

- [ ] **Step 1:** Read `frontend/src/pages/CheckoutPage.vue` and `frontend/tests/unit/pages/CheckoutPage.spec.ts` for the VeeValidate + Zod page pattern and the `vi.mock` test setup. Read `frontend/src/components/domain/AddressForm.vue` for the form-component pattern.

- [ ] **Step 2:** Write failing page tests with three behaviors:

```ts
// 1. Profile form Zod errors render: clear name field, blur, expect "Name is required" inline.
// 2. Avatar upload happy path: click CHANGE PHOTO, simulate file, expect presign → fetch PUT → attach calls.
// 3. Password mismatch blocks submit: type new=abc12345, confirm=different, click CHANGE PASSWORD, expect "Passwords do not match" + no mutation call.
```

Use `vi.mock('@/api/queries/profile', () => ({ ... }))` with stub `mutateAsync` per Phase 5 pattern. Mock `global.fetch` for the S3 PUT in test 2 (pattern: `vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 200 }))`).

- [ ] **Step 3:** Run tests. Expected: FAIL.

- [ ] **Step 4:** Implement `ProfilePage.vue`:

```vue
<script setup lang="ts">
import { ref, watch } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useProfileQuery, useUpdateProfileMutation, useChangePasswordMutation,
         useAvatarPresignMutation, useAttachAvatarMutation } from '@/api/queries/profile';
import { profileSchema, passwordSchema } from '@/lib/zod-schemas';
import { BButton, BCard, BInput, BSelect } from '@/components/primitives';
import BImageFallback from '@/components/BImageFallback.vue';
import { useToast } from '@/composables/useToast';

const profileQ = useProfileQuery();
const updateM = useUpdateProfileMutation();
const passwordM = useChangePasswordMutation();
const presignM = useAvatarPresignMutation();
const attachM = useAttachAvatarMutation();
const toast = useToast();

// Profile form
const profileForm = useForm({ validationSchema: toTypedSchema(profileSchema), initialValues: { name: '', gender: null, address: '' } });
const [name, nameAttrs] = profileForm.defineField('name');
const [gender, genderAttrs] = profileForm.defineField('gender');
const [address, addressAttrs] = profileForm.defineField('address');

watch(() => profileQ.data.value, (p) => {
  if (p) profileForm.resetForm({ values: { name: p.name, gender: p.gender, address: p.address ?? '' } });
});

const onProfileSubmit = profileForm.handleSubmit(async (values) => {
  try {
    await updateM.mutateAsync({ name: values.name, gender: values.gender, address: values.address || null });
    toast.success('Profile updated');
  } catch { toast.error('Update failed', 'Please try again.'); }
});

// Password form
const pwForm = useForm({ validationSchema: toTypedSchema(passwordSchema),
  initialValues: { oldPassword: '', newPassword: '', confirmNewPassword: '' } });
const [oldPw, oldPwAttrs] = pwForm.defineField('oldPassword');
const [newPw, newPwAttrs] = pwForm.defineField('newPassword');
const [confirmPw, confirmPwAttrs] = pwForm.defineField('confirmNewPassword');

const onPasswordSubmit = pwForm.handleSubmit(async (values) => {
  try {
    await passwordM.mutateAsync({
      old_password: values.oldPassword,
      new_password: values.newPassword,
      confirm_new_password: values.confirmNewPassword,
    });
    toast.success('Password changed');
    pwForm.resetForm();
  } catch { toast.error('Change failed', 'Check your current password.'); }
});

// Avatar
const fileInput = ref<HTMLInputElement | null>(null);
const uploading = ref(false);
const uploadError = ref<string | null>(null);

async function onAvatarSelected(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (!file) return;
  if (file.size > 5 * 1024 * 1024) { uploadError.value = 'Max 5MB'; return; }
  uploading.value = true; uploadError.value = null;
  try {
    const presign = await presignM.mutateAsync({ content_type: file.type, size_bytes: file.size });
    const r = await fetch(presign.upload_url, { method: 'PUT', headers: { 'Content-Type': file.type }, body: file });
    if (!r.ok) throw new Error('S3 PUT failed');
    await attachM.mutateAsync({ object_key: presign.object_key });
    toast.success('Avatar updated');
  } catch (err) {
    uploadError.value = (err as Error).message ?? 'Upload failed';
  } finally {
    uploading.value = false;
    if (fileInput.value) fileInput.value.value = '';
  }
}
</script>

<template>
  <div class="profile-page">
    <h1 class="profile-page__title">PROFILE</h1>

    <!-- Avatar card -->
    <BCard class="profile-page__card">
      <div class="profile-page__avatar-row">
        <div class="profile-page__avatar">
          <img v-if="profileQ.data.value?.avatar_url" :src="profileQ.data.value.avatar_url" alt="Avatar" />
          <BImageFallback v-else :name="profileQ.data.value?.name ?? '?'" />
        </div>
        <div>
          <BButton :disabled="uploading" @click="fileInput?.click()">
            {{ uploading ? 'UPLOADING…' : 'CHANGE PHOTO' }}
          </BButton>
          <p v-if="uploadError" class="profile-page__error" role="alert">{{ uploadError }}</p>
          <input ref="fileInput" type="file" accept="image/*" hidden @change="onAvatarSelected" />
        </div>
      </div>
    </BCard>

    <!-- Profile form -->
    <BCard class="profile-page__card">
      <form @submit.prevent="onProfileSubmit">
        <BInput v-model="name" v-bind="nameAttrs" label="Name" :error="profileForm.errors.value.name" />
        <BSelect v-model="gender" v-bind="genderAttrs" label="Gender"
                 :options="[{ value: null, label: '—' }, { value: 'MALE', label: 'Male' }, { value: 'FEMALE', label: 'Female' }, { value: 'OTHER', label: 'Other' }]" />
        <BInput v-model="address" v-bind="addressAttrs" label="Address" multiline
                :error="profileForm.errors.value.address" />
        <p class="profile-page__readonly">Email: {{ profileQ.data.value?.email ?? '' }}</p>
        <BButton type="submit" :disabled="!profileForm.meta.value.dirty || !profileForm.meta.value.valid"
                 :loading="updateM.isPending.value">SAVE</BButton>
      </form>
    </BCard>

    <!-- Password form -->
    <BCard class="profile-page__card">
      <form @submit.prevent="onPasswordSubmit">
        <BInput v-model="oldPw" v-bind="oldPwAttrs" type="password" label="Current password"
                :error="pwForm.errors.value.oldPassword" />
        <BInput v-model="newPw" v-bind="newPwAttrs" type="password" label="New password"
                :error="pwForm.errors.value.newPassword" />
        <BInput v-model="confirmPw" v-bind="confirmPwAttrs" type="password" label="Confirm new password"
                :error="pwForm.errors.value.confirmNewPassword" />
        <BButton type="submit" :loading="passwordM.isPending.value">CHANGE PASSWORD</BButton>
      </form>
    </BCard>
  </div>
</template>

<style scoped>
.profile-page { padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-6); }
.profile-page__title { font-family: var(--font-display); font-weight: 900; font-size: var(--type-h1); text-transform: uppercase; margin: 0; }
.profile-page__card { padding: var(--space-5); }
.profile-page__avatar-row { display: flex; align-items: center; gap: var(--space-4); }
.profile-page__avatar { width: 96px; height: 96px; overflow: hidden; border: var(--border-thin); }
.profile-page__avatar img { width: 100%; height: 100%; object-fit: cover; }
.profile-page__error { color: var(--danger); font-family: var(--font-mono); margin-top: var(--space-2); }
.profile-page__readonly { font-family: var(--font-mono); color: var(--muted-ink); margin: var(--space-2) 0; }
</style>
```

(Adapt `BInput`/`BSelect` props to actual primitives — read them first. The `multiline` prop on `BInput` may not exist; if not, swap for a plain `<textarea>` with the same Tailwind classes.)

- [ ] **Step 5:** Run tests. Expected: PASS. Iterate on test/page until green.

- [ ] **Step 6:** `pnpm typecheck` clean. `pnpm lint` clean.

- [ ] **Step 7:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): implement ProfilePage with avatar, profile form, and password change

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: FE useOrdersListQuery + OrderStatusStamp + OrderReceiptRow

**Goal:** Data layer + atomic components for the orders list.

**Files:**
- Modify: `frontend/src/api/queries/orders.ts` (add `useOrdersListQuery`)
- Create: `frontend/src/components/domain/OrderStatusStamp.vue`
- Create: `frontend/src/components/domain/OrderReceiptRow.vue`
- Test: `frontend/tests/unit/components/domain/OrderStatusStamp.spec.ts`
- Test: `frontend/tests/unit/components/domain/OrderReceiptRow.spec.ts`

**Steps:**

- [ ] **Step 1:** Read `frontend/src/api/queries/orders.ts` (Phase 5) for the existing query pattern and the order detail/cancel hooks already there.

- [ ] **Step 2:** Add to `orders.ts`:

```ts
export interface OrderSummary {
  id: string;
  status: 'PENDING' | 'PROCESSING' | 'PAID' | 'CANCELED' | 'FAILED' | string;
  address: string;
  phone_number: string;
  created_at: string;
  updated_at: string;
  total_amount: number;
  item_count: number;
  first_item_image_url: string | null;
}

export interface OrdersListPage {
  content: OrderSummary[];
  page: number;
  size: number;
  total_elements: number;
}

export function useOrdersListQuery(params: { page: Ref<number>; size: number }) {
  return useQuery({
    queryKey: computed(() => ['orders', 'list', params.page.value, params.size] as const),
    queryFn: () => apiFetch<OrdersListPage>(
      `/order-service/v1/orders?page=${params.page.value}&size=${params.size}`,
      { method: 'GET' },
    ),
    keepPreviousData: true,
  });
}
```

- [ ] **Step 3:** Write failing OrderStatusStamp test:

```ts
import { render } from '@testing-library/vue';
import OrderStatusStamp from '@/components/domain/OrderStatusStamp.vue';

describe('OrderStatusStamp', () => {
  it.each([
    ['PENDING', 'pill--pending'],
    ['PROCESSING', 'pill--processing'],
    ['PAID', 'pill--paid'],
    ['CANCELED', 'pill--canceled'],
    ['FAILED', 'pill--failed'],
  ])('renders %s with class %s', (status, cls) => {
    const { container } = render(OrderStatusStamp, { props: { status } });
    expect(container.querySelector(`.${cls}`)).not.toBeNull();
  });
});
```

- [ ] **Step 4:** Implement OrderStatusStamp:

```vue
<script setup lang="ts">
import { computed } from 'vue';
const props = defineProps<{ status: string }>();
const cls = computed(() => `pill pill--${props.status.toLowerCase()}`);
</script>

<template>
  <span :class="cls">{{ status }}</span>
</template>

<style scoped>
.pill { display: inline-block; padding: 2px 8px; font-family: var(--font-mono); font-size: 0.75rem; text-transform: uppercase; border: 1px solid currentColor; }
.pill--pending { color: var(--muted-ink); }
.pill--processing { color: #2563eb; }
.pill--paid { color: #16a34a; }
.pill--canceled, .pill--failed { color: #dc2626; }
</style>
```

- [ ] **Step 5:** Write failing OrderReceiptRow test:

```ts
it('renders status, total, item count, and links to detail', () => {
  const summary = {
    id: 'abc12345-0000-0000-0000-000000000000',
    status: 'PAID', address: 'X', phone_number: '+1', created_at: '2026-05-01T00:00:00Z',
    updated_at: '2026-05-01T00:00:00Z', total_amount: 19.98, item_count: 2, first_item_image_url: null,
  };
  const { getByText, getByRole } = render(OrderReceiptRow, { props: { summary }, global: { plugins: [router] } });
  expect(getByText(/PAID/)).toBeInTheDocument();
  expect(getByText(/\$19\.98/)).toBeInTheDocument();
  expect(getByText(/2 item/)).toBeInTheDocument();
  expect(getByRole('link')).toHaveAttribute('href', '/account/orders/abc12345-0000-0000-0000-000000000000');
});
```

- [ ] **Step 6:** Implement OrderReceiptRow:

```vue
<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink } from 'vue-router';
import OrderStatusStamp from './OrderStatusStamp.vue';
import BImageFallback from '@/components/BImageFallback.vue';
import type { OrderSummary } from '@/api/queries/orders';

const props = defineProps<{ summary: OrderSummary }>();
const shortId = computed(() => props.summary.id.slice(0, 8));
const total = computed(() => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(props.summary.total_amount));
const dateStr = computed(() => new Date(props.summary.created_at).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' }));
</script>

<template>
  <RouterLink :to="`/account/orders/${summary.id}`" class="order-card">
    <div class="order-card__thumb">
      <img v-if="summary.first_item_image_url" :src="summary.first_item_image_url" alt="" />
      <BImageFallback v-else :name="summary.id" />
    </div>
    <div class="order-card__body">
      <p class="order-card__id">Order #{{ shortId }}</p>
      <p class="order-card__meta">{{ dateStr }} · {{ summary.item_count }} item{{ summary.item_count === 1 ? '' : 's' }}</p>
    </div>
    <div class="order-card__right">
      <OrderStatusStamp :status="summary.status" />
      <p class="order-card__total">{{ total }}</p>
    </div>
  </RouterLink>
</template>

<style scoped>
.order-card { display: grid; grid-template-columns: 64px 1fr auto; gap: var(--space-4); padding: var(--space-4); border: var(--border-thin); text-decoration: none; color: var(--ink); }
.order-card__thumb { width: 64px; height: 64px; overflow: hidden; }
.order-card__thumb img { width: 100%; height: 100%; object-fit: cover; }
.order-card__id { font-family: var(--font-display); font-weight: 700; text-transform: uppercase; margin: 0; }
.order-card__meta { font-family: var(--font-mono); color: var(--muted-ink); margin: var(--space-1) 0 0; font-size: 0.85rem; }
.order-card__right { text-align: right; display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-2); }
.order-card__total { font-family: var(--font-mono); font-weight: 700; margin: 0; }
</style>
```

- [ ] **Step 7:** `pnpm test`. Expected: PASS for both tests.

- [ ] **Step 8:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): add useOrdersListQuery, OrderStatusStamp, OrderReceiptRow

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: FE OrdersPage with pagination + empty state

**Goal:** Compose Task 10's pieces into the orders list page.

**Files:**
- Replace stub: `frontend/src/pages/account/OrdersPage.vue`
- Test: `frontend/tests/unit/pages/OrdersPage.spec.ts`

**Steps:**

- [ ] **Step 1:** Write failing tests for three behaviors:
  - Renders cards from mocked query (3 fixtures).
  - Empty state when list empty: "No orders yet" + BROWSE PRODUCTS link to `/`.
  - Pagination: PREV disabled on page 1; NEXT disabled when `content.length < size`; clicking NEXT increments the page param passed to the query mock.

Mock pattern:

```ts
const useOrdersListQuery = vi.fn();
vi.mock('@/api/queries/orders', () => ({ useOrdersListQuery: (...a: unknown[]) => useOrdersListQuery(...a) }));
```

- [ ] **Step 2:** Run tests. Expected: FAIL.

- [ ] **Step 3:** Implement `OrdersPage.vue`:

```vue
<script setup lang="ts">
import { ref, computed } from 'vue';
import { useOrdersListQuery } from '@/api/queries/orders';
import OrderReceiptRow from '@/components/domain/OrderReceiptRow.vue';
import { BButton } from '@/components/primitives';

const PAGE_SIZE = 20;
const page = ref(1);
const query = useOrdersListQuery({ page, size: PAGE_SIZE });

const items = computed(() => query.data.value?.content ?? []);
const isEmpty = computed(() => !query.isLoading.value && items.value.length === 0 && page.value === 1);
const canPrev = computed(() => page.value > 1);
const canNext = computed(() => items.value.length === PAGE_SIZE);
</script>

<template>
  <div class="orders-page">
    <h1 class="orders-page__title">THE LEDGER</h1>

    <div v-if="query.isLoading.value" class="orders-page__skeletons">
      <div v-for="n in 3" :key="n" class="orders-page__skeleton" />
    </div>

    <div v-else-if="query.isError.value" class="orders-page__error" role="alert">
      <p>Failed to load orders.</p>
      <BButton variant="ghost" @click="query.refetch()">RETRY</BButton>
    </div>

    <div v-else-if="isEmpty" class="orders-page__empty">
      <p>No orders yet.</p>
      <RouterLink to="/" class="orders-page__cta">BROWSE PRODUCTS</RouterLink>
    </div>

    <div v-else class="orders-page__list">
      <OrderReceiptRow v-for="o in items" :key="o.id" :summary="o" />
    </div>

    <div v-if="!isEmpty && !query.isLoading.value" class="orders-page__pagination">
      <BButton :disabled="!canPrev" @click="page--">PREV</BButton>
      <span class="orders-page__page-num">PAGE {{ page }}</span>
      <BButton :disabled="!canNext" @click="page++">NEXT</BButton>
    </div>
  </div>
</template>

<style scoped>
.orders-page { padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-6); }
.orders-page__title { font-family: var(--font-display); font-weight: 900; font-size: var(--type-h1); text-transform: uppercase; margin: 0; }
.orders-page__list, .orders-page__skeletons { display: flex; flex-direction: column; gap: var(--space-3); }
.orders-page__skeleton { height: 96px; background: var(--muted-ink); opacity: 0.1; }
.orders-page__empty, .orders-page__error { padding: var(--space-8); text-align: center; font-family: var(--font-mono); }
.orders-page__cta { display: inline-block; margin-top: var(--space-4); font-family: var(--font-display); font-weight: 700; text-transform: uppercase; color: var(--ink); border-bottom: 2px solid var(--ink); padding-bottom: 2px; }
.orders-page__pagination { display: flex; justify-content: center; align-items: center; gap: var(--space-4); padding-top: var(--space-4); }
.orders-page__page-num { font-family: var(--font-mono); }
</style>
```

- [ ] **Step 4:** Run tests. Expected: PASS.

- [ ] **Step 5:** `pnpm typecheck` and `pnpm lint` clean.

- [ ] **Step 6:** Commit.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): implement OrdersPage with pagination and empty state

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: FE order detail + REORDER + CANCEL ORDER + DoD/PR

**Goal:** Final FE task. Order detail page with all interactions, plus full DoD checks and PR open.

**Files:**
- Modify: `frontend/src/api/queries/orders.ts` (add `useOrderDetailBffQuery`)
- Create: `frontend/src/components/domain/OrderItemRow.vue`
- Replace stub: `frontend/src/pages/account/OrderDetailPage.vue`
- Test: `frontend/tests/unit/pages/OrderDetailPage.spec.ts`

**Steps:**

- [ ] **Step 1:** Add to `orders.ts`:

```ts
export interface OrderDetailItem {
  id: string;
  product_id: string;
  product_name: string | null;
  image_url: string | null;
  price: number;
  quantity: number;
}

export interface OrderDetailView {
  id: string;
  status: string;
  address: string;
  phone_number: string;
  created_at: string;
  updated_at: string;
  items: OrderDetailItem[];
}

export interface PaymentView {
  status: string | null;
  type: string | null;
  captured_at?: string | null;
}

export interface OrderDetailBffData {
  order: OrderDetailView;
  payment: PaymentView | null;
}

export function useOrderDetailBffQuery(orderId: Ref<string>) {
  return useQuery({
    queryKey: computed(() => ['orders', 'detail', orderId.value] as const),
    queryFn: () => apiFetch<OrderDetailBffData>(
      `/bff-service/v1/orders/${orderId.value}`,
      { method: 'GET' },
    ),
    enabled: computed(() => !!orderId.value),
    retry: (failureCount, err) => {
      const status = (err as { status?: number })?.status;
      if (status === 404) return false;
      return failureCount < 2;
    },
  });
}
```

- [ ] **Step 2:** Write failing OrderDetailPage tests covering:
  1. Renders hydrated items (`product_name` shown, line subtotal `$qty × price`).
  2. Legacy item with `product_name: null` shows "Product unavailable" non-link text.
  3. CANCEL ORDER button hidden when status is PAID.
  4. CANCEL ORDER visible when status is PENDING; clicking opens BDialog; mutation NOT called until confirm.
  5. CANCEL ORDER on confirm calls `useCancelOrderMutation().mutateAsync` with the order id.
  6. REORDER loops `useAddToCartMutation` over items, awaits all, navigates to `/cart`. With one 409 from the cart mutation, partial-success toast surfaces with the skipped name.
  7. 404 error surfaces "Order not found" panel with "Back to orders" link to `/account/orders`.

Mock module pattern (mirror Phase 5 CheckoutPage.spec.ts):

```ts
const useOrderDetailBffQuery = vi.fn();
const cancelMutate = vi.fn();
const addToCartMutate = vi.fn();
vi.mock('@/api/queries/orders', () => ({
  useOrderDetailBffQuery: (...a: unknown[]) => useOrderDetailBffQuery(...a),
  useCancelOrderMutation: () => ({ mutateAsync: cancelMutate, isPending: { value: false } }),
}));
vi.mock('@/api/queries/cart', () => ({
  useAddToCartMutation: () => ({ mutateAsync: addToCartMutate, isPending: { value: false } }),
}));
```

- [ ] **Step 3:** Run tests. Expected: FAIL.

- [ ] **Step 4:** Implement `OrderItemRow.vue`:

```vue
<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink } from 'vue-router';
import BImageFallback from '@/components/BImageFallback.vue';
import type { OrderDetailItem } from '@/api/queries/orders';

const props = defineProps<{ item: OrderDetailItem }>();
const fmt = (n: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);
const subtotal = computed(() => fmt(props.item.price * props.item.quantity));
const unit = computed(() => fmt(props.item.price));
</script>

<template>
  <div class="row">
    <div class="row__thumb">
      <img v-if="item.image_url" :src="item.image_url" :alt="item.product_name ?? 'Product'" />
      <BImageFallback v-else :name="item.product_name ?? 'Product'" />
    </div>
    <div class="row__info">
      <RouterLink v-if="item.product_name" :to="`/products/${item.product_id}`" class="row__name">
        {{ item.product_name }}
      </RouterLink>
      <span v-else class="row__name row__name--missing">Product unavailable</span>
      <p class="row__qty">{{ item.quantity }} × {{ unit }}</p>
    </div>
    <div class="row__sub">{{ subtotal }}</div>
  </div>
</template>

<style scoped>
.row { display: flex; align-items: center; gap: var(--space-3); padding: var(--space-3) 0; border-bottom: var(--border-thin); }
.row__thumb { width: 56px; height: 56px; overflow: hidden; flex-shrink: 0; }
.row__thumb img { width: 100%; height: 100%; object-fit: cover; }
.row__info { flex: 1; min-width: 0; }
.row__name { display: block; font-family: var(--font-display); font-weight: 700; text-transform: uppercase; text-decoration: none; color: var(--ink); }
.row__name--missing { color: var(--muted-ink); }
.row__qty { font-family: var(--font-mono); color: var(--muted-ink); margin: var(--space-1) 0 0; }
.row__sub { font-family: var(--font-mono); flex-shrink: 0; }
</style>
```

- [ ] **Step 5:** Implement `OrderDetailPage.vue`:

```vue
<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute, useRouter, RouterLink } from 'vue-router';
import { useOrderDetailBffQuery, useCancelOrderMutation } from '@/api/queries/orders';
import { useAddToCartMutation } from '@/api/queries/cart';
import OrderItemRow from '@/components/domain/OrderItemRow.vue';
import OrderStatusStamp from '@/components/domain/OrderStatusStamp.vue';
import { BButton, BDialog } from '@/components/primitives';
import { useToast } from '@/composables/useToast';

const route = useRoute();
const router = useRouter();
const toast = useToast();

const orderId = computed(() => String(route.params.id));
const query = useOrderDetailBffQuery(orderId);
const cancelM = useCancelOrderMutation();
const addToCartM = useAddToCartMutation();

const order = computed(() => query.data.value?.order ?? null);
const payment = computed(() => query.data.value?.payment ?? null);

const is404 = computed(() => {
  const e = query.error.value as { status?: number } | null;
  return query.isError.value && e?.status === 404;
});

const shortId = computed(() => orderId.value.slice(0, 8));
const canCancel = computed(() => order.value?.status === 'PENDING' || order.value?.status === 'PROCESSING');

const fmt = (n: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);
const total = computed(() => {
  const items = order.value?.items ?? [];
  return fmt(items.reduce((s, i) => s + i.price * i.quantity, 0));
});

const showCancelModal = ref(false);
async function confirmCancel() {
  showCancelModal.value = false;
  try {
    await cancelM.mutateAsync(orderId.value);
    toast.success('Order canceled');
    query.refetch();
  } catch { toast.error('Cancel failed', 'Please try again.'); }
}

const reordering = ref(false);
async function handleReorder() {
  if (!order.value?.items.length) return;
  reordering.value = true;
  const skipped: string[] = [];
  for (const item of order.value.items) {
    try {
      await addToCartM.mutateAsync({ product_id: item.product_id, quantity: item.quantity });
    } catch (err: unknown) {
      const status = (err as { status?: number })?.status;
      if (status === 409 || status === 400) skipped.push(item.product_name ?? item.product_id);
    }
  }
  reordering.value = false;
  const added = order.value.items.length - skipped.length;
  if (skipped.length === 0) toast.success(`${added} item(s) added to cart`);
  else if (added === 0) toast.error('All items unavailable', skipped.join(', '));
  else toast.info(`${added} added, ${skipped.length} unavailable`, skipped.join(', '));
  router.push('/cart');
}
</script>

<template>
  <div v-if="is404" class="not-found">
    <p>Order not found.</p>
    <RouterLink to="/account/orders">Back to orders</RouterLink>
  </div>

  <div v-else-if="query.isLoading.value" class="loading">
    <div class="skeleton" /><div class="skeleton" />
  </div>

  <div v-else-if="query.isError.value" class="error" role="alert">
    <p>Failed to load order.</p>
    <BButton variant="ghost" @click="query.refetch()">RETRY</BButton>
    <RouterLink to="/account/orders">Back to orders</RouterLink>
  </div>

  <div v-else-if="order" class="detail">
    <div class="detail__header">
      <span class="detail__numeral" aria-hidden="true">Nº{{ shortId }}</span>
      <h1 class="detail__title">RECEIPT</h1>
      <p class="detail__uuid">{{ orderId }}</p>
      <p class="detail__stamped">STAMPED {{ formatStamped(order.created_at) }}</p>
      <OrderStatusStamp :status="order.status" class="detail__stamp" />
    </div>

    <div class="detail__body">
      <section class="detail__items">
        <BCropmarks inset="0.5rem" />
        <OrderItemRow v-for="(i, idx) in order.items" :key="i.id" :item="i" :index="idx + 1" />
        <BCropmarks inset="0.5rem" />
      </section>

      <aside class="detail__meta">
        <div><p class="detail__label">SHIP TO</p><p>{{ order.address }}</p><p>{{ order.phone_number }}</p></div>
        <div v-if="payment">
          <p class="detail__label">TENDERED</p>
          <OrderStatusStamp :status="payment.status ?? '—'" />
          <p v-if="payment.type" class="detail__pay-type">{{ payment.type }}</p>
        </div>
        <div class="detail__total-block">
          <p class="detail__label">TOTAL DUE</p>
          <p class="detail__total-amount">{{ total }}</p>
        </div>
        <div class="detail__actions">
          <BButton variant="ghost" :loading="reordering" @click="handleReorder">STAMP AGAIN</BButton>
          <BButton v-if="canCancel" variant="ghost" :loading="cancelM.isPending.value" @click="showCancelModal = true">
            VOID THIS RECEIPT
          </BButton>
        </div>
      </aside>
    </div>

    <BDialog :open="showCancelModal" @update:open="showCancelModal = $event"
             title="Void this order?" :description="`Void order Nº${shortId}? Stamp is permanent.`">
      <template #footer>
        <BButton variant="ghost" @click="showCancelModal = false">KEEP ORDER</BButton>
        <BButton variant="danger" :loading="cancelM.isPending.value" @click="confirmCancel">CONFIRM CANCEL</BButton>
      </template>
    </BDialog>
  </div>
</template>

<style scoped>
.not-found, .error, .loading { padding: var(--space-8); font-family: var(--font-mono); text-align: center; }
.skeleton { height: 80px; background: var(--muted-ink); opacity: 0.1; margin-bottom: var(--space-3); }
.detail { padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-6); }
.detail__header h1 { font-family: var(--font-display); font-weight: 900; font-size: var(--type-h1); text-transform: uppercase; margin: 0; }
.detail__uuid { font-family: var(--font-mono); color: var(--muted-ink); margin: 0 0 var(--space-3); font-size: 0.85rem; }
.detail__body { display: grid; grid-template-columns: 1fr 280px; gap: var(--space-6); align-items: start; }
@media (max-width: 768px) { .detail__body { grid-template-columns: 1fr; } }
.detail__items h2 { font-family: var(--font-display); font-weight: 700; text-transform: uppercase; margin: 0 0 var(--space-3); }
.detail__total { display: flex; justify-content: space-between; padding: var(--space-3) 0; font-family: var(--font-mono); font-weight: 700; }
.detail__sidebar { border: var(--border-thin); padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-4); }
.detail__label { font-family: var(--font-mono); color: var(--muted-ink); text-transform: uppercase; letter-spacing: 0.06em; margin: 0 0 var(--space-1); font-size: 0.75rem; }
.detail__pay-type { font-family: var(--font-mono); color: var(--muted-ink); margin: var(--space-1) 0 0; }
.detail__actions { display: flex; flex-direction: column; gap: var(--space-3); padding-top: var(--space-4); border-top: var(--border-thin); }
</style>
```

- [ ] **Step 6:** Run tests. Iterate until 7/7 pass.

- [ ] **Step 7:** Run **full DoD**:

```bash
cd frontend && pnpm test && pnpm typecheck && pnpm lint
```

Expected: all green. ~140-160 tests total.

```bash
mvn -pl order-service,bff-service test
```

Expected: all green.

- [ ] **Step 8:** Commit + push.

```bash
git commit -m "$(cat <<'EOF'
feat(fe): implement OrderDetailPage with reorder, cancel, 404 handling

Adds useOrderDetailBffQuery + OrderItemRow. REORDER loops add-to-cart
and surfaces partial-success toasts. CANCEL ORDER gated on status with
BDialog confirmation. Legacy null product_name renders fallback.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"

git push -u origin feat/phase-6-account
```

- [ ] **Step 9:** Open PR with manual-test checklist:

```bash
gh pr create --title "Phase 6: Account & order history" --body "$(cat <<'EOF'
## Summary
- Snapshot product_name + image_url onto order_item at create time (decouples order history from product-service)
- Add total_amount + item_count + first_item_image_url to OrderSummaryResponse
- Tighten BFF OrderDetailBffResponse to typed views; drop product-service runtime call
- New /account shell with Profile, Orders, Order Detail pages
- Avatar upload, profile edit, password change, order list pagination, REORDER, CANCEL ORDER

## Test plan
- [ ] Profile edit + avatar upload (sandbox)
- [ ] Password change (sandbox)
- [ ] Orders list pagination (sandbox)
- [ ] Order detail with PAID example
- [ ] Order detail with CANCELED example
- [ ] Order detail with PENDING example
- [ ] REORDER happy path
- [ ] REORDER with one out-of-stock item
- [ ] CANCEL ORDER on a PENDING order

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Done-of-Done

When Task 12 is committed, pushed, and the PR is open, Phase 6 is complete from an automated-checks perspective. The manual checklist in the PR body must be ticked by the human against a live stack — those nine items are user-only territory (PayPal sandbox session, real S3 upload, real cancellation across the saga).

If any spec requirement gets discovered un-implemented during execution, add a follow-up task to this plan rather than silently expanding scope on the implementer subagent.
