# Error-handling overhaul — end-to-end message quality

**Date:** 2026-07-10
**Status:** Approved design, ready for planning
**Branch:** `feat/error-handling-overhaul`

## Problem

Error messages surfaced to users are vague and inconsistent. This is not one bug
but a broken chain with a failure at every link, confirmed by an end-to-end audit
of the backend advice, the response envelope, and the frontend display layer.

1. **The message never reaches the UI (the killer).** `GlobalExceptionHandler`
   puts the real text in `data.message`; the frontend (`frontend/src/api/client.ts`)
   reads a top-level `body.message`, which **does not exist** on the backend
   envelope, then silently falls back to `response.statusText` — the raw browser
   phrase ("Bad Request", "Not Found"). Even a perfect backend message would never
   be seen.
2. **The i18n layer is dead.** `GlobalExceptionHandler.translate(code)` resolves
   against a `MessageSource`, but there are **zero `messages*.properties` files** in
   the repo, so it returns the raw code string. Clients literally receive
   `"org.aibles.business.exception.NotFoundException"`.
3. **Coverage gaps & shape drift.** Only 5 of ~10 services use the shared advice
   (`core/core-exception-api`). `product-service` and `orchestrator-service` throw
   **whitelabel 500s** (no handler). The reactive `gateway` hand-rolls a **third**
   error shape. The `code` field means different things per author (dotted key vs.
   English sentence vs. never-resolved FQN).
4. **Frontend swallows errors.** Bare `catch {}` blocks with hardcoded copy
   (`'ORDER NOT CREATED — TRY AGAIN'`, `'UPDATE MISFIRE'`), and the field-level
   validation map the backend *does* send (`{field: message}`) is **never parsed**.

## Goal

A single, consistent, greppable error contract across every service, with real
human-readable (and i18n-ready) messages that actually reach the UI — established
as durable convention (an error-code catalog + a CI gate), not a one-off cleanup.
The rollout is structured as two sequential **enhancement loops** (backend, then
frontend) in the same mold as the repo's existing `a11y-step` / `coverage-step`
loops.

## Key decisions (settled during brainstorming)

1. **Backend owns the copy; revive the i18n catalog.** Exceptions carry a stable
   dotted code; the server resolves it to human text via `MessageSource`. Single
   source of truth, on-call-greppable codes, localization-ready. The frontend
   displays what arrives (and switches on `code` only where it needs custom UI).
2. **Two sequential loops:** a backend catalog loop, then a frontend display loop.
   Each has its own detector, done-marker, and test gate (`mvn` vs `pnpm`).
3. **Per-service message bundles + a shared base in core.** `core-exception-api`
   ships the base bundle (`validation.*`, `auth.*`, `common.*`) and configures the
   `MessageSource`; each service owns `messages/<service>.properties` for its domain
   codes. One loop iteration = "own one service's bundle."
