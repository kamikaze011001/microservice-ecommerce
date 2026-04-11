# Product Search & Category Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `category` field to the Product entity and support keyword search + category filtering via query params on `GET /v1/products`, unblocking the Product Browsing MFE.

**Architecture:** `Product` (MongoDB) gets a new `category` field. `ProductRepositoryCustomImpl` is extended to build dynamic MongoDB `Criteria` queries using keyword (regex on name) and category (exact match). The existing pagination math is preserved (`page - 1` offset). No new service or infrastructure is needed.

**Tech Stack:** Java 17, Spring Boot 3.3.6, Spring Data MongoDB, MongoTemplate, Lombok

---

## File Map

| Action | File |
|--------|------|
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/request/ProductRequest.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustom.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImpl.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java` |
| Modify | `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java` |
| Create | `product-service/src/test/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImplTest.java` |

---

## Task 1: Add category field to Product entity

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java`

- [ ] **Step 1: Add the category field**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.entity;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@Document
public class Product {

    @Id
    private String id;

    private String name;

    private Double price;

    private Map<String, Object> attributes;

    @Indexed
    private String category;
}
```

> `@Indexed` on `category` lets MongoDB use an index for category-filtered queries. It doesn't break existing documents — MongoDB treats missing fields as null.

- [ ] **Step 2: Compile**

```bash
cd product-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java
git commit -m "feat(product-service): add category field to Product entity"
```

---

## Task 2: Add category to ProductRequest and ProductResponse

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/request/ProductRequest.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java`

- [ ] **Step 1: Add category to ProductRequest**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.dto.request;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import lombok.experimental.SuperBuilder;
import org.aibles.ecommerce.product_service.entity.Product;

import java.util.Map;

@Data
@AllArgsConstructor
@NoArgsConstructor
@SuperBuilder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductRequest {

    @NotBlank
    private String name;

    @NotNull
    private Double price;

    @Size(min = 1)
    private Map<String, Object> attributes;

    private String category;

    public static Product to(final ProductRequest productRequest) {
        return Product.builder()
                .name(productRequest.name)
                .price(productRequest.price)
                .attributes(productRequest.attributes)
                .category(productRequest.category)
                .build();
    }
}
```

- [ ] **Step 2: Add category to ProductResponse**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.EqualsAndHashCode;
import lombok.NoArgsConstructor;
import lombok.experimental.SuperBuilder;
import org.aibles.ecommerce.product_service.entity.Product;

import java.util.Map;

@Data
@AllArgsConstructor
@NoArgsConstructor
@SuperBuilder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductResponse {

    private String id;
    private String name;
    private Double price;
    private Map<String, Object> attributes;
    private long quantity;
    private String category;

    public static ProductResponse from(final Product product, final long quantity) {
        return ProductResponse.builder()
                .id(product.getId())
                .name(product.getName())
                .price(product.getPrice())
                .quantity(quantity)
                .attributes(product.getAttributes())
                .category(product.getCategory())
                .build();
    }
}
```

- [ ] **Step 3: Compile**

```bash
cd product-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/dto/request/ProductRequest.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java
git commit -m "feat(product-service): add category to ProductRequest and ProductResponse"
```

---

## Task 3: Extend repository for search + category filter

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustom.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImpl.java`

- [ ] **Step 1: Write a failing test first**

Create `product-service/src/test/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImplTest.java`:

```java
package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Query;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductRepositoryCustomImplTest {

    @Mock
    private MongoTemplate mongoTemplate;

    private ProductRepositoryCustomImpl repo;

    @BeforeEach
    void setUp() {
        repo = new ProductRepositoryCustomImpl(mongoTemplate);
    }

    @Test
    void list_withNoFilters_shouldCallFindWithEmptyCriteria() {
        Product p = Product.builder().id("1").name("Hat").price(10.0).category("clothing").build();
        when(mongoTemplate.find(any(Query.class), eq(Product.class))).thenReturn(List.of(p));

        List<Product> result = repo.list(0, 10, null, null);

        assertThat(result).hasSize(1);
        verify(mongoTemplate).find(any(Query.class), eq(Product.class));
    }

    @Test
    void list_withKeyword_shouldReturnMatchingProducts() {
        Product p = Product.builder().id("2").name("Blue Hat").price(15.0).category("clothing").build();
        when(mongoTemplate.find(any(Query.class), eq(Product.class))).thenReturn(List.of(p));

        List<Product> result = repo.list(0, 10, "hat", null);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).getName()).containsIgnoringCase("hat");
    }

    @Test
    void total_withCategory_shouldCountOnlyMatchingCategory() {
        when(mongoTemplate.count(any(Query.class), eq(Product.class))).thenReturn(3L);

        long count = repo.total("clothing", null);

        assertThat(count).isEqualTo(3L);
        verify(mongoTemplate).count(any(Query.class), eq(Product.class));
    }
}
```

- [ ] **Step 2: Run the test — confirm it fails**

```bash
cd product-service && mvn test -Dtest=ProductRepositoryCustomImplTest -q 2>&1 | tail -5
```
Expected: COMPILE ERROR — `list(int, int, String, String)` doesn't exist yet.

- [ ] **Step 3: Update the ProductRepositoryCustom interface**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;

import java.util.List;

public interface ProductRepositoryCustom {

    List<Product> list(Integer page, Integer size, String keyword, String category);

    long total(String category, String keyword);
}
```

- [ ] **Step 4: Implement search + category filter in ProductRepositoryCustomImpl**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.repository;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
import org.springframework.data.mongodb.core.query.Query;
import org.springframework.stereotype.Repository;

import java.util.List;

