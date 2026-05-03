# Cart BFF + FE Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make the cart page render real items via a new bff-service `/v1/cart` facade that fans out to order/product/inventory; fix two FE bugs (UUID greeting, dropdown bleed-through) along the way.

**Architecture:** bff-service owns the FE-facing cart contract (read enriches via OpenFeign + gRPC fan-out, writes pass-through to order-service). product-service gains an `ids` filter on `GET /v1/products`. Frontend flips four cart URLs and replaces JWT-derived greeting with a profile query.

**Tech Stack:** Spring Boot 3.3.6 / Java 17 / Maven, Spring Cloud OpenFeign, gRPC, MongoDB (product-service). Vue 3 + TS + Vite, Vitest + @testing-library/vue, Pinia.

---

## File map

**Frontend (Bug 1):**
- Modify: `frontend/src/components/layout/AppNav.vue` — read greeting from `useProfileQuery()`.
- Modify: `frontend/src/stores/auth.ts` — drop `username` computed and `decodeJwtSub` helper.
- Modify: `frontend/tests/unit/stores/auth.spec.ts` — drop username assertions.
- Create: `frontend/tests/unit/components/AppNav.spec.ts` — greeting comes from profile name.

**Frontend (Bug 3):**
- Modify: `frontend/src/components/primitives/BSelect.vue` — split portal-content rules into a sibling unscoped `<style>` block.

**product-service (Bug 2):**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepository.java` — add `findAllByIdIn`.
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java` — add `listByIds`.
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java` — implement `listByIds`.
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java` — branch `list` on `ids` param.
- Create: `product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductServiceImplListByIdsTest.java`.

**bff-service (Bug 2):**
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java` — add `listByIds`.
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java` — add 4 cart methods.
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartView.java`.
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartItemView.java`.
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/CartBffService.java`.
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/CartBffServiceImpl.java`.
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/CartController.java`.
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/BffServiceConfiguration.java` — register `cartBffService` bean.
- Create: `bff-service/src/test/java/org/aibles/ecommerce/bff_service/CartBffServiceImplTest.java`.

**Auth (Bug 2):**
- Modify: `docker/api_role.json` — 4 entries for `/bff-service/v1/cart*`.

**Frontend wiring (Bug 2):**
- Modify: `frontend/src/api/queries/cart.ts` — flip 4 URLs.
- Modify: `frontend/tests/unit/api/cart.spec.ts` — update URL assertions.

---

### Task 1: AppNav greeting via profile (Bug 1)

**Files:**
- Modify: `frontend/src/components/layout/AppNav.vue`
- Modify: `frontend/src/stores/auth.ts`
- Modify: `frontend/tests/unit/stores/auth.spec.ts`
- Create: `frontend/tests/unit/components/AppNav.spec.ts`

- [ ] **Step 1: Write the failing AppNav greeting test**

Create `frontend/tests/unit/components/AppNav.spec.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render } from '@testing-library/vue';
import { createPinia, setActivePinia } from 'pinia';
import { ref } from 'vue';
import { createRouter, createMemoryHistory } from 'vue-router';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import AppNav from '@/components/layout/AppNav.vue';
import { useAuthStore, AUTH_STORAGE_KEY } from '@/stores/auth';

vi.mock('@/api/queries/profile', () => ({
  useProfileQuery: () => ({
    data: ref({
      id: 'u1',
      name: 'Son Anh',
      email: 'son@example.com',
      gender: null,
      address: null,
    }),
    isLoading: ref(false),
    isError: ref(false),
  }),
}));
vi.mock('@/api/queries/auth', () => ({ useLogout: () => () => {} }));

const router = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/', component: { template: '<div />' } }, { path: '/account', component: { template: '<div />' } }, { path: '/login', component: { template: '<div />' } }],
});

beforeEach(() => {
  setActivePinia(createPinia());
  localStorage.clear();
  // Logged-in: persist a fake token
  localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify({ accessToken: 'h.eyJzdWIiOiJ1MSJ9.s', refreshToken: 'r' }));
});

describe('AppNav greeting', () => {
  it('shows HI, {NAME} from profile, not @{uuid}', async () => {
    useAuthStore(); // hydrate from localStorage
    const { findByTestId } = render(AppNav, {
      global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
    });
    const el = await findByTestId('nav-user');
    expect(el.textContent).toBe('HI, SON ANH');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm vitest run tests/unit/components/AppNav.spec.ts`
Expected: FAIL — current AppNav renders `@u1` (the JWT sub UUID), not `HI, SON ANH`.

