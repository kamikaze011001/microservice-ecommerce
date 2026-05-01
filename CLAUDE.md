# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview
This is a microservice-based e-commerce platform built with Spring Boot and Java 17. The system uses event-driven architecture with Kafka, master-slave MySQL setup, Redis caching, HashiCorp Vault for secrets management, and gRPC for internal service communication.

## Core Architecture

### Microservices Structure
- **authorization-server**: JWT-based authentication/authorization with OAuth2, user management, role-based access control
- **gateway**: Spring Cloud Gateway for API routing, load balancing, and centralized Swagger documentation
- **eureka-server**: Service discovery and registry
- **product-service**: Product catalog management
- **inventory-service**: Stock management with gRPC endpoints for internal communication
- **order-service**: Order processing, validation, and lifecycle management
- **payment-service**: PayPal integration for payment processing
- **orchestrator-service**: Saga pattern implementation for distributed transactions

### Core Modules (in `/core`)
- **common-dto**: Shared DTOs, events, exceptions, and common request/response models
- **core-order-cache**: Order caching utilities
- **core-routing-db**: Master-slave database routing configuration
- **core-redis**: Redis configuration and utilities
- **core-email**: Email service with Thymeleaf templates
- **core-exception-api**: Global exception handling
- **core-jwt-util**: JWT token utilities
- **core-paypal**: PayPal integration utilities
- **core-s3**: S3-compatible object storage (presigned uploads, MinIO local / AWS S3 prod)
- **grpc-common**: Protocol buffer definitions and gRPC service contracts

### Key Technologies
- **Spring Boot 3.3.6** with Spring Cloud 2023.0.3
- **Java 17** with Maven build system
- **MySQL 8.0.40** in master-slave configuration with GTID replication
- **Redis** for caching and session management
- **Apache Kafka** for event-driven messaging
- **HashiCorp Vault** for secrets management
- **gRPC** for internal service communication
- **Spring Security** with JWT tokens
- **Docker Compose** for infrastructure services

## Common Development Commands

### One-Time Setup (First Run)
```bash
# 1. Configure environment
cp docker/.env.example docker/.env  # fill in passwords + PayPal credentials

# 2. Bootstrap everything (infra → vault → kafka → maven → seed data)
make bootstrap

# 3. Start the services
make up
```

`make bootstrap` is idempotent and seeds MySQL (`ecommerce_dev`) plus
MongoDB collections `api_role` and `product` from `docker/*.{sql,json}`.

### Daily Loop (after Docker restart)
```bash
make up      # starts infra, auto-unseals vault, starts services
make down    # stops everything (preserves data)
make status  # health table for every service
make logs svc=order-service
```

`make up` always re-runs vault unseal — no more "vault sealed" crashes
after Docker restarts.

### Adding a New Service
Add one line to `scripts/services.list`:
```
my-service  1234  -  3
```
The drift guard in `scripts/services/start.sh` will refuse to start until
every `*-service` / `gateway` / `eureka-server` directory is registered.

### Building and Running Services
```bash
# Build all services (run from service directory)
mvn clean compile

# Run individual service
mvn spring-boot:run

# Build with tests
mvn clean test

# Package service
mvn clean package
```

### Infrastructure Management
```bash
make infra-up      # start docker compose stacks
make infra-down    # stop them (keeps volumes)
make infra-status  # ps table per stack
```

### Development Workflow
1. First run: `make bootstrap` (see One-Time Setup above)
2. Daily: `make up` brings everything up in tier order (eureka → auth+gateway → inventory → product/order/payment/orchestrator/bff)
3. Tier order is enforced by `scripts/services/start.sh` reading `scripts/services.list`. inventory-service blocks until both HTTP (6969) and gRPC (9090) are listening before order-service starts.
4. Swagger UI: `http://localhost:8080/swagger-ui.html`

### Service Ports
| Service | Port |
|---|---|
| Gateway (entry point) | 8080 |
| Eureka Dashboard | 8761 |
| Vault UI | 8200 |
| Kafka Connect REST | 8093 |
| MySQL Master | 3306 |
| MySQL Slave1/Slave2 | 3307/3308 |
| MinIO S3 API | 9000 |
| MinIO Console | 9001 |

## Database Architecture

### Master-Slave MySQL Setup
- **Master**: Port 3306 (writes)
- **Slave1**: Port 3307 (reads)
- **Slave2**: Port 3308 (reads)
- Uses GTID replication with automatic failover
- Read queries are routed to slaves, writes to master
- Initialization scripts in `/docker/scripts/`

### Configuration
Services use `@EnableRoutingDatasource` annotation with separate configurations:
- `MasterEntityFactoryConfiguration` for write operations
- `SlaveEntityFactoryConfiguration` for read operations

## Event-Driven Architecture

### Key Events (in common-dto)
- `PaymentSuccessEvent`, `PaymentFailedEvent`, `PaymentCanceledEvent`
- `ProductUpdateEvent`, `ProductQuantityUpdatedEvent`
- `MongoSavedEvent` for MongoDB operations

### Event Flow (Order Processing)
1. Order validation and creation in Order Service
2. Inventory validation via gRPC call to Inventory Service
3. Payment processing with PayPal integration
4. Event publishing for success/failure scenarios
5. Distributed transaction management via orchestrator

## Security & Communication
- **Auth**: JWT (RS256) issued by `authorization-server`; gateway validates and injects `X-User-Id`.
- **External**: REST through gateway. **Internal**: gRPC (see `grpc-common` protos).
- **Async**: Kafka with Avro + Confluent Schema Registry. **Cache**: Redis.

