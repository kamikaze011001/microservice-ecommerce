# core-exception-api

Centralized exception handling. Provides `@ControllerAdvice` + helpers so every service returns errors in the same `BaseResponse` shape.

## Layout
- `configuration/` — `@ControllerAdvice` exception handlers
- `constant/` — error code enums / message keys
- `helper/` — utilities for building error responses

## Convention
Don't write your own `@ExceptionHandler` in a service for things this module already handles (validation, auth, generic 500). Add new error types here, not in the service. Error codes are stable contracts — bumping them is a breaking change for the SPA.

## Wire format
Errors are `BaseResponse` with `success=false`, `code`, `message`. Snake_case throughout (`SnakeCaseStrategy` from `common-dto`).