- [ ] **Step 3: Update AppNav.vue greeting source**

Edit `frontend/src/components/layout/AppNav.vue` `<script setup>` — replace these lines:

```ts
import { computed, ref, watch } from 'vue';
import { RouterLink, useRouter, useRoute } from 'vue-router';
import { storeToRefs } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { useLogout } from '@/api/queries/auth';
import { BButton } from '@/components/primitives';

const auth = useAuthStore();
const { isLoggedIn, username } = storeToRefs(auth);
const logout = useLogout();
const router = useRouter();
const route = useRoute();

const greeting = computed(() => (username.value ? `@${username.value}` : ''));
```

with:

```ts
import { computed, ref, watch } from 'vue';
import { RouterLink, useRouter, useRoute } from 'vue-router';
import { storeToRefs } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { useLogout } from '@/api/queries/auth';
import { useProfileQuery } from '@/api/queries/profile';
import { BButton } from '@/components/primitives';

const auth = useAuthStore();
const { isLoggedIn } = storeToRefs(auth);
const logout = useLogout();
const router = useRouter();
const route = useRoute();

const profile = useProfileQuery();
const greeting = computed(() => {
  const name = profile.data.value?.name?.trim();
  return name ? `HI, ${name.toUpperCase()}` : '';
});
```

- [ ] **Step 4: Drop username from auth store**

Edit `frontend/src/stores/auth.ts` — delete the `decodeJwtSub` helper (lines 11–20) and update the store function:

Replace:

```ts
function decodeJwtSub(token: string): string | null {
  try {
    const payload = token.split('.')[1];
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    const parsed = JSON.parse(json) as { sub?: string };
    return parsed.sub ?? null;
  } catch {
    return null;
  }
}
```

with nothing (delete the entire function).

Then in `useAuthStore`, replace:

```ts
  const username = computed(() => (accessToken.value ? decodeJwtSub(accessToken.value) : null));
  const isLoggedIn = computed(() => accessToken.value !== null);
```

with:

```ts
  const isLoggedIn = computed(() => accessToken.value !== null);
```

And in the return statement, change:

```ts
  return { accessToken, refreshToken, username, isLoggedIn, login, clear };
```

to:

```ts
  return { accessToken, refreshToken, isLoggedIn, login, clear };
```

Also remove the unused `computed` import if it's only used for `isLoggedIn` — keep it, `isLoggedIn` still uses it.

- [ ] **Step 5: Update auth.spec.ts to drop username assertions**

Edit `frontend/tests/unit/stores/auth.spec.ts`:

Replace the test at lines 12–25:

```ts
describe('useAuthStore.login', () => {
  it('sets tokens, derives username from JWT, persists to localStorage', () => {
    const auth = useAuthStore();
    auth.login({ accessToken: FAKE_TOKEN, refreshToken: 'r' });
    expect(auth.accessToken).toBe(FAKE_TOKEN);
    expect(auth.refreshToken).toBe('r');
    expect(auth.username).toBe('son');
    expect(auth.isLoggedIn).toBe(true);
    expect(JSON.parse(localStorage.getItem(AUTH_STORAGE_KEY)!)).toMatchObject({
      accessToken: FAKE_TOKEN,
      refreshToken: 'r',
    });
  });
});
```

with:

```ts
describe('useAuthStore.login', () => {
  it('sets tokens, persists to localStorage, marks logged-in', () => {
    const auth = useAuthStore();
    auth.login({ accessToken: FAKE_TOKEN, refreshToken: 'r' });
    expect(auth.accessToken).toBe(FAKE_TOKEN);
    expect(auth.refreshToken).toBe('r');
    expect(auth.isLoggedIn).toBe(true);
    expect(JSON.parse(localStorage.getItem(AUTH_STORAGE_KEY)!)).toMatchObject({
      accessToken: FAKE_TOKEN,
      refreshToken: 'r',
    });
  });
});
```

And in the hydration test (lines 38–48), remove the line `expect(auth.username).toBe('son');`.

- [ ] **Step 6: Run all FE tests**

Run: `cd frontend && pnpm test`
Expected: PASS — including new `AppNav.spec.ts`. Existing AppNav tests (if any) might assert greeting content; if they do and they break, fix them in this same task.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/components/layout/AppNav.vue frontend/src/stores/auth.ts \
        frontend/tests/unit/stores/auth.spec.ts frontend/tests/unit/components/AppNav.spec.ts