## Code Conventions (non-obvious)

### Gateway routing — no StripPrefix
Each service sets `server.servlet.context-path: /<service-name>` in its `application.yml`.
Gateway routes use `Path=/<service-name>/**` → `lb://<SERVICE-NAME>` (uppercase, no
`StripPrefix` filter). Controllers use bare paths like `/v1/orders` — the context path
handles the prefix. Don't add `StripPrefix` and don't repeat the service name in `@RequestMapping`.

`GET /product-service/v1/products/**` and `GET /bff-service/v1/products/**` are
`PERMIT_ALL` (storefront browse + detail work without login). All other routes
require authentication; admin routes require the `ADMIN` role. Auth rules live in
`docker/api_role.json` and are loaded into MongoDB by `make seed-data`.

### Gateway CORS
The gateway publishes a single `CorsConfigurationSource` covering all routes.
Allowed origins, methods, headers, and credentials live under
`application.gateway.cors.*` in `gateway/src/main/resources/application.yml`
(overridable via Vault for prod). Defaults are `http://localhost:3000` and
`http://localhost:5173` with `allow-credentials=true`.

Per-service CORS would be redundant — all browser traffic enters via the gateway.

### User identity
Gateway extracts `userId` from the JWT and forwards it as the `X-User-Id` header.
Controllers read it via `@RequestHeader("X-User-Id") String userId`. Don't parse JWTs
in business services.

### Bean wiring
Service implementations are NOT annotated with `@Component`/`@Service`. They are
constructed manually in `@Configuration` classes (e.g. `OrderServiceConfiguration`).
When adding a constructor parameter, update the corresponding `@Bean` method.

### Repository layout
JPA-using services split repositories into `repository/master/` (writes) and
`repository/slave/` (reads). The routing datasource picks the connection based on
which package the bean lives in.

### Response & paging shapes (from `common-dto`)
- All controllers return `BaseResponse` via static factories: `BaseResponse.ok(data)`,
  `.created(data)`, `.notFound(data)`, etc. Don't construct `BaseResponse` directly.
- `PagingRequest`: `page` is **1-indexed** (min 1), `size` defaults to 10. Convert to
  0-indexed (`page - 1`) before passing to Spring Data / MongoTemplate.

### Saga trigger
The order Saga is triggered by MongoDB CDC events (Mongo → Kafka Connect → orchestrator),
not by a direct call from order-service. See `scripts/kafka/mongo-connector.sh`.

### Tests in CI without infra
Spring Boot `contextLoads` tests are guarded so they pass without Kafka/Vault/MySQL
available (see orchestrator-service for the pattern). Mirror this when adding new services.

### Image storage
Product images and user avatars use S3-compatible storage via the `core-s3`
shared module. Clients upload directly to S3 with a presigned URL — the JVM
never touches the bytes. Two-step flow:
1. `POST /v1/products/{id}/image/presign` (or `.../users/self/avatar/presign`)
   returns `{ uploadUrl, objectKey, expiresAt }`. The signed URL embeds
   Content-Type and a 5MB content-length-range as conditions.
2. Client `PUT`s the bytes to `uploadUrl` with the matching `Content-Type`
   header.
3. Client calls `PUT /v1/products/{id}/image` (or `.../users/self/avatar`)
   with `{ objectKey }`. Server HEAD-checks the object, validates the key
   prefix, and stores the public URL.

Object keys: `products/{productId}/{uuid}.{ext}` and
`avatars/{userId}/{uuid}.{ext}`. Both prefixes have anonymous-read enabled,
so the stored URL is just `{public-base-url}/{key}` — clients fetch
directly. Vault path `secret/core-s3` holds the bucket, endpoint, and
credentials; switching from MinIO to AWS S3 is a Vault-only change (flip
`endpoint`, `path-style`, and creds).

### Observability
Every JVM service exposes Spring Boot Actuator on a separate management port
(`9091`) so it's never reachable through the gateway. Three endpoints matter:

- `/actuator/health/liveness` — k8s liveness probe target
- `/actuator/health/readiness` — k8s readiness probe target (gates traffic
  during startup until the service's external deps are reachable)
- `/actuator/prometheus` — Micrometer Prometheus scrape endpoint, tagged with
  `application=<service-name>`

Per-service `readiness.include` reflects each service's actual deps (e.g.
`readinessState,db,redis,mail` for authorization-server; `readinessState` only
for gateway / eureka-server / bff-service). Adding `db` to a service that has
no datasource will fail readiness — match the existing values.

Local-dev caveat: when nine services run on the same host via `make up`, they
all try to bind `9091` and only one wins. Smoke-test actuator one service at a
time, or assign distinct management ports per service. In k8s every pod has
its own loopback so 9091 is fine across the cluster.

The gateway intentionally does not route `/actuator/**`. The management port
is internal-only — protect it at the network level (k8s NetworkPolicy, AWS SG)
when deploying.

## Development Notes
- **Maven build order matters**: core modules must be installed before services — use `make build` (wraps `scripts/maven/install-modules.sh`)
- **Vault secrets required at startup**: each service fetches config from Vault on boot; if Vault is sealed, services crash on startup
- All services use Spring Boot 3.3.6 with consistent dependency versions
- Lombok is used extensively for reducing boilerplate
- Custom validation annotations (`@ValidEmail`, `@ValidPassword`)
- Consistent exception handling across all services
- Swagger documentation auto-aggregated at gateway level
- Service registration automatic via Eureka client