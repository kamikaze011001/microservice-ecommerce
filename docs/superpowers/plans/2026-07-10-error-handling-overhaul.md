# Error-handling Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make error messages clear, consistent, and i18n-resolved end-to-end by fixing the response contract, reviving the dead `MessageSource`, and shipping two enhancement loops (backend catalog, frontend display) to sweep the rest.

**Architecture:** Keep `BaseResponse{status, code, data}` untouched; move domain error detail into a typed `ErrorData` object *inside* `data`. `GlobalExceptionHandler` resolves a stable dotted `code` to human text via a revived `MessageSource` (base bundle in `core-exception-api` + per-service `messages/<service>.properties`). A CI gate (`check-error-catalog.sh`) enforces that every thrown code is dotted and resolvable. Two `/loop` skills sweep services and pages one unit per iteration, in the mold of the existing `a11y-step` loop.

**Tech Stack:** Spring Boot 3.3.6 (Java, Lombok, manual `@Bean` wiring), JUnit 5; Vue 3 + TypeScript + openapi-fetch + vee-validate + Pinia + Vitest/happy-dom; Node ESM detector scripts; Bash + `gh` for loop PRs.

## Global Constraints

- **Do NOT change `BaseResponse`'s fields** — `common-dto/CLAUDE.md`: "touch with care, ripples across the whole stack." Only add new classes.
- **DTOs are `@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)`** — wire format is snake_case.
- **Service beans are wired manually in `@Configuration` classes**, NOT via `@Component`/`@Service`.
- **i18n placeholders are `%key%`**, resolved from the `params` map by `I18nHelperImpl` — NOT `{0}` positional.
- **Code convention:** `<domain>.<entity>.<reason>`, matching regex `^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$` (lower snake, ≥1 dot). Cross-cutting codes use `common.*`, `validation.*`, `auth.*`.
- **Maven build order:** `core` modules install before services — run `make build` (wraps `scripts/maven/install-modules.sh`) after touching any `core/*` module.
- **Every commit** ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Never auto-merge.** Loop output is always a PR a human merges.

## File Structure

**Phase 0 — Foundation (this plan, one reviewed PR):**
- Create `core/common-dto/.../response/ErrorData.java` — typed error payload (`code`, `message`, `errors`).
- Modify `core/common-dto/.../exception/{BaseException,NotFoundException,BadRequestException,ConflictException,ForbiddenException,UnauthorizedException,InternalErrorException}.java` — dotted default codes + code/param constructors.
- Modify `core/core-exception-api/.../configuration/GlobalExceptionHandler.java` — build `ErrorData` into `data`.
- Create `core/core-exception-api/src/main/resources/messages.properties` — base bundle.
- Modify each service's `application.yml` `application.i18n.resources` — list base + own bundle (reference service only in Phase 0).
- Modify `gateway/.../filter/{JwtAuthenticationFilter,AuthorizationFilter}.java` — align error JSON to the contract.
- Create `scripts/check-error-catalog.sh` — the CI gate.
- Create `scripts/next-error-target.mjs` + reuse — the backend detector.
- Modify `frontend/src/api/client.ts` + `frontend/src/api/error.ts` — read `data.{code,message,errors}`.
- Create `frontend/src/composables/useApiError.ts` — display helper for the Phase-2 loop.
- Migrate `product-service` end-to-end as the reference implementation.

**Loop machinery (this plan):**
- Create `.claude/skills/error-catalog-step/SKILL.md` — backend loop.
- Create `.claude/skills/error-display-step/SKILL.md` — frontend loop.
- Modify `.github/workflows/*` — wire the gate + a bare-catch grep gate.
- Modify docs: `core/core-exception-api/CLAUDE.md` (stale `success` field), `frontend/docs/enhance-loops.md`.

**Executed later by running the loops (NOT tasks here):** migrating the remaining services and pages.

---

## Task 1: `ErrorData` DTO

**Files:**
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/response/ErrorData.java`
- Test: `core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/response/ErrorDataTest.java`

**Interfaces:**
- Produces: `ErrorData` with `static ErrorData of(String code, String message)` and `static ErrorData of(String code, String message, Map<String,String> errors)`; fields `code`, `message`, `errors` (nullable). Serializes to snake_case `{code, message, errors}`; `errors` omitted when null.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.common_dto.response;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ErrorDataTest {

  private final ObjectMapper mapper = new ObjectMapper();

  @Test
  void serializes_code_and_message_and_omits_null_errors() throws Exception {
    String json = mapper.writeValueAsString(ErrorData.of("order.not_found", "Order A123 was not found."));
    assertThat(json).contains("\"code\":\"order.not_found\"");
    assertThat(json).contains("\"message\":\"Order A123 was not found.\"");
    assertThat(json).doesNotContain("errors");
  }

  @Test
  void serializes_field_errors_map() throws Exception {
    String json = mapper.writeValueAsString(
        ErrorData.of("validation.failed", "One or more fields are invalid.", Map.of("email", "must be valid")));
    assertThat(json).contains("\"errors\":{\"email\":\"must be valid\"}");
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core/common-dto && mvn -q test -Dtest=ErrorDataTest`
Expected: FAIL — `ErrorData` does not exist (compilation error).

- [ ] **Step 3: Write minimal implementation**