4. **Do NOT change `BaseResponse`.** Per `common-dto/CLAUDE.md` ("touch with care,
   ripples across the whole stack"), keep its `{status, code, data}` shape. The
   domain error detail moves into a typed object *inside* `data`. Adding a new DTO
   class breaks no existing consumer; changing `BaseResponse` fields would.

## The canonical error contract

Top-level `status` / `code` keep describing the HTTP layer exactly as today (`code`
stays the reason phrase produced by the `BaseResponse` factories). Domain detail
lives in a typed `ErrorData` object inside `data`.

```jsonc
// success — completely unchanged from today
{ "status": 200, "code": "OK", "data": { /* payload */ } }

// error — data is a typed ErrorData object
{ "status": 404,
  "code":   "Not Found",                     // HTTP reason phrase, unchanged
  "data": {
     "code":    "order.not_found",           // dotted key — machine-switchable, greppable
     "message": "Order A123 was not found.", // resolved i18n text (the FE reads this)
     "errors":  { "email": "must be valid" } // present ONLY for validation errors, else omitted
  } }
```

- **New class** `ErrorData` in `core/common-dto/.../response/`, annotated
  `@JsonNaming(SnakeCaseStrategy)` like every other DTO (all its keys are single
  words, so the wire form stays clean: `code`, `message`, `errors`).
- **Code convention:** `<domain>.<entity>.<reason>` — e.g. `order.not_found`,
  `inventory.insufficient_stock`, `payment.declined`, `auth.otp_expired`.
- **`code` field discipline:** the `code` inside `ErrorData` is always a dotted
  i18n key — never an English sentence, never a class FQN. The gate enforces this.

## Phase 0 — Foundation (one-time, done directly; NOT a loop)

A loop needs a stable contract and a "done" marker to detect against, so this lands
first as one reviewed PR.

- **A1 — `ErrorData` + `GlobalExceptionHandler`.** Add the `ErrorData` DTO. Rework
  the handler to build it: `data.code` = `ex.getCode()` (dotted), `data.message` =
  resolved text, `data.errors` = the field map for
  `MethodArgumentNotValidException` / `ConstraintViolationException`.
- **A2 — Revive `MessageSource`.** `core-exception-api` autoconfigures a
  `ReloadableResourceBundleMessageSource` loading `classpath:messages.properties`
  (base) **plus** `classpath*:messages/*.properties` (per-service bundles). Ship the
  base bundle with cross-cutting codes (`validation.*`, `auth.*`,
  `common.internal_error`). `translate(code, params)` now resolves real text.
- **A3 — Align the reactive gateway.** It cannot use the servlet
  `@ControllerAdvice`; align its hand-rolled JSON in `JwtAuthenticationFilter` /
  `AuthorizationFilter` to the same `{status, code, data:{code, message}}` shape by
  hand. One-off — not a loop target.
- **A4 — Detector + gate scripts.**
  - `scripts/check-error-catalog.sh` — the CI gate (analogous to
    `pnpm check:consistency`). Fails if any exception's thrown `code` has no entry
    in any `*.properties` bundle on the classpath, or if any `code` is an English
    sentence / FQN rather than a dotted key.
  - `scripts/next-error-target.mjs` — the backend detector. Prints the next service
    still carrying bare/uncoded throws, or the literal `DONE`.
- **A5 — Frontend foundation fix** (`frontend/src/api/client.ts` + `api/error.ts`).
  Read `data.code` / `data.message` / `data.errors` instead of the phantom
  top-level `body.message`; surface `errors` on `ApiError` for field-level display.
  This alone fixes ~80% of the visible vagueness and unlocks the Phase-2 loop.

## Phase 1 — Backend catalog loop (`/loop error-catalog-step`)

One **service** per iteration, autonomous (Claude does the work; user reviews the
PR), in the mold of `a11y-step`.

1. **Detector** (`next-error-target.mjs`) prints the next service with bare/uncoded
   throws, or `DONE`. **Priority order:** the two unguarded services first
   (`product-service`, `orchestrator-service` — highest impact), then the remaining
   services alphabetically as a deterministic tie-break.
2. **Work (one unit):** audit every throw-site and custom exception in that service.
   Assign each a stable `<domain>.<entity>.<reason>` code; replace bare no-arg
   throws with coded ones carrying params (the actual IDs); fix misused codes (e.g.
   `authorization-server`'s `UserNotFoundException` stuffing an English sentence into
   `code` → `auth.user.not_found`). Wire the service to `core-exception-api` if it
   isn't (backfills `product` / `orchestrator`). Add `messages/<service>.properties`
   entries with `{0}`-param messages.
3. **Verify (gate):** `mvn -pl <service> -am verify` **and**
   `scripts/check-error-catalog.sh`. Green → commit; unfixable red → `git checkout
   -- .` + increment the blocked counter.

## Phase 2 — Frontend display loop (`/loop error-display-step`)

Runs after the backend loop reaches `DONE` (and its PR merges). One **page** per
iteration.

1. **Detector:** next page under `frontend/src/pages/` with a bare `catch {}` that
   discards the error, or a hardcoded error string. `DONE` when none remain.
2. **Work (one unit):** replace bare catches with real inspection; surface
   `err.message` (now the real backend text) via the toast store; parse the
   `data.errors` field-map into vee-validate `setErrors`; switch on `err.code` where
   a page needs custom UI (e.g. `INVALID_CREDENTIALS`). A small `useApiError`
   composable absorbs the boilerplate.
3. **Verify (gate):** `pnpm test && pnpm typecheck`, plus a grep gate banning
   error-discarding `catch {}` in `pages/`.

## Stop contract (both loops — mirrors `a11y-step`'s four gates)

Checked in order every invocation:

1. **Success** — detector prints `DONE` → open PR (if commits exist), stop.
2. **Blocked** — an in-session counter of consecutive unfixable targets hits 2 →
   open a draft "needs-human" PR, stop.
3. **Hard cap** — `git rev-list --count main..HEAD` hits the ceiling (backend ≈ 6,
   frontend ≈ 8) → open PR, stop.
4. **Interrupt** — user kills `/loop` anytime; the last commit is safe and a rerun
   resumes. All durable state is derived from git + bundle files; the only ephemeral
   state is the blocked counter, which intentionally resets on restart.

## Resumability

No custom state file. "Done" is recomputed each invocation from committed repo
state: the backend detector diffs throw-site codes against `*.properties` keys; the
frontend detector scans `pages/` for bare catches. Each iteration commits
atomically, so a killed session just re-runs the detector.

## How it's run (operator flow)

1. Foundation (Phase 0) lands as one reviewed PR and merges.
2. `/loop error-catalog-step` until its PR is green and merged.
3. `/loop error-display-step` until its PR is green and merged.

## Out of scope (YAGNI)

- Frontend `vue-i18n` / localized copy — backend owns text; FE echoes it. Adding a
  second catalog is deferred until a real localization requirement exists.
- Changing `BaseResponse`'s field set.
- Retrofitting logging conventions (see root `CLAUDE.md` "Known scars" — not an
  active cleanup target).
- Non-JVM / non-Vue surfaces (mobile, partners) — the dotted `code` is already in
  the contract for them to consume later.

## Deliverables

- `core/common-dto`: new `ErrorData` DTO.
- `core/core-exception-api`: reworked `GlobalExceptionHandler`, autoconfigured
  `MessageSource`, base `messages.properties`.
- Per-service `messages/<service>.properties` bundles (added by the Phase-1 loop).
- `gateway`: aligned error JSON.
- `scripts/check-error-catalog.sh`, `scripts/next-error-target.mjs`.
- `frontend`: `client.ts` / `error.ts` contract fix, `useApiError` composable,
  per-page cleanups (added by the Phase-2 loop), a bare-catch grep gate.
- Two new skills: `.claude/skills/error-catalog-step/`,
  `.claude/skills/error-display-step/`.
- CI wiring for `check-error-catalog.sh` and the frontend bare-catch gate.
