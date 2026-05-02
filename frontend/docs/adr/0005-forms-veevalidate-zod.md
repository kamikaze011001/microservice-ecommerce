# 0005 — Forms: VeeValidate + Zod

**Status:** Accepted
**Date:** 2026-05-01

## Context

We need form validation (login, register, address at checkout). We also need to parse API responses safely (since OpenAPI types are compile-time and don't enforce shape at runtime). Defining schemas twice — once for the form, once for the API parser — is duplication waiting to drift.

## Decision

- **Zod** for schemas, defined once in `src/lib/zod-schemas.ts`.
- **VeeValidate** for form state, error tracking, and submission, with `@vee-validate/zod`'s `toTypedSchema` adapter.
- Same schemas validate forms AND parse API responses (in `src/api/queries/`).

## Alternatives considered

| Option                                        | Why not                                                                                     |
| --------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Vuelidate                                     | Less idiomatic with Composition API; weaker TS inference; harder to share with API parsing. |
| FormKit                                       | All-in-one (renders fields too) — too opinionated for a brutalist visual identity.          |
| React-Hook-Form-style (manual + Zod resolver) | Possible but VeeValidate is the Vue-native answer with the same DX.                         |
| Yup                                           | Less ergonomic in TS than Zod; no `z.infer` equivalent.                                     |

## Consequences

- One source of truth for shape. Backend changes the password rule → one file changes → both forms and API parsers update.
- Server-side validation errors map to inline form errors via VeeValidate's `setErrors({ field })`. (Convention in [`docs/05-form-conventions.md`](../05-form-conventions.md).)
- Zod adds ~9 kB gzip — acceptable for the runtime safety it buys.
