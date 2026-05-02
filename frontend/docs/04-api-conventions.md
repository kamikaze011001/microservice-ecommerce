# API conventions

The API boundary is `src/api/queries/`. Components, pages, and composables consume hooks from here, never the raw client.

## Generation pipeline (wired in Phase 3)

```
Backend gateway              FE codegen         FE runtime
/v3/api-docs (OpenAPI)  ───→  schema.d.ts  ───→ openapi-fetch <client>
                              (types only)       + auth interceptor
                                                 + error classifier
```

- `pnpm api:gen` → fetches `http://localhost:8080/v3/api-docs` and writes `src/api/schema.d.ts` via `openapi-typescript`.
- `src/api/client.ts` exports a singleton `client` from `openapi-fetch<paths>()`.
- The interceptor attaches `Authorization: Bearer <token>` and classifies errors.

Components never import `client` directly.

## Query / mutation hooks

### Naming

- Queries: `useXQuery`, `useXListQuery`, `useXByIdQuery`.
- Mutations: `useCreateXMutation`, `useUpdateXMutation`, `useDeleteXMutation`, `useXActionMutation` (e.g. `useCancelOrderMutation`).
- One file per resource: `src/api/queries/products.ts`, `cart.ts`, `orders.ts`, `auth.ts`, `payment.ts`.

### Cache key hierarchy

Hierarchical keys allow surgical invalidation.

| Key                         | Meaning                                       |
| --------------------------- | --------------------------------------------- |
| `["currentUser"]`           | Logged-in user                                |
| `["products"]`              | Product list (with filters as second segment) |
| `["products", { page, q }]` | List with params                              |
| `["products", id]`          | Single product detail                         |
| `["cart"]`                  | Current user's cart                           |
| `["orders"]`                | Order list                                    |
| `["orders", id]`            | Single order                                  |
| `["payments", paymentId]`   | Single payment                                |

`queryClient.invalidateQueries({ queryKey: ["products"] })` invalidates list AND detail.
`queryClient.invalidateQueries({ queryKey: ["products", id], exact: true })` hits one entry.

## Invalidation rules

| Mutation                   | Invalidates                         |
| -------------------------- | ----------------------------------- |
| Login / Register           | `["currentUser"]`                   |
| Add / Update / Remove cart | `["cart"]`                          |
| Create order               | `["cart"]`, `["orders"]`            |
| Cancel order               | `["orders"]`, `["orders", orderId]` |
| Logout                     | `queryClient.clear()`               |

Document each new mutation here when added.

## Error taxonomy

The interceptor classifies every non-2xx response into one of six classes. UX defaults are codified.

| Class           | Status          | Default UX                                                                                                                       |
| --------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `auth-required` | 401             | Clear auth store; redirect to `/login?next=<currentPath>`                                                                        |
| `forbidden`     | 403             | Toast "Not allowed"; stay on page                                                                                                |
| `not-found`     | 404             | Route-level → 404 page; component-level → empty state                                                                            |
| `validation`    | 400 / 409 / 422 | **NO toast.** Surface inline (form field or page banner). 409 maps via `code` for tailored copy (e.g. `ORDER_ALREADY_CANCELED`). |
| `server`        | 500-599         | Toast "Server error — try again". Queries auto-retry 3× exp-backoff. Mutations don't auto-retry.                                 |
| `network`       | fetch threw     | Toast "Connection lost"; mutations show inline retry.                                                                            |

Backend envelope: `BaseResponse { status, code, message, data }`. The interceptor unwraps `data` on 2xx; on error, throws a typed `ApiError { status, code, message }`.

## Retry policy

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error) => {
        if ((error as ApiError).status >= 500) return failureCount < 3;
        return false;
      },
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 8000),
      staleTime: 30_000,
    },
    mutations: { retry: false },
  },
});
```

Mutations never auto-retry — that's a bad default for state-changing calls.

## Optimistic mutation pattern

Used for: cancel order, qty stepper, remove cart item. Pattern:

```ts
useMutation({
  mutationFn: cancelOrder,
  onMutate: async (orderId) => {
    await queryClient.cancelQueries({ queryKey: ['orders'] });
    const prev = queryClient.getQueryData(['orders']);
    queryClient.setQueryData(['orders'], (old) =>
      old.map((o) => (o.id === orderId ? { ...o, status: 'CANCELED' } : o)),
    );
    return { prev };
  },
  onError: (err, _id, ctx) => {
    queryClient.setQueryData(['orders'], ctx.prev);
    toast.error(
      err.code === 'ORDER_ALREADY_CANCELED' ? 'Already canceled — refreshed.' : 'Cancel failed',
    );
  },
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['orders'] }),
});
```

`onError` rolls back. `onSettled` always reconciles with server truth. The user sees instant feedback; conflicts auto-correct.

## Hard rules

- **Never** call `client.GET` / `client.POST` from a component, page, or store. Always go through `src/api/queries/`.
- **Never** cache server data in Pinia.
- **Never** swallow an `ApiError` — let it propagate and let the taxonomy decide UX.
- New endpoint → new test in `tests/unit/api/` (mocked via MSW) covering happy + one error class.