```java
package org.aibles.ecommerce.common_dto.response;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonInclude(JsonInclude.Include.NON_NULL)
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ErrorData {

  private String code;
  private String message;
  private Map<String, String> errors;

  public static ErrorData of(String code, String message) {
    return new ErrorData(code, message, null);
  }

  public static ErrorData of(String code, String message, Map<String, String> errors) {
    return new ErrorData(code, message, errors);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core/common-dto && mvn -q test -Dtest=ErrorDataTest`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/response/ErrorData.java \
        core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/response/ErrorDataTest.java
git commit -m "feat(common-dto): add typed ErrorData payload for error responses

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Dotted default codes + code constructors on common exceptions

Turns the FQN default codes (e.g. `org.aibles.business.exception.NotFoundException`) into dotted `common.*` keys, and adds constructors so throw-sites can pass a specific code + params. This makes even un-migrated bare throws resolve to a human (if generic) message.

**Files:**
- Modify: `core/common-dto/.../exception/BaseException.java`
- Modify: `core/common-dto/.../exception/NotFoundException.java` and the 5 siblings (`BadRequestException`, `ConflictException`, `ForbiddenException`, `UnauthorizedException`, `InternalErrorException`)
- Test: `core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/exception/CommonExceptionCodeTest.java`

**Interfaces:**
- Consumes: `BaseException.addParams(key, value)` (exists), `setCode`, `setStatus`.
- Produces: each semantic exception exposes `NoArgsConstructor` (dotted `common.*` default) **and** `XxxException(String code)` **and** `XxxException(String code, Map<String,String> params)`. Default codes: `common.not_found` (404), `common.bad_request` (400), `common.conflict` (409), `common.forbidden` (403), `common.unauthorized` (401), `common.internal_error` (500).

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.common_dto.exception;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CommonExceptionCodeTest {

  @Test
  void notFound_has_dotted_default_code_and_404() {
    NotFoundException ex = new NotFoundException();
    assertThat(ex.getStatus()).isEqualTo(404);
    assertThat(ex.getCode()).isEqualTo("common.not_found");
  }

  @Test
  void notFound_accepts_specific_code_and_params() {
    NotFoundException ex = new NotFoundException("order.not_found", Map.of("id", "A123"));
    assertThat(ex.getCode()).isEqualTo("order.not_found");
    assertThat(ex.getParams()).containsEntry("id", "A123");
    assertThat(ex.getStatus()).isEqualTo(404);
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core/common-dto && mvn -q test -Dtest=CommonExceptionCodeTest`
Expected: FAIL — `NotFoundException(String, Map)` constructor missing; default code is the FQN.

- [ ] **Step 3: Write minimal implementation**

`NotFoundException.java` (apply the same shape to each sibling, swapping status + default code):

```java
package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class NotFoundException extends BaseException {

  public NotFoundException() {
    this("common.not_found", null);
  }

  public NotFoundException(String code) {
    this(code, null);
  }

  public NotFoundException(String code, Map<String, String> params) {
    setStatus(404);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
```

Sibling defaults: `BadRequestException` → status `400`, code `common.bad_request`; `ConflictException` → `409`, `common.conflict`; `ForbiddenException` → `403`, `common.forbidden`; `UnauthorizedException` → `401`, `common.unauthorized`; `InternalErrorException` → `500`, `common.internal_error`. Leave `BaseException.java` unchanged (it already has `addParams`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core/common-dto && mvn -q test -Dtest=CommonExceptionCodeTest,ImageExceptionsTest`
Expected: PASS. (Run `ImageExceptionsTest` too — the image exceptions subclass these; confirm nothing regressed.)

- [ ] **Step 5: Commit**

```bash
git add core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/*.java \
        core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/exception/CommonExceptionCodeTest.java
git commit -m "feat(common-dto): dotted common.* default codes + code/param constructors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Base message bundle in core-exception-api

**Files:**
- Create: `core/core-exception-api/src/main/resources/messages.properties`
- Test: `core/core-exception-api/src/test/java/org/aibles/ecommerce/core_exception_api/BaseBundleTest.java`

**Interfaces:**
- Produces: resolvable keys `common.not_found`, `common.bad_request`, `common.conflict`, `common.forbidden`, `common.unauthorized`, `common.internal_error`, `validation.failed`.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.core_exception_api;

import org.junit.jupiter.api.Test;
import org.springframework.context.support.ReloadableResourceBundleMessageSource;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class BaseBundleTest {

  @Test
  void base_bundle_resolves_common_codes() {
    var ms = new ReloadableResourceBundleMessageSource();
    ms.setBasename("classpath:messages");
    ms.setDefaultEncoding("UTF-8");
    assertThat(ms.getMessage("common.not_found", null, Locale.ENGLISH))
        .isEqualTo("The requested resource was not found.");
    assertThat(ms.getMessage("common.internal_error", null, Locale.ENGLISH))
        .isEqualTo("Something went wrong on our end. Please try again.");
    assertThat(ms.getMessage("validation.failed", null, Locale.ENGLISH))
        .isEqualTo("One or more fields are invalid.");
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core/core-exception-api && mvn -q test -Dtest=BaseBundleTest`
Expected: FAIL — `NoSuchMessageException` (no `messages.properties`).

- [ ] **Step 3: Write minimal implementation**

`core/core-exception-api/src/main/resources/messages.properties`:

```properties
# Cross-cutting fallback codes. Service-specific codes live in messages/<service>.properties.
common.not_found=The requested resource was not found.
common.bad_request=The request was invalid.
common.conflict=That action conflicts with the current state.
common.forbidden=You do not have permission to do that.
common.unauthorized=Please sign in to continue.
common.internal_error=Something went wrong on our end. Please try again.
validation.failed=One or more fields are invalid.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core/core-exception-api && mvn -q test -Dtest=BaseBundleTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/core-exception-api/src/main/resources/messages.properties \
        core/core-exception-api/src/test/java/org/aibles/ecommerce/core_exception_api/BaseBundleTest.java
git commit -m "feat(core-exception-api): ship base message bundle for common.* + validation codes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `GlobalExceptionHandler` builds `ErrorData` into `data`

**Files:**
- Modify: `core/core-exception-api/.../configuration/GlobalExceptionHandler.java`
- Test: `core/core-exception-api/src/test/java/org/aibles/ecommerce/core_exception_api/GlobalExceptionHandlerTest.java`

**Interfaces:**
- Consumes: `I18nHelper.translate(code, locale, params)`, `ErrorData.of(...)`, `BaseException`.
- Produces: for `BaseException` → `BaseResponse.from(status, reasonPhrase, ErrorData.of(code, message))`; for validation → `BaseResponse.badRequest(ErrorData.of("validation.failed", <resolved>, fieldMap))`.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.core_exception_api;

import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.common_dto.response.ErrorData;
import org.aibles.ecommerce.core_exception_api.configuration.GlobalExceptionHandler;
import org.aibles.ecommerce.core_exception_api.helper.I18nHelper;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;
import org.springframework.web.context.request.WebRequest;

import java.util.Locale;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class GlobalExceptionHandlerTest {

  @Test
  void baseException_puts_code_and_message_inside_errorData() {
    I18nHelper i18n = mock(I18nHelper.class);
    when(i18n.translate(eq("order.not_found"), any(), any())).thenReturn("Order A123 was not found.");
    WebRequest req = mock(WebRequest.class);
    when(req.getLocale()).thenReturn(Locale.ENGLISH);

    GlobalExceptionHandler handler = new GlobalExceptionHandler(i18n);
    NotFoundException ex = new NotFoundException("order.not_found", Map.of("id", "A123"));

    ResponseEntity<BaseResponse> resp = handler.handleBaseException(ex, req);

    assertThat(resp.getStatusCode().value()).isEqualTo(404);
    ErrorData data = (ErrorData) resp.getBody().getData();
    assertThat(data.getCode()).isEqualTo("order.not_found");
    assertThat(data.getMessage()).isEqualTo("Order A123 was not found.");
    assertThat(data.getErrors()).isNull();
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core/core-exception-api && mvn -q test -Dtest=GlobalExceptionHandlerTest`
Expected: FAIL — body's `data` is a `Map`, cast to `ErrorData` throws `ClassCastException`.

- [ ] **Step 3: Write minimal implementation**

Replace the two handler bodies (keep the class/imports; add `import org.aibles.ecommerce.common_dto.response.ErrorData;`):

```java
  @ExceptionHandler(BaseException.class)
  public ResponseEntity<BaseResponse> handleBaseException(BaseException ex, WebRequest webRequest) {
    log.info("(handleBaseException) code={} locale={}", ex.getCode(), webRequest.getLocale());
    String message = i18nHelper.translate(ex.getCode(), webRequest.getLocale(), ex.getParams());
    HttpStatus status = HttpStatus.valueOf(ex.getStatus());
    BaseResponse baseResponse =
        BaseResponse.from(ex.getStatus(), status.getReasonPhrase(), ErrorData.of(ex.getCode(), message));
    return new ResponseEntity<>(baseResponse, status);
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ResponseEntity<BaseResponse> handleValidationExceptions(MethodArgumentNotValidException exception,
                                                                 WebRequest webRequest) {
    Map<String, String> errors = new HashMap<>();
    exception.getBindingResult().getAllErrors().forEach(error -> {
      String fieldName = ((FieldError) error).getField();
      errors.put(fieldName, error.getDefaultMessage());
    });
    String message = i18nHelper.translate("validation.failed", webRequest.getLocale(), null);
    BaseResponse errorResponse =
        BaseResponse.badRequest(ErrorData.of("validation.failed", message, errors));
    return new ResponseEntity<>(errorResponse, HttpStatus.BAD_REQUEST);
  }
```

Apply the same `ErrorData.of("validation.failed", message, errors)` change to `handleConstraintViolationException` (add a `WebRequest webRequest` parameter there too).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core/core-exception-api && mvn -q test -Dtest=GlobalExceptionHandlerTest,BaseBundleTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/core-exception-api/src/main/java/org/aibles/ecommerce/core_exception_api/configuration/GlobalExceptionHandler.java \
        core/core-exception-api/src/test/java/org/aibles/ecommerce/core_exception_api/GlobalExceptionHandlerTest.java
git commit -m "feat(core-exception-api): return code+message+errors inside typed ErrorData

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Reference migration — `product-service` end-to-end

Proves the whole chain (wire advice → coded throws → bundle → gate → frontend shows real text) on the highest-priority unguarded service. This is the worked example the Phase-1 loop imitates.

**Files:**
- Modify: `product-service/pom.xml` — add the `core-exception-api` dependency (copy the `<dependency>` block from `order-service/pom.xml`).
- Modify: `product-service/src/main/java/.../<App>.java` or its config — add `@EnableCoreExceptionApi` (grep `order-service` for how it's imported).
- Create: `product-service/src/main/resources/messages/product.properties`
- Modify: `product-service/src/main/resources/application.yml` — set `application.i18n.resources`.
- Modify: the product throw-sites (grep `throw new .*Exception` under `product-service/src/main`).
- Test: `product-service/src/test/java/.../ProductErrorCatalogTest.java` (bundle resolves the codes).

**Interfaces:**
- Consumes: `NotFoundException(String code, Map<String,String> params)` from Task 2, base bundle from Task 3.
- Produces: dotted codes `product.not_found`, `product.out_of_stock` (extend as the throw-sites require), each defined in `product.properties`.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.product_service;

import org.junit.jupiter.api.Test;
import org.springframework.context.support.ReloadableResourceBundleMessageSource;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProductErrorCatalogTest {
  @Test
  void product_bundle_resolves_its_codes() {
    var ms = new ReloadableResourceBundleMessageSource();
    ms.setBasenames("classpath:messages", "classpath:messages/product");
    ms.setDefaultEncoding("UTF-8");
    assertThat(ms.getMessage("product.not_found", null, Locale.ENGLISH)).contains("Product");
  }
}
```

(Adjust package to product-service's actual base package — grep an existing test.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd product-service && mvn -q test -Dtest=ProductErrorCatalogTest`
Expected: FAIL — `messages/product.properties` missing.

- [ ] **Step 3: Write minimal implementation**

`product-service/src/main/resources/messages/product.properties`:

```properties
product.not_found=Product %id% was not found.
product.out_of_stock=Product %id% is out of stock.
```

`product-service/src/main/resources/application.yml` — add (merge into existing config):

```yaml
application:
  i18n:
    resources:
      - classpath:messages
      - classpath:messages/product
```

Add the `core-exception-api` dependency + `@EnableCoreExceptionApi` (mirror `order-service`). Replace each product throw-site, e.g.:

```java
// BEFORE: throw new NotFoundException();
throw new NotFoundException("product.not_found", Map.of("id", productId));
```

- [ ] **Step 4: Run test + build to verify**

Run: `make build && cd product-service && mvn -q test -Dtest=ProductErrorCatalogTest`
Expected: PASS. (`make build` reinstalls the changed `core/*` modules first.)

- [ ] **Step 5: Commit**

```bash
git add product-service/
git commit -m "feat(product-service): adopt core-exception-api + coded error catalog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: `check-error-catalog.sh` gate

**Files:**
- Create: `scripts/check-error-catalog.sh`
- Test: manual (a shell gate; verify it passes on the migrated tree and fails on a planted bad code).

**Interfaces:**
- Produces: exit 0 when every `setCode("…")` literal in service `src/main` is dotted (`^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$`) AND defined in some `*.properties` bundle; exit 1 with a report otherwise.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Fails if any thrown error code is non-dotted or unresolved in the message bundles.
set -euo pipefail
cd "$(dirname "$0")/.."

DOTTED='^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'

# 1. All codes referenced via setCode("…") in service/core main sources (exclude tests).
mapfile -t used < <(grep -rhoE 'setCode\("[^"]+"\)' \
  --include='*.java' \
  $(git ls-files '*/src/main/*.java') 2>/dev/null \
  | sed -E 's/setCode\("([^"]+)"\)/\1/' | sort -u)

# 2. All keys defined across every bundle.
keys="$(git ls-files '*messages*.properties' | xargs -r grep -hoE '^[^#=]+=' | sed 's/=$//' | tr -d ' ' | sort -u)"

fail=0
for code in "${used[@]:-}"; do
  [ -z "$code" ] && continue
  if ! [[ "$code" =~ $DOTTED ]]; then
    echo "NON-DOTTED code: '$code' (must be <domain>.<entity>.<reason>)"; fail=1; continue
  fi
  if ! grep -qxF "$code" <<< "$keys"; then
    echo "UNRESOLVED code: '$code' has no bundle entry"; fail=1
  fi
done

if [ "$fail" -ne 0 ]; then echo "check-error-catalog: FAIL"; exit 1; fi
echo "check-error-catalog: OK"
```

- [ ] **Step 2: Make executable and run against the migrated tree**

Run: `chmod +x scripts/check-error-catalog.sh && ./scripts/check-error-catalog.sh`
Expected: `check-error-catalog: OK`.

- [ ] **Step 3: Verify it fails on a bad code**

Temporarily add `throw new NotFoundException("NotDotted");` somewhere under a service `src/main`, then run the gate.
Expected: `NON-DOTTED code: 'NotDotted'` and exit 1. Revert the edit.

- [ ] **Step 4: Commit**

```bash
git add scripts/check-error-catalog.sh
git commit -m "feat(scripts): add check-error-catalog gate (dotted + resolvable codes)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `next-error-target.mjs` backend detector

**Files:**
- Create: `scripts/next-error-target.mjs`
- Test: `scripts/next-error-target.test.mjs` (pure-function unit test of the picker)

**Interfaces:**
- Produces: `pickNextService(services, doneSet, priority)` → next service name or `null`. CLI prints the next service lacking a `messages/<service>.properties` bundle (priority `product-service`, `orchestrator-service` first), or `DONE`.

- [ ] **Step 1: Write the failing test**

```javascript
import assert from 'node:assert';
import { pickNextService } from './next-error-target.mjs';

const PRIORITY = ['product-service', 'orchestrator-service'];
// product done, orchestrator not → orchestrator is next (priority beats alpha).
assert.equal(
  pickNextService(['order-service', 'product-service', 'orchestrator-service'],
    new Set(['product-service']), PRIORITY),
  'orchestrator-service',
);
// all done → null.
assert.equal(pickNextService(['a-service'], new Set(['a-service']), PRIORITY), null);
console.log('ok');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node scripts/next-error-target.test.mjs`
Expected: FAIL — cannot import `pickNextService`.

- [ ] **Step 3: Write minimal implementation**

```javascript
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PRIORITY = ['product-service', 'orchestrator-service'];

export function pickNextService(services, doneSet, priority) {
  const rank = (s) => {
    const i = priority.indexOf(s);
    return i === -1 ? priority.length : i;
  };
  const pending = services
    .filter((s) => !doneSet.has(s))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return pending[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  // Services come from scripts/services.list (col 1), excluding infra-only entries.
  const list = readFileSync(join(root, 'scripts/services.list'), 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'))
    .map((l) => l.split(/\s+/)[0])
    .filter((name) => name.endsWith('-service') || name === 'gateway');
  const done = new Set(
    list.filter((name) => existsSync(join(root, name, `src/main/resources/messages/${name.replace(/-service$/, '')}.properties`))),
  );
  const next = pickNextService(list, done, PRIORITY);
  console.log(next ?? 'DONE');
}
```

(Verify the `services.list` column layout matches — root `CLAUDE.md` shows `name port - tier`. Adjust the bundle-name derivation if a service's domain prefix differs from `<name>-service`.)

- [ ] **Step 4: Run test + CLI**

Run: `node scripts/next-error-target.test.mjs && node scripts/next-error-target.mjs`
Expected: test prints `ok`; CLI prints the next unmigrated service (e.g. `orchestrator-service`, since product was migrated in Task 5).

- [ ] **Step 5: Commit**

```bash
git add scripts/next-error-target.mjs scripts/next-error-target.test.mjs
git commit -m "feat(scripts): backend error-catalog detector (next service or DONE)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Frontend contract fix — read `data.{code,message,errors}`

**Files:**
- Modify: `frontend/src/api/error.ts` — add `errors` to `ApiError`.
- Modify: `frontend/src/api/client.ts` — read the nested error object.
- Test: `frontend/tests/unit/api/error-extraction.spec.ts`

**Interfaces:**
- Consumes: backend contract `{status, code, data:{code, message, errors?}}`.
- Produces: `ApiError` gains `public readonly errors?: Record<string,string>`; `client.ts` populates `code`/`message`/`errors` from `body.data`.

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { extractError } from '@/api/client';

describe('extractError', () => {
  it('reads code, message and field errors from data', () => {
    const body = { status: 400, code: 'Bad Request',
      data: { code: 'validation.failed', message: 'One or more fields are invalid.',
              errors: { email: 'must be valid' } } };
    const e = extractError(400, body, 'Bad Request');
    expect(e.code).toBe('validation.failed');
    expect(e.message).toBe('One or more fields are invalid.');
    expect(e.errors).toEqual({ email: 'must be valid' });
  });

  it('falls back to statusText when data is absent', () => {
    const e = extractError(500, null, 'Server Error');
    expect(e.message).toBe('Server Error');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test -- error-extraction`
Expected: FAIL — `extractError` is not exported.

- [ ] **Step 3: Write minimal implementation**

In `error.ts`, extend `ApiError`:

```typescript
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly errors?: Record<string, string>,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}
```

In `client.ts`, replace the `BaseResponse<T>` interface and add a shared extractor, then use it in both `errorMiddleware` and `apiFetchUnsafe`:

```typescript
interface ErrorData {
  code?: string;
  message?: string;
  errors?: Record<string, string>;
}
interface BaseResponse<T> {
  status: number;
  code: string;
  data: T;
}

export function extractError(status: number, body: BaseResponse<unknown> | null, statusText: string): ApiError {
  const d = (body?.data ?? null) as ErrorData | null;
  return new ApiError(status, d?.code ?? '', d?.message ?? statusText, d?.errors);
}
```

Then in `errorMiddleware.onResponse`, replace the manual `code`/`message` block with:

```typescript
    if (!response.ok) {
      let body: BaseResponse<unknown> | null = null;
      try { body = (await response.clone().json()) as BaseResponse<unknown>; } catch { /* non-JSON */ }
      if (response.status === 401) redirectToLogin();
      throw extractError(response.status, body, response.statusText);
    }
```

And in `apiFetchUnsafe`, replace the throw at the `!response.ok` branch with `throw extractError(response.status, body, response.statusText);`.

- [ ] **Step 4: Run test + typecheck**

Run: `cd frontend && pnpm test -- error-extraction && pnpm typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/client.ts frontend/src/api/error.ts frontend/tests/unit/api/error-extraction.spec.ts
git commit -m "fix(frontend): read error code/message/field-errors from data envelope

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: `useApiError` composable

The display helper the Phase-2 loop uses so pages don't re-derive toast-vs-field logic.

**Files:**
- Create: `frontend/src/composables/useApiError.ts`
- Test: `frontend/tests/unit/composables/useApiError.spec.ts`

**Interfaces:**
- Consumes: `ApiError` (with `errors`), the toast store (`useToast`).
- Produces: `useApiError()` → `{ toApiError(e: unknown): ApiError, fieldErrors(e: unknown): Record<string,string>, notify(e: unknown, fallback?: string): void }`. `notify` shows `err.message` (real backend text) as a toast; `fieldErrors` returns `err.errors ?? {}` for `setErrors`.

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect, vi } from 'vitest';
import { ApiError } from '@/api/error';

vi.mock('@/composables/useToast', () => ({ useToast: () => ({ error: vi.fn() }) }));
import { useApiError } from '@/composables/useApiError';

describe('useApiError', () => {
  it('extracts field errors from an ApiError', () => {
    const { fieldErrors } = useApiError();
    expect(fieldErrors(new ApiError(400, 'validation.failed', 'bad', { email: 'x' }))).toEqual({ email: 'x' });
  });
  it('returns empty field map for non-ApiError', () => {
    const { fieldErrors } = useApiError();
    expect(fieldErrors(new Error('boom'))).toEqual({});
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && pnpm test -- useApiError`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```typescript
import { ApiError } from '@/api/error';
import { useToast } from '@/composables/useToast';

export function useApiError() {
  const toast = useToast();

  const toApiError = (e: unknown): ApiError | null => (e instanceof ApiError ? e : null);

  const fieldErrors = (e: unknown): Record<string, string> => toApiError(e)?.errors ?? {};

  const notify = (e: unknown, fallback = 'Something went wrong. Please try again.') => {
    const err = toApiError(e);
    toast.error(err?.message || fallback);
  };

  return { toApiError, fieldErrors, notify };
}
```

(Confirm `useToast`'s method name — grep `frontend/src/composables/useToast.ts`; adjust `toast.error(...)` if the signature is `(title, body)`.)

- [ ] **Step 4: Run test + typecheck**

Run: `cd frontend && pnpm test -- useApiError && pnpm typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/composables/useApiError.ts frontend/tests/unit/composables/useApiError.spec.ts
git commit -m "feat(frontend): add useApiError composable for consistent error display

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Align the reactive gateway error JSON

**Files:**
- Modify: `gateway/.../filter/JwtAuthenticationFilter.java`, `gateway/.../filter/AuthorizationFilter.java` (grep for where they write the error body)
- Test: whatever gateway test harness exists (grep `gateway/src/test`); if none, a `WebTestClient` slice test for one unauthenticated route.

**Interfaces:**
- Produces: gateway error body `{status, code:<reasonPhrase>, data:{code, message}}` with dotted codes `auth.token_invalid`, `auth.token_missing`, `auth.forbidden`, `common.internal_error`. Add those keys to the base bundle (Task 3 file) — gateway ships no servlet bundle.

- [ ] **Step 1: Add the gateway codes to the base bundle**

Append to `core/core-exception-api/src/main/resources/messages.properties`:

```properties
auth.token_missing=Authentication is required.
auth.token_invalid=Your session is invalid or has expired. Please sign in again.
auth.forbidden=You do not have permission to access this resource.
```

(The gateway reads this bundle directly — it depends on `common-dto`; if it does not already have `core-exception-api` on the classpath for the bundle resource, inline the same strings in the filter instead. Grep the gateway `pom.xml` first.)

- [ ] **Step 2: Rewrite the error-writing helper in each filter**

Find the current hand-rolled JSON writer (produces `{status, error, message, path, errorCode}`) and replace its body construction so the serialized shape is:

```java
// pseudo-shape written to the DataBuffer:
// { "status": <int>, "code": "<HTTP reason phrase>",
//   "data": { "code": "<dotted>", "message": "<human>" } }
```

Reuse the service's existing `ObjectMapper`; build a nested `Map.of("status", status, "code", reasonPhrase, "data", Map.of("code", dottedCode, "message", humanMessage))`. Replace the generic strings (`"Internal authentication error"`, `"Authorization processing error"`) with the human messages above.

- [ ] **Step 3: Verify**

Run: `cd gateway && mvn -q test` (or the smallest slice test that hits an unauthenticated route). Manually confirm one 401 body matches the shape.
Expected: PASS; body is the nested shape.

- [ ] **Step 4: Commit**

```bash
git add gateway/ core/core-exception-api/src/main/resources/messages.properties
git commit -m "fix(gateway): align error JSON to {status,code,data:{code,message}} contract

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: `error-catalog-step` backend loop skill

**Files:**
- Create: `.claude/skills/error-catalog-step/SKILL.md`

**Interfaces:**
- Consumes: `scripts/next-error-target.mjs` (detector), `scripts/check-error-catalog.sh` (gate).
- Produces: a `/loop /error-catalog-step` runner that migrates ONE service per invocation.

- [ ] **Step 1: Write the skill file**

```markdown
---
name: error-catalog-step
description: >
  Use to run ONE iteration of the backend error-catalog sweep, then self-pace via /loop.
  Picks the next service lacking a messages/<svc>.properties bundle, gives its throw-sites
  stable dotted codes with %param% messages, wires core-exception-api if missing, verifies
  (mvn + check-error-catalog.sh), and commits. Ends at one human-merged PR.
  Trigger phrases: "/error-catalog-step", "/loop /error-catalog-step".
---

# error-catalog-step — one iteration of the backend error-catalog loop

**Announce at start:** "Running one error-catalog-step iteration."

Runs as `/loop /error-catalog-step` (no interval → self-paced). Durable state lives in git and
the message bundles — a killed session resumes from there. The only in-session state is a
transient blocked-service counter (Gate 2). Migrate EXACTLY ONE service per invocation, commit,
then stop or let /loop schedule the next wake-up.

## Four-gate stop contract (check in order, every invocation)
1. **Success stop** — `node scripts/next-error-target.mjs` prints `DONE`. If the branch has
   commits, open the PR (below) and STOP. Else report "every service is coded" and STOP.
2. **Blocked stop** — track a blocked-service counter across this run; if 2 services in a row
   cannot be brought green (build/gate stays red), open the escape-hatch draft PR and STOP.
3. **Hard cap** — if `git rev-list --count main..HEAD` >= 6, open the PR and STOP.
4. **User interrupt** — the last commit is safe; re-running resumes from git state.

## The iteration
1. Ensure on branch `chore/error-catalog-sweep` (create off `main` if missing).
2. **Gate 3 check** — if `git rev-list --count main..HEAD` >= 6, open the Gate 1 PR and STOP.
3. Run `node scripts/next-error-target.mjs`. `DONE` → Gate 1. Else output is `<service-name>`.
4. For that service (mirror the product-service reference in the spec):
   - Add the `core-exception-api` dependency + `@EnableCoreExceptionApi` if absent.
   - Grep `throw new .*Exception` under `src/main`. Give each a `<domain>.<entity>.<reason>`
     code and params (the real IDs) via the `Xxx(code, params)` constructors. Fix any code that
     is an English sentence or FQN.
   - Create `src/main/resources/messages/<domain>.properties` with `%param%` messages.
   - Add both basenames to `application.i18n.resources` in `application.yml`.
5. **Verify (gate):** `make build` then `mvn -pl <service> -am -q verify` AND
   `./scripts/check-error-catalog.sh`. Green → `git add -A && git commit` (Co-Authored-By
   trailer). Red and unfixable → `git checkout -- .` and count a blocked service (Gate 2).
6. Report and let /loop schedule the next wake-up.

## Gate 1 PR
git push -u origin HEAD; gh pr create --base main --title "chore(backend): error-catalog sweep"
--body "Coded error catalog for: <list>. Each throw-site has a dotted code + %param% message.
check-error-catalog green."

## Gate 2 escape hatch
git commit --allow-empty -m "wip: error-catalog-step blocked — needs human"; push;
gh pr create --draft --base main --title "wip: error-catalog-step needs human"
--body "<blocked services + the specific blocker>"; gh pr edit --add-label needs-human

## Hard rules
- ONE service per invocation. Never batch.
- Never change `BaseResponse`. Codes are dotted, defined in a bundle before commit.
- Never auto-merge. Output is always a PR a human merges.
```

- [ ] **Step 2: Sanity-check the detector wiring**

Run: `node scripts/next-error-target.mjs`
Expected: prints a real service name or `DONE` (no crash).

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/error-catalog-step/SKILL.md
git commit -m "feat(skill): add error-catalog-step backend loop

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 12: `error-display-step` frontend loop skill + detector

**Files:**
- Create: `frontend/scripts/next-error-display-target.mjs` (+ `.test.mjs`)
- Create: `.claude/skills/error-display-step/SKILL.md`

**Interfaces:**
- Produces: detector prints the next `pages/**/*.vue` containing an error-discarding `catch {` / `catch (` block whose body ignores the error, or a hardcoded error string, else `DONE`. Loop rewrites ONE page per invocation using `useApiError`.

- [ ] **Step 1: Write the detector test + script**

`frontend/scripts/next-error-display-target.test.mjs`:

```javascript
import assert from 'node:assert';
import { pickNextPage } from './next-error-display-target.mjs';
// page A has a bare catch, B is clean → A is next.
assert.equal(pickNextPage([{ f: 'CartPage.vue', bad: true }, { f: 'HomePage.vue', bad: false }]), 'CartPage.vue');
assert.equal(pickNextPage([{ f: 'HomePage.vue', bad: false }]), null);
console.log('ok');
```

`frontend/scripts/next-error-display-target.mjs`:

```javascript
import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

// A page is "bad" if it has an empty-binding catch (`catch {`), which always discards
// the caught error. That is the marker; the loop's human review catches subtler cases.
export function hasDiscardedCatch(src) {
  return /catch\s*\{/.test(src);
}

export function pickNextPage(pages) {
  const bad = pages.filter((p) => p.bad).map((p) => p.f).sort();
  return bad[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const pages = walk(`${srcRoot}/pages`, ['.vue']).map((p) => ({
    f: relative(`${srcRoot}/pages`, p),
    bad: /catch\s*\{/.test(readFileSync(p, 'utf8')),
  }));
  console.log(pickNextPage(pages) ?? 'DONE');
}
```

(The `catch {` regex is the marker: an empty-binding catch always discards the error. Keep it simple — the loop's human review catches the rest.)

- [ ] **Step 2: Run detector test**

Run: `cd frontend && node scripts/next-error-display-target.test.mjs && node scripts/next-error-display-target.mjs`
Expected: test prints `ok`; CLI prints a page (e.g. `CheckoutPage.vue`) or `DONE`.

- [ ] **Step 3: Write the skill file**

```markdown
---
name: error-display-step
description: >
  Use to run ONE iteration of the frontend error-display sweep, then self-pace via /loop.
  Picks the next page that discards caught errors, rewrites it to surface real backend
  messages + field errors via useApiError, verifies (pnpm test + typecheck), and commits.
  Ends at one human-merged PR. Trigger: "/error-display-step", "/loop /error-display-step".
---

# error-display-step — one iteration of the frontend error-display loop

**Announce at start:** "Running one error-display-step iteration."

Runs as `/loop /error-display-step` after the backend catalog PR merges. ONE page per
invocation. Durable state is git + the page tree; only in-session state is a blocked-page
counter (Gate 2).

## Four-gate stop contract
1. **Success** — `node scripts/next-error-display-target.mjs` prints `DONE` → open PR, STOP.
2. **Blocked** — 2 pages in a row un-fixable (test/typecheck stays red) → draft needs-human PR.
3. **Hard cap** — `git rev-list --count main..HEAD` >= 8 → open PR, STOP.
4. **User interrupt** — last commit safe; rerun resumes.

## The iteration
1. `cd frontend`. Ensure on branch `chore/error-display-sweep` (create off `main` if missing).
2. Gate 3 check (>= 8 commits → PR + STOP).
3. `node scripts/next-error-display-target.mjs`. `DONE` → Gate 1. Else output is `<page>.vue`.
4. Rewrite that page's error handling:
   - Replace bare `catch {}` / error-discarding catches with `catch (e) { ... }`.
   - Use `useApiError()`: `notify(e)` for toasts (surfaces the real backend `message`),
     `fieldErrors(e)` → vee-validate `setErrors(...)` for forms.
   - Switch on `e.code` only where the page needs custom UI (e.g. `INVALID_CREDENTIALS`).
   - Replace SHOUTY hardcoded strings (`'ORDER NOT CREATED — TRY AGAIN'`) with `notify(e, '<fallback>')`.
5. **Verify:** `pnpm test && pnpm typecheck`. Green → commit (Co-Authored-By). Red → `git checkout -- .` (Gate 2).
6. Report; let /loop schedule the next wake-up.

## Gate 1 / Gate 2 PRs — same pattern as a11y-step (base main, needs-human label on the draft).

## Hard rules
- ONE page per invocation. Never batch. Never touch a `B*` primitive, `tokens.css`, or CI.
- Never auto-merge.
```

- [ ] **Step 4: Commit**

```bash
git add frontend/scripts/next-error-display-target.mjs frontend/scripts/next-error-display-target.test.mjs \
        .claude/skills/error-display-step/SKILL.md
git commit -m "feat(skill): add error-display-step frontend loop + detector

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 13: CI wiring + docs

**Files:**
- Modify: the backend CI workflow under `.github/workflows/` (grep for the Maven job) — add a `check-error-catalog` step.
- Modify: the frontend CI workflow — add a bare-catch grep gate.
- Modify: `core/core-exception-api/CLAUDE.md` (remove the stale `success=false` wire-format claim), `frontend/docs/enhance-loops.md` (document the two new loops).

**Interfaces:**
- Produces: CI fails on an unresolved/non-dotted backend code or a new bare `catch {` in `frontend/src/pages`.

- [ ] **Step 1: Add the backend gate step**

In the Maven CI job, after build, add:

```yaml
      - name: Error-catalog gate
        run: ./scripts/check-error-catalog.sh
```

- [ ] **Step 2: Add the frontend bare-catch gate**

In the frontend CI job (after `pnpm test`), add:

```yaml
      - name: No error-discarding catch in pages
        run: |
          if grep -rnE 'catch\s*\{' frontend/src/pages; then
            echo "Bare catch {} discards the error — use useApiError(); see error-display-step."; exit 1
          fi
```

- [ ] **Step 3: Fix the stale docs**

In `core/core-exception-api/CLAUDE.md`, replace the "## Wire format" paragraph (which claims `success=false`, `code`, `message` at top level) with the real contract: `BaseResponse{status, code, data}` where `data` is an `ErrorData{code, message, errors?}`; snake_case throughout. In `frontend/docs/enhance-loops.md`, add a section for `/loop /error-catalog-step` and `/loop /error-display-step` mirroring the existing loop entries.

- [ ] **Step 4: Verify gates locally**

Run: `./scripts/check-error-catalog.sh && ! grep -rqE 'catch\s*\{' frontend/src/pages && echo "gates OK"`
Expected: `gates OK` (after the display loop runs; before it, this documents that unmigrated pages still trip the grep — so wire the frontend gate as `continue-on-error` or land it in the display-loop PR, not the foundation PR).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ core/core-exception-api/CLAUDE.md frontend/docs/enhance-loops.md
git commit -m "ci+docs: wire error-catalog gate, document the two error loops

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** A1 `ErrorData` → Task 1/4; A2 MessageSource revival → Task 3 (base bundle; the `MessageSource` bean already exists in `CoreApiExceptionConfiguration` and reads `application.i18n.resources`, so no bean change — only bundles + yml); A3 gateway → Task 10; A4 gate + detector → Tasks 6/7; A5 frontend contract → Task 8; Phase-1 loop → Task 11; Phase-2 loop → Task 12; stop contract → embedded in Tasks 11/12; reference migration → Task 5; docs/CI → Task 13. `useApiError` (Phase-2 dependency) → Task 9.
- **`success` field:** the spec noted `core-exception-api/CLAUDE.md` is stale (claims a `success` field that does not exist) — fixed in Task 13.
- **Placeholder scan:** the one soft spot is the frontend bare-catch gate ordering (Task 13 Step 4) — called out explicitly: land the grep gate in the display-loop PR, not the foundation PR, since unmigrated pages still contain bare catches until the Phase-2 loop finishes.
- **Type consistency:** `ErrorData.of` / `ErrorData{code,message,errors}` used identically in Tasks 1, 4; `extractError(status, body, statusText)` defined in Task 8 and consumed only there; `useApiError().fieldErrors/notify` defined in Task 9 and consumed by Task 12's skill.
