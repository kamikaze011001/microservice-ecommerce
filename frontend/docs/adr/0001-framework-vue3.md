# 0001 — Framework: Vue 3 + Vite + TypeScript

**Status:** Accepted
**Date:** 2026-05-01

## Context

We need a frontend framework for a single-page storefront against an existing microservice backend. Constraints: learning project, single owner, type-safety required, fast dev loop, plays well with Tailwind.

## Decision

**Vue 3** (Composition API + `<script setup>`) with **Vite** and **TypeScript** strict mode.

## Alternatives considered

| Option         | Why not                                                                                                                                                                     |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React + Vite   | Bigger ecosystem, but ergonomics for this scope are heavier (more boilerplate, more decisions per component, JSX vs template religious wars). The owner has Vue background. |
| SvelteKit      | Smaller bundle, lovely DX, but library breadth (forms, query, headless UI) is thinner than Vue's, and SSR is a Phase-N concern out of scope for v1.                         |
| Next.js / Nuxt | SSR is a non-goal (see design spec). Nuxt would be a strong v1.5 path; v1 stays SPA.                                                                                        |

## Consequences

- Native Vite integration. Fastest dev loop available.
- Strong-typed templates via `vue-tsc`.
- Single-file components keep CSS, template, and logic colocated — fits Issue Nº01's tight per-component aesthetics.
- Smaller library ecosystem than React for niche needs (e.g. Reka UI for headless a11y is younger than Radix).
- TanStack and Zod work first-class in Vue 3.
