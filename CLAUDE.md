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
cp docker/.env.example docker/.env  # then fill in passwords + PayPal credentials

# 2. Start all infrastructure
./start-infrastructure.sh

# 3. Initialize & configure Vault (first time only)
./init-vault.sh

# 4. Create Kafka topics
./init-kafka-topics.sh

# 5. Install MongoDB Kafka Connector (CDC pipeline)
./install-mongodb-kafka-connector.sh

# 6. Build all Maven modules in dependency order
./install-modules.sh
```

### After Docker Restart (Vault Re-seals Automatically)
```bash
./start-infrastructure.sh   # restart containers
./init-vault.sh unseal      # re-unseal Vault — services will fail to start without this
```

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
# Start all infrastructure at once
./start-infrastructure.sh

# Or start individual services
docker compose -f docker/mysql.yml up -d
docker compose -f docker/kafka.yml up -d
docker compose -f docker/mongodb.yml up -d
docker compose -f docker/redis.yml up -d
docker compose -f docker/vault.yml up -d
```

### Development Workflow
1. Follow One-Time Setup above (first run only)
2. Start Eureka Server first: `cd eureka-server && mvn spring-boot:run`
3. Start auth + gateway, then business services
4. **inventory-service must start before order-service** (gRPC dependency)
5. Swagger UI: `http://localhost:8080/swagger-ui.html`

### Service Ports
| Service | Port |
|---|---|
| Gateway (entry point) | 8080 |
| Eureka Dashboard | 8761 |
| Vault UI | 8200 |
| Kafka Connect REST | 8093 |
| MySQL Master | 3306 |
| MySQL Slave1/Slave2 | 3307/3308 |

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
not by a direct call from order-service. See `install-mongodb-kafka-connector.sh`.

### Tests in CI without infra
Spring Boot `contextLoads` tests are guarded so they pass without Kafka/Vault/MySQL
available (see orchestrator-service for the pattern). Mirror this when adding new services.

## Development Notes
- **Maven build order matters**: core modules must be installed before services — use `./install-modules.sh`
- **Vault secrets required at startup**: each service fetches config from Vault on boot; if Vault is sealed, services crash on startup
- All services use Spring Boot 3.3.6 with consistent dependency versions
- Lombok is used extensively for reducing boilerplate
- Custom validation annotations (`@ValidEmail`, `@ValidPassword`)
- Consistent exception handling across all services
- Swagger documentation auto-aggregated at gateway level
- Service registration automatic via Eureka client