git commit -m "fix(fe): use profile name for nav greeting, drop JWT-sub username"
```

---

### Task 2: BSelect dropdown panel CSS escape (Bug 3)

**Files:**
- Modify: `frontend/src/components/primitives/BSelect.vue`

- [ ] **Step 1: Reproduce visually (no automated test)**

Open `http://localhost:5173/account/profile` (after `pnpm dev`), click the GENDER select. The MALE/FEMALE/OTHER options should appear with NO panel background — the EMAIL field shows through.

- [ ] **Step 2: Split styles in BSelect.vue**

Edit `frontend/src/components/primitives/BSelect.vue`. The current `<style scoped>` block contains both trigger and content rules. Replace the entire `<style scoped>` block (starting at line 63) with TWO blocks:

```vue
<style scoped>
.b-select__trigger {
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  min-width: 14rem;
  padding: var(--space-3) var(--space-4);
  border: var(--border-thick);
  background: var(--paper);
  font-family: var(--font-body);
  color: var(--ink);
  box-shadow: var(--shadow-md);
  cursor: pointer;
}
.b-select__trigger.has-error {
  border-color: var(--stamp-red);
}
.b-select__chev {
  font-family: var(--font-mono);
}
</style>

<style>
.b-select__content {
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-lg);
  z-index: 60;
  min-width: var(--reka-select-trigger-width);
}
.b-select__viewport {
  padding: var(--space-1);
}
.b-select__item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  padding: var(--space-2) var(--space-4);
  cursor: pointer;
  user-select: none;
  background: var(--paper);
}
.b-select__item[data-highlighted] {
  background: var(--spot);
  color: var(--ink);
}
.b-select__check {
  font-family: var(--font-mono);
}
</style>
```

(Note: also added explicit `background: var(--paper)` on `.b-select__item` itself as belt-and-braces for the bleed-through.)

- [ ] **Step 3: Verify visually**

Reload the profile page. Click the GENDER select. Panel should have a cream background, 3px black border, drop shadow. EMAIL field below should not be visible through the dropdown.

- [ ] **Step 4: Run FE tests**

Run: `cd frontend && pnpm test && pnpm typecheck && pnpm lint`
Expected: all PASS, 0 lint warnings.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/primitives/BSelect.vue
git commit -m "fix(fe): lift BSelect portal-content styles out of scoped block"
```

---

### Task 3: product-service `?ids=` filter

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepository.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java`
- Create: `product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductServiceImplListByIdsTest.java`

- [ ] **Step 1: Write failing service test**

Create `product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductServiceImplListByIdsTest.java`:

```java
package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.impl.ProductServiceImpl;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.context.ApplicationEventPublisher;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductServiceImplListByIdsTest {

    @Mock private ProductRepository productRepository;
    @Mock private ProductQuantityHistoryRepo productQuantityHistoryRepo;
    @Mock private ApplicationEventPublisher publisher;

    @Test
    void listByIds_returnsMatchingProductsOnly() {
        ProductServiceImpl service = new ProductServiceImpl(productRepository, productQuantityHistoryRepo, publisher);
        Product p1 = new Product();
        p1.setId("p1"); p1.setName("Issue Nº01"); p1.setPrice(25.0); p1.setImageUrl("http://img/p1.png");
        Product p2 = new Product();
        p2.setId("p2"); p2.setName("Issue Nº02"); p2.setPrice(30.0); p2.setImageUrl("http://img/p2.png");
        when(productRepository.findAllByIdIn(Set.of("p1", "p2"))).thenReturn(List.of(p1, p2));
        when(productQuantityHistoryRepo.getQuantitySumByProductId("p1")).thenReturn(5L);
        when(productQuantityHistoryRepo.getQuantitySumByProductId("p2")).thenReturn(0L);

        List<ProductResponse> result = service.listByIds(Set.of("p1", "p2"));

        assertThat(result).hasSize(2);
        assertThat(result).extracting(ProductResponse::getId).containsExactlyInAnyOrder("p1", "p2");
    }

    @Test
    void listByIds_emptyInput_returnsEmpty() {
        ProductServiceImpl service = new ProductServiceImpl(productRepository, productQuantityHistoryRepo, publisher);
        assertThat(service.listByIds(Set.of())).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd product-service && mvn -Dtest='ProductServiceImplListByIdsTest' test`
Expected: FAIL — `findAllByIdIn` does not exist on `ProductRepository`, `listByIds` does not exist on `ProductServiceImpl`.

- [ ] **Step 3: Add `findAllByIdIn` to ProductRepository**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepository.java`:

Replace:

```java
package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.repository.MongoRepository;

