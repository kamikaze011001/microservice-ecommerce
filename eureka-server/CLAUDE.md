# eureka-server

Service registry. Tier 0 — every other service waits for it before registering.

## Port
- App: `8761` (dashboard at `http://localhost:8761`)

## Layout
Effectively empty Spring Boot app — just `@EnableEurekaServer` on the main class. Configuration entirely in `application.yml` / `application.properties`.

## Notes
- No business logic here. If you find yourself editing Java in this module, you're probably in the wrong place.
- Readiness is `readinessState` only (no DB, no Redis).
- Other services discover each other via `lb://<SERVICE-NAME>` — that resolution happens through this registry.