@Slf4j
@Repository
public class ProductRepositoryCustomImpl implements ProductRepositoryCustom {

    private final MongoTemplate mongoTemplate;

    public ProductRepositoryCustomImpl(MongoTemplate mongoTemplate) {
        this.mongoTemplate = mongoTemplate;
    }

    @Override
    public List<Product> list(Integer page, Integer size, String keyword, String category) {
        log.info("(list) page: {}, size: {}, keyword: {}, category: {}", page, size, keyword, category);
        Query query = new Query(buildCriteria(keyword, category));
        query.skip((long) page * size);
        query.limit(size);
        return mongoTemplate.find(query, Product.class);
    }

    @Override
    public long total(String category, String keyword) {
        return mongoTemplate.count(new Query(buildCriteria(keyword, category)), Product.class);
    }

    private Criteria buildCriteria(String keyword, String category) {
        Criteria criteria = new Criteria();
        if (keyword != null && !keyword.isBlank()) {
            criteria = criteria.and("name").regex(keyword, "i");
        }
        if (category != null && !category.isBlank()) {
            criteria = criteria.and("category").is(category);
        }
        return criteria;
    }
}
```

> `regex(keyword, "i")` is case-insensitive substring match on the `name` field — simple and sufficient without Elasticsearch for a learning project.

- [ ] **Step 5: Run the test**

```bash
cd product-service && mvn test -Dtest=ProductRepositoryCustomImplTest -q
```
Expected: All 3 tests PASS

- [ ] **Step 6: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustom.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImpl.java \
        product-service/src/test/java/org/aibles/ecommerce/product_service/repository/ProductRepositoryCustomImplTest.java
git commit -m "feat(product-service): add keyword search and category filter to product repository"
```

---

## Task 4: Update ProductService and ProductServiceImpl

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java`

- [ ] **Step 1: Update ProductService interface**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;

public interface ProductService {

    ProductResponse create(ProductRequest productRequest);

    ProductResponse get(String id);

    void update(String id, ProductRequest productRequest);

    PagingResponse list(Integer page, Integer size, String keyword, String category);

    void delete(String id);
}
```

> `delete` is added here so the interface is complete. It will be implemented in Plan 4. Leave it `// TODO` in the impl for now.

- [ ] **Step 2: Update list and add stub delete in ProductServiceImpl**

Update the `list` method signature and body. Also add a stub `delete`:

Find the existing `list` method in `ProductServiceImpl.java` and replace it:

```java
@Override
@Transactional(readOnly = true)
public PagingResponse list(Integer page, Integer size, String keyword, String category) {
    log.info("(list) page: {}, size: {}, keyword: {}, category: {}", page, size, keyword, category);
    int zeroBasedPage = page - 1;
    List<Product> products = productRepository.list(zeroBasedPage, size, keyword, category);
    List<ProductResponse> productResponses = products.stream().map(product -> {
        Long quantitySum = productQuantityHistoryRepo.getQuantitySumByProductId(product.getId());
        return ProductResponse.from(product, quantitySum != null ? quantitySum : 0);
    }).toList();
    long total = productRepository.total(category, keyword);
    return PagingResponse.builder()
            .page(page)
            .size(size)
            .total(total)
            .data(productResponses)
            .build();
}

@Override
public void delete(String id) {
    // Implemented in Plan 4
    throw new UnsupportedOperationException("delete not yet implemented");
}
```

- [ ] **Step 3: Compile**

```bash
cd product-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductService.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductServiceImpl.java
git commit -m "feat(product-service): update list method to support keyword search and category filter"
```

---

## Task 5: Update ProductController to accept search query params

**Files:**
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java`

- [ ] **Step 1: Add keyword and category query params to list endpoint**

Replace the file content:

```java
package org.aibles.ecommerce.product_service.controller;

import org.aibles.ecommerce.common_dto.request.PagingRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.service.ProductService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1/products")
public class ProductController {

    private final ProductService productService;

    public ProductController(ProductService productService) {
        this.productService = productService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public BaseResponse create(@RequestBody ProductRequest request) {
        ProductResponse response = productService.create(request);
        return BaseResponse.created(response);
    }

    @GetMapping("/{id}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getById(@PathVariable String id) {
        ProductResponse response = productService.get(id);
        return BaseResponse.ok(response);
    }

    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse list(final PagingRequest pagingRequest,
                             @RequestParam(required = false) String keyword,
                             @RequestParam(required = false) String category) {
        PagingResponse response = productService.list(
                pagingRequest.getPage(), pagingRequest.getSize(), keyword, category);
        return BaseResponse.ok(response);
    }

    @PutMapping("/{id}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse update(@PathVariable String id, @RequestBody ProductRequest request) {
        productService.update(id, request);
        return BaseResponse.ok();
    }
}
```

- [ ] **Step 2: Compile**

```bash
cd product-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Run all tests**

```bash
cd product-service && mvn test -q
```
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductController.java
git commit -m "feat(product-service): add keyword and category query params to GET /v1/products"
```

---

## Verification

- [ ] Start product-service: `cd product-service && mvn spring-boot:run`
- [ ] `GET /v1/products` — confirm returns all products (same as before)
- [ ] `GET /v1/products?keyword=shirt` — confirm only products whose name contains "shirt" are returned (case-insensitive)
- [ ] `GET /v1/products?category=clothing` — confirm only products in "clothing" category returned
- [ ] `GET /v1/products?keyword=blue&category=clothing` — confirm both filters applied together
- [ ] Create a product with `"category": "electronics"` — confirm it appears under category filter
- [ ] Old products without category — confirm they still appear in unfiltered list