public interface ProductRepository extends MongoRepository<Product, String>, ProductRepositoryCustom {
}
```

with:

```java
package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.repository.MongoRepository;

import java.util.Collection;
import java.util.List;

public interface ProductRepository extends MongoRepository<Product, String>, ProductRepositoryCustom {

    List<Product> findAllByIdIn(Collection<String> ids);
}
```

- [ ] **Step 4: Add `listByIds` to ProductService interface**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java` — add to the interface (after the existing `list` method):

```java
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import java.util.Collection;
import java.util.List;
```

(merge with existing imports), and inside the interface body:

```java
    List<ProductResponse> listByIds(Collection<String> ids);
```

- [ ] **Step 5: Implement `listByIds` in ProductServiceImpl**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java`. Add this method (place it next to the existing `list`):

```java
    @Override
    @Transactional(readOnly = true)
    public List<ProductResponse> listByIds(Collection<String> ids) {
        log.info("(listByIds) ids: {}", ids);
        if (ids == null || ids.isEmpty()) return List.of();
        List<Product> products = productRepository.findAllByIdIn(ids);
        return products.stream().map(product -> {
            Long quantitySum = productQuantityHistoryRepo.getQuantitySumByProductId(product.getId());
            return ProductResponse.from(product, quantitySum != null ? quantitySum : 0);
        }).toList();
    }
```

Add `import java.util.Collection;` if not already present.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd product-service && mvn -Dtest='ProductServiceImplListByIdsTest' test`
Expected: PASS, 2 tests.

- [ ] **Step 7: Branch ProductController on `ids` param**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java`. Replace the existing `list` method:

```java
    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse list(final PagingRequest pagingRequest,
                             @RequestParam(required = false) String keyword,
                             @RequestParam(required = false) String category) {
        PagingResponse response = productService.list(pagingRequest.getPage(), pagingRequest.getSize(), keyword, category);
        return BaseResponse.ok(response);
    }
```

with:

```java
    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse list(final PagingRequest pagingRequest,
                             @RequestParam(required = false) String keyword,
                             @RequestParam(required = false) String category,
                             @RequestParam(required = false) java.util.Set<String> ids) {
        if (ids != null && !ids.isEmpty()) {
            return BaseResponse.ok(productService.listByIds(ids));
        }
        PagingResponse response = productService.list(pagingRequest.getPage(), pagingRequest.getSize(), keyword, category);
        return BaseResponse.ok(response);
    }
```

- [ ] **Step 8: Run full product-service tests**

Run: `cd product-service && mvn test -q`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepository.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java \
        product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductServiceImplListByIdsTest.java
git commit -m "feat(product-service): add ?ids= filter to GET /v1/products"
```

---

### Task 4: Extend Feign clients in bff-service

**Files:**
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java`
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java`

- [ ] **Step 1: Extend ProductFeignClient with listByIds**

Replace `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java` entirely:

```java
package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;

import java.util.Set;

@FeignClient(name = "product-service")
public interface ProductFeignClient {

    @GetMapping("/v1/products/{id}")
    BaseResponse getById(@PathVariable("id") String id);

    @GetMapping("/v1/products")
    BaseResponse listByIds(@RequestParam("ids") Set<String> ids);
}
```

- [ ] **Step 2: Extend OrderFeignClient with cart methods**

Replace `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java` entirely:

```java
package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;

import java.util.Map;

@FeignClient(name = "order-service")
public interface OrderFeignClient {

    @GetMapping("/v1/orders/{orderId}")
    BaseResponse getOrder(@RequestHeader("X-User-Id") String userId,
                          @PathVariable("orderId") String orderId);

    @GetMapping("/v1/shopping-carts")
    BaseResponse getCart(@RequestHeader("X-User-Id") String userId);

    @PostMapping("/v1/shopping-carts:add-item")
    BaseResponse addCartItem(@RequestHeader("X-User-Id") String userId,
                             @RequestBody Map<String, Object> body);

    @PatchMapping("/v1/shopping-carts:update-item")
    BaseResponse updateCartItem(@RequestBody Map<String, Object> body);

    @DeleteMapping("/v1/shopping-carts:delete-item")
    BaseResponse deleteCartItem(@RequestParam("itemId") String itemId);
}
```

- [ ] **Step 3: Compile bff-service**

