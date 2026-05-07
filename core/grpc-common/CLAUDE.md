# grpc-common

Protocol Buffer definitions and generated stubs for internal service-to-service gRPC.

## Layout
- `src/main/proto/` — `.proto` files (the only source of truth)
- Generated Java classes are produced at build time by the `protoc` Maven plugin and shipped as part of the artifact

## Current contracts
gRPC is used today between **order-service (client)** and **inventory-service (server)** — see `inventory-service/grpc/server/`.

## Editing protos
- Add fields, don't renumber. Removing or renumbering a field is a wire-breaking change.
- After editing: `mvn clean install` from this module before rebuilding consuming services.
- `make build` handles install order; raw `mvn` from a service directory will pick up the stale local artifact if you forget.

## Why gRPC instead of REST here
Internal latency-critical paths only (stock check during order validation). External traffic stays REST through the gateway.
