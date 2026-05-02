# Testing conventions

No coverage % gate. **Test what matters**: every Zod schema (happy + sad), every page (happy render), every optimistic mutation (rollback path), every error class (mapping).

## Layers

| Layer     | Tool                                | Lives in                           | What it tests                                                                                      |
| --------- | ----------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------- |
| Unit      | Vitest                              | `tests/unit/`                      | Pure functions: Zod schemas, format helpers, `apiError` classifier, store reducers                 |
| Component | @testing-library/vue + Vitest       | `tests/unit/` (colocated by topic) | Primitives + domain components — render, props, events, a11y semantics                             |
| Page      | @testing-library/vue + MSW + Vitest | `tests/unit/pages/`                | Page renders + key flows (login error path, optimistic cancel rollback, debounced search)          |
| E2E       | Playwright                          | `tests/e2e/`                       | 2 golden paths: public browse → PDP; register → cart → checkout (PayPal stubbed) → orders → cancel |

## What goes where

- **Don't** unit-test things that have no logic (a tagless presentational primitive's "renders slot content" test is noise — instead test the variant prop changes the class).
- **Do** unit-test every Zod schema with valid + invalid inputs.
- **Do** test every optimistic mutation's rollback (mock 409, assert UI flips back).
- **Do** test the API error classifier's full taxonomy mapping (one test per class).
- E2E: only the two named golden paths. More e2e = slow CI = flaky.

## File naming

```
tests/unit/sanity.spec.ts
tests/unit/lib/zod-schemas.spec.ts
tests/unit/api/error-classifier.spec.ts
tests/unit/components/primitives/BButton.spec.ts
tests/unit/pages/LoginPage.spec.ts
tests/e2e/browse.spec.ts
tests/e2e/buy.spec.ts
```

`*.spec.ts` for tests. Mirror `src/` paths under `tests/unit/`.

## MSW — request mocking

MSW handlers live in `tests/handlers/` (one file per resource, mirroring `src/api/queries/`). Imported by both unit/page tests and CI-mode Playwright.

```ts
// tests/handlers/products.ts (lands in Phase 4)
import { http, HttpResponse } from 'msw';
import { productListFixture } from '../fixtures/products';

export const productsHandlers = [
  http.get('/api/bff-service/v1/products', () =>
    HttpResponse.json({ status: 'OK', code: '200', message: '', data: productListFixture }),
  ),
];
```

## Fixtures

Fixtures in `tests/fixtures/` are **parsed through Zod schemas at construction**. Drift between FE types and backend shapes fails the fixture parse fast.

```ts
// tests/fixtures/products.ts (lands in Phase 4)
import { productSchema } from '@/lib/zod-schemas';
export const productListFixture = [
  productSchema.parse({ id: 'abc', name: 'Issue Nº01 Tote', price: 39 /* … */ }),
];
```

If you change the schema, fixtures break — that's the point.

## Component test shape

```ts
import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BButton from '@/components/primitives/BButton.vue';

describe('BButton', () => {
  it('renders default slot', () => {
    render(BButton, { slots: { default: 'BUY NOW' } });
    expect(screen.getByRole('button')).toHaveTextContent('BUY NOW');
  });

  it('applies variant class', () => {
    render(BButton, { props: { variant: 'spot' }, slots: { default: 'X' } });
    expect(screen.getByRole('button').className).toContain('b-button--spot');
  });
});
```

## Page test shape

```ts
import { describe, expect, it } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { setupServer } from 'msw/node';
import { authHandlers } from '../../handlers/auth';
// … MSW setup, router stub, query client

describe('LoginPage', () => {
  it('shows inline error on invalid credentials', async () => {
    render(LoginPage, {
      /* … */
    });
    await user.type(screen.getByLabelText(/email/i), 'no@one.com');
    await user.type(screen.getByLabelText(/password/i), 'wrong');
    await user.click(screen.getByRole('button', { name: /log in/i }));
    await waitFor(() => {
      expect(screen.getByText(/wrong email or password/i)).toBeInTheDocument();
    });
  });
});
```

## E2E run modes

- **Local**: `pnpm test:e2e` — hits real backend (`make up` required).
- **CI**: Playwright with MSW served in-page, no backend dependency. Runs on every PR.

## What's deferred

- Storybook + visual regression
- axe-core a11y suite (manual checklist in `09-a11y-checklist.md` for now)
- Coverage % gates
- Lighthouse budgets in CI

## Hard rules

- **TDD for non-trivial logic.** Schemas, classifiers, optimistic mutations get tests first.
- **Don't mock what you can fixture.** A real Zod-parsed fixture beats a `jest.fn()`.
- **Avoid testing implementation.** Test what the user sees: rendered text, role, behavior.
- **No snapshot tests.** They rot fast and don't enforce intent.