Run: `cd bff-service && mvn -q compile`
Expected: PASS (no test compile yet — that's task 6).

- [ ] **Step 4: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java
git commit -m "feat(bff-service): extend Feign clients with cart + product-by-ids methods"
```

---

### Task 5: CartView + CartItemView DTOs

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartView.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartItemView.java`

- [ ] **Step 1: Create CartItemView**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartItemView.java`:

```java
package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class CartItemView {
    private String shoppingCartItemId;
    private String productId;
    private String name;
    private String imageUrl;
    private Double unitPrice;
    private Long quantity;
    private Long availableStock;
}
```

- [ ] **Step 2: Create CartView**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartView.java`:

```java
package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.List;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class CartView {
    private String shoppingCartId;
    private String userId;
    private List<CartItemView> items;
}
```

- [ ] **Step 3: Compile**

Run: `cd bff-service && mvn -q compile`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartView.java \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/response/CartItemView.java
git commit -m "feat(bff-service): add CartView + CartItemView DTOs"
```

---

### Task 6: CartBffService — interface, impl, tests

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/CartBffService.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/CartBffServiceImpl.java`
- Create: `bff-service/src/test/java/org/aibles/ecommerce/bff_service/CartBffServiceImplTest.java`

- [ ] **Step 1: Define the interface**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/CartBffService.java`:

```java
package org.aibles.ecommerce.bff_service.service;

import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.common_dto.response.BaseResponse;

import java.util.Map;

public interface CartBffService {
    CartView getCart(String userId);
    BaseResponse addItem(String userId, Map<String, Object> body);
    BaseResponse updateItem(Map<String, Object> body);
    BaseResponse deleteItem(String itemId);
}
```

- [ ] **Step 2: Write failing test for CartBffServiceImpl**

Create `bff-service/src/test/java/org/aibles/ecommerce/bff_service/CartBffServiceImplTest.java`:

```java
package org.aibles.ecommerce.bff_service;

import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.bff_service.service.impl.CartBffServiceImpl;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anySet;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CartBffServiceImplTest {

    @Mock private OrderFeignClient orderFeignClient;
    @Mock private ProductFeignClient productFeignClient;
    @Mock private InventoryGrpcClientService inventoryGrpcClientService;

    private CartBffServiceImpl service() {
        return new CartBffServiceImpl(orderFeignClient, productFeignClient, inventoryGrpcClientService);
    }

    private BaseResponse cartResponse(List<Map<String, Object>> items) {
        BaseResponse r = new BaseResponse();
        r.setData(Map.of("shoppingCarts", items));
        return r;
    }

    private BaseResponse productListResponse(List<Map<String, Object>> products) {
        BaseResponse r = new BaseResponse();
        r.setData(products);
        return r;
    }

    @Test
    void getCart_emptyCart_returnsEmptyItems() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of()));
        CartView view = service().getCart("u1");
        assertThat(view.getUserId()).isEqualTo("u1");
        assertThat(view.getItems()).isEmpty();
    }

    @Test
    void getCart_normal_mergesProductAndInventory() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2)
        )));
        when(productFeignClient.listByIds(Set.of("p1"))).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder()
                .addInventoryProducts(InventoryProduct.newBuilder().setId("p1").setQuantity(10L).build())
                .build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems()).hasSize(1);
        var item = view.getItems().get(0);
        assertThat(item.getShoppingCartItemId()).isEqualTo("ci1");
        assertThat(item.getProductId()).isEqualTo("p1");
        assertThat(item.getName()).isEqualTo("Issue Nº01");
        assertThat(item.getImageUrl()).isEqualTo("http://img/p1.png");
        assertThat(item.getUnitPrice()).isEqualTo(25.0);
        assertThat(item.getQuantity()).isEqualTo(2L);
        assertThat(item.getAvailableStock()).isEqualTo(10L);
    }

    @Test
    void getCart_productMissing_dropsRow() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2),
            Map.of("id", "ci2", "productId", "p2", "price", 30.0, "quantity", 1)
        )));
        when(productFeignClient.listByIds(any())).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder()
                .addInventoryProducts(InventoryProduct.newBuilder().setId("p1").setQuantity(10L).build())
                .build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems()).hasSize(1);
        assertThat(view.getItems().get(0).getProductId()).isEqualTo("p1");
    }

    @Test
    void getCart_inventoryMissing_defaultsStockToZero() {
        when(orderFeignClient.getCart("u1")).thenReturn(cartResponse(List.of(
            Map.of("id", "ci1", "productId", "p1", "price", 25.0, "quantity", 2)
        )));
        when(productFeignClient.listByIds(any())).thenReturn(productListResponse(List.of(
            Map.of("id", "p1", "name", "Issue Nº01", "imageUrl", "http://img/p1.png")
        )));
        when(inventoryGrpcClientService.fetchInventory(anyList())).thenReturn(
            InventoryProductIdsResponse.newBuilder().build()
        );

        CartView view = service().getCart("u1");

        assertThat(view.getItems().get(0).getAvailableStock()).isEqualTo(0L);
    }
}
```

(Add `import static org.mockito.ArgumentMatchers.anyList;` at the top of the imports.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd bff-service && mvn -Dtest='CartBffServiceImplTest' test`
Expected: FAIL — `CartBffServiceImpl` does not exist.

- [ ] **Step 4: Implement CartBffServiceImpl**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/CartBffServiceImpl.java`:

```java
package org.aibles.ecommerce.bff_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.response.CartItemView;
import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.bff_service.service.CartBffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
public class CartBffServiceImpl implements CartBffService {

    private final OrderFeignClient orderFeignClient;
    private final ProductFeignClient productFeignClient;
    private final InventoryGrpcClientService inventoryGrpcClientService;

    public CartBffServiceImpl(OrderFeignClient orderFeignClient,
                              ProductFeignClient productFeignClient,
                              InventoryGrpcClientService inventoryGrpcClientService) {
        this.orderFeignClient = orderFeignClient;
        this.productFeignClient = productFeignClient;
        this.inventoryGrpcClientService = inventoryGrpcClientService;
    }

    @Override
    @SuppressWarnings("unchecked")
    public CartView getCart(String userId) {
        log.info("(getCart) userId: {}", userId);

        BaseResponse cartResp = orderFeignClient.getCart(userId);
        Map<String, Object> cartData = (Map<String, Object>) cartResp.getData();
        List<Map<String, Object>> rawRows = (List<Map<String, Object>>) cartData.getOrDefault("shoppingCarts", Collections.emptyList());

        if (rawRows.isEmpty()) {
            return CartView.builder()
                    .shoppingCartId("cart-" + userId)
                    .userId(userId)
                    .items(List.of())
                    .build();
        }

        Set<String> productIds = rawRows.stream()
                .map(r -> (String) r.get("productId"))
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toSet());

        Map<String, Map<String, Object>> productById = new HashMap<>();
        BaseResponse prodResp = productFeignClient.listByIds(productIds);
        List<Map<String, Object>> products = (List<Map<String, Object>>) prodResp.getData();
        if (products != null) {
            for (Map<String, Object> p : products) {
                productById.put((String) p.get("id"), p);
            }
        }

        Map<String, Long> stockById = new HashMap<>();
        for (InventoryProduct inv : inventoryGrpcClientService.fetchInventory(new ArrayList<>(productIds)).getInventoryProductsList()) {
            stockById.put(inv.getId(), inv.getQuantity());
        }

        List<CartItemView> items = new ArrayList<>();
        for (Map<String, Object> row : rawRows) {
            String productId = (String) row.get("productId");
            Map<String, Object> product = productById.get(productId);
            if (product == null) {
                log.warn("(getCart) product {} missing — dropping cart row {}", productId, row.get("id"));
                continue;
            }
            Object priceObj = row.get("price");
            Object qtyObj = row.get("quantity");
            items.add(CartItemView.builder()
                    .shoppingCartItemId((String) row.get("id"))
                    .productId(productId)
                    .name((String) product.get("name"))
                    .imageUrl((String) product.get("imageUrl"))
                    .unitPrice(priceObj != null ? ((Number) priceObj).doubleValue() : null)
                    .quantity(qtyObj != null ? ((Number) qtyObj).longValue() : 0L)
                    .availableStock(stockById.getOrDefault(productId, 0L))
                    .build());
        }

        return CartView.builder()
                .shoppingCartId("cart-" + userId)
                .userId(userId)
                .items(items)
                .build();
    }

    @Override
    public BaseResponse addItem(String userId, Map<String, Object> body) {
        log.info("(addItem) userId: {}, body: {}", userId, body);
        return orderFeignClient.addCartItem(userId, body);
    }

    @Override
    public BaseResponse updateItem(Map<String, Object> body) {
        log.info("(updateItem) body: {}", body);
        return orderFeignClient.updateCartItem(body);
    }

    @Override
    public BaseResponse deleteItem(String itemId) {
        log.info("(deleteItem) itemId: {}", itemId);
        return orderFeignClient.deleteCartItem(itemId);
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd bff-service && mvn -Dtest='CartBffServiceImplTest' test`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/CartBffService.java \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/CartBffServiceImpl.java \
        bff-service/src/test/java/org/aibles/ecommerce/bff_service/CartBffServiceImplTest.java
git commit -m "feat(bff-service): cart enrichment service with TDD coverage"
```

---

### Task 7: CartController + bean wiring

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/CartController.java`
- Modify: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/BffServiceConfiguration.java`

- [ ] **Step 1: Create CartController**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/CartController.java`:

```java
package org.aibles.ecommerce.bff_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.service.CartBffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/v1/cart")
public class CartController {

    private final CartBffService cartBffService;

    public CartController(CartBffService cartBffService) {
        this.cartBffService = cartBffService;
    }

    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getCart(@RequestHeader("X-User-Id") String userId) {
        log.info("(getCart) userId: {}", userId);
        return BaseResponse.ok(cartBffService.getCart(userId));
    }

    @PostMapping(":add-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse addItem(@RequestHeader("X-User-Id") String userId,
                                @RequestBody Map<String, Object> body) {
        log.info("(addItem) userId: {}", userId);
        return cartBffService.addItem(userId, body);
    }

    @PatchMapping(":update-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse updateItem(@RequestBody Map<String, Object> body) {
        log.info("(updateItem)");
        return cartBffService.updateItem(body);
    }

    @DeleteMapping(":delete-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse deleteItem(@RequestParam("itemId") String itemId) {
        log.info("(deleteItem) itemId: {}", itemId);
        return cartBffService.deleteItem(itemId);
    }
}
```

- [ ] **Step 2: Wire CartBffService bean in BffServiceConfiguration**

Edit `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/BffServiceConfiguration.java`. Replace the file:

```java
package org.aibles.ecommerce.bff_service.configuration;

import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.PaymentFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.bff_service.service.CartBffService;
import org.aibles.ecommerce.bff_service.service.impl.BffServiceImpl;
import org.aibles.ecommerce.bff_service.service.impl.CartBffServiceImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class BffServiceConfiguration {

    @Bean
    public BffService bffService(ProductFeignClient productFeignClient,
                                 OrderFeignClient orderFeignClient,
                                 PaymentFeignClient paymentFeignClient,
                                 InventoryGrpcClientService inventoryGrpcClientService) {
        return new BffServiceImpl(productFeignClient, orderFeignClient, paymentFeignClient, inventoryGrpcClientService);
    }

    @Bean
    public CartBffService cartBffService(OrderFeignClient orderFeignClient,
                                         ProductFeignClient productFeignClient,
                                         InventoryGrpcClientService inventoryGrpcClientService) {
        return new CartBffServiceImpl(orderFeignClient, productFeignClient, inventoryGrpcClientService);
    }
}
```

- [ ] **Step 3: Compile + test bff-service**

Run: `cd bff-service && mvn test -q`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/CartController.java \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/BffServiceConfiguration.java
git commit -m "feat(bff-service): /v1/cart routes wired"
```

---

### Task 8: Auth rules for /bff-service/v1/cart\*

**Files:**
- Modify: `docker/api_role.json`

- [ ] **Step 1: Add 4 entries**

Edit `docker/api_role.json`. After the existing `/order-service/v1/shopping-carts**` entry (around line 121), insert:

```json
,
  {
    "_id": {"$oid": "67ff000000000000000c0001"},
    "path": "/bff-service/v1/cart",
    "roles": ["AUTHORIZED"],
    "method": ["GET"]
  },
  {
    "_id": {"$oid": "67ff000000000000000c0002"},
    "path": "/bff-service/v1/cart:add-item",
    "roles": ["AUTHORIZED"],
    "method": ["POST"]
  },
  {
    "_id": {"$oid": "67ff000000000000000c0003"},
    "path": "/bff-service/v1/cart:update-item",
    "roles": ["AUTHORIZED"],
    "method": ["PATCH"]
  },
  {
    "_id": {"$oid": "67ff000000000000000c0004"},
    "path": "/bff-service/v1/cart:delete-item",
    "roles": ["AUTHORIZED"],
    "method": ["DELETE"]
  }
```

(Match the comma/indent style of surrounding entries — entries are comma-separated objects in a JSON array.)

- [ ] **Step 2: Validate JSON**

Run: `python3 -m json.tool docker/api_role.json > /dev/null && echo OK`
Expected: `OK` printed.

- [ ] **Step 3: Re-seed MongoDB so the new rules take effect**

Run: `make seed-data`
Expected: success message; gateway picks up new rules on next request (rules are read from MongoDB on each gateway request).

- [ ] **Step 4: Commit**

```bash
git add docker/api_role.json
git commit -m "feat(gateway): add AUTHORIZED rules for /bff-service/v1/cart*"
```

---

### Task 9: Frontend URL flip + test update

**Files:**
- Modify: `frontend/src/api/queries/cart.ts`
- Modify: `frontend/tests/unit/api/cart.spec.ts`

- [ ] **Step 1: Update cart.spec.ts URL assertions**

Edit `frontend/tests/unit/api/cart.spec.ts`. Replace the four URL strings:

- `'/order-service/v1/shopping-carts'` → `'/bff-service/v1/cart'`
- `'/order-service/v1/shopping-carts:add-item'` → `'/bff-service/v1/cart:add-item'`
- `'/order-service/v1/shopping-carts:update-item'` → `'/bff-service/v1/cart:update-item'`
- `'/order-service/v1/shopping-carts:delete-item?itemId=i1'` → `'/bff-service/v1/cart:delete-item?itemId=i1'`

(Use sed or your editor's find-replace inside this one file.)

- [ ] **Step 2: Run cart.spec.ts to verify it fails**

Run: `cd frontend && pnpm vitest run tests/unit/api/cart.spec.ts`
Expected: FAIL — `cart.ts` still hits `/order-service/...`.

- [ ] **Step 3: Update cart.ts URLs**

Edit `frontend/src/api/queries/cart.ts`. Replace the four URLs in the same way:

- Line 40: `'/order-service/v1/shopping-carts'` → `'/bff-service/v1/cart'`
- Line 49: `'/order-service/v1/shopping-carts:add-item'` → `'/bff-service/v1/cart:add-item'`
- Line 61: `'/order-service/v1/shopping-carts:update-item'` → `'/bff-service/v1/cart:update-item'`
- Line 92: `/order-service/v1/shopping-carts:delete-item?itemId=…` → `/bff-service/v1/cart:delete-item?itemId=…`

- [ ] **Step 4: Run all FE tests**

Run: `cd frontend && pnpm test && pnpm typecheck && pnpm lint`
Expected: all PASS, 0 lint warnings.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/queries/cart.ts frontend/tests/unit/api/cart.spec.ts
git commit -m "feat(fe): switch cart calls to /bff-service/v1/cart*"
```

---

### Task 10: Manual smoke + push

**No file changes — verification only.**

- [ ] **Step 1: Rebuild affected services**

Run, sequentially:

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
(cd product-service && mvn -q clean package -DskipTests)
(cd bff-service && mvn -q clean package -DskipTests)
```

- [ ] **Step 2: Restart product-service and bff-service**

```bash
scripts/services/stop.sh product-service
scripts/services/stop.sh bff-service
scripts/services/start.sh product-service
scripts/services/start.sh bff-service
```

Verify each comes up: `tail -20 logs/services/product-service.log` and `…/bff-service.log` should show `Started ...Application` with no exceptions.

- [ ] **Step 3: Smoke the cart through the FE**

```bash
cd frontend && pnpm dev
```

In the browser:
1. Log in as `sonanh2001` / `Password1!`.
2. Verify the nav shows `HI, SON ANH` (not `@<uuid>`).
3. Add a product to cart from a product detail page.
4. Open `/cart` — verify line item shows name, image, price, quantity, with a working +/- and Remove.
5. Open `/account/profile`, click GENDER select — dropdown should show with proper cream background and black border, EMAIL field NOT visible behind options.

- [ ] **Step 4: Push branch**

```bash
git push origin feat/phase-7-polish-deploy
```

The existing PR (#7) updates with these commits.

- [ ] **Step 5: Done**

No further commit. Report task list complete.

---

## Self-review notes

- Spec coverage: Bug 1 → Task 1; Bug 3 → Task 2; product-service `?ids=` → Task 3; bff-service Feign extensions → Task 4; DTOs → Task 5; service + tests → Task 6; controller + wiring → Task 7; auth rules → Task 8; FE URL flip → Task 9; smoke → Task 10. The "downstream-503" error case from the spec is intentionally not in the unit test — Mockito throwing from a stub propagates as an unchecked exception, and Spring's default error handling will return 5xx to the FE. The FE's existing `cart.isError.value` branch handles it. If a stronger contract is desired, add a single `RestClientException` test in a follow-up.
- Type consistency: `CartView.shoppingCartId / userId / items`, `CartItemView.shoppingCartItemId / productId / name / imageUrl / unitPrice / quantity / availableStock`. All match the FE's `CartResponse` / `CartItem` interfaces in `frontend/src/api/queries/cart.ts`.
- Action-verb paths use `:add-item / :update-item / :delete-item` consistently in controller, Feign client, FE URL, and api_role rules.
