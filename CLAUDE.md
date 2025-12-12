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
# Start MySQL master-slave cluster
docker compose -f docker/mysql.yml up -d

# Start Kafka
docker compose -f docker/kafka.yml up -d

# Start MongoDB
docker compose -f docker/mongodb.yml up -d

# Start Redis
docker compose -f docker/redis.yml up -d

# Start Vault
docker compose -f docker/vault.yml up -d
```

### Development Workflow
1. Start required infrastructure services with Docker Compose
2. Configure Vault with necessary secrets
3. Start Eureka Server first
4. Start other services (they will register with Eureka)
5. Access Swagger UI via Gateway at `/swagger-ui.html`

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

## Security Architecture
- JWT-based authentication with RS256 signing
- Role-based access control with User/Admin roles
- OAuth2 authorization server implementation
- Vault integration for secure configuration management
- Request filtering through Gateway with authentication

## Service Communication
- **External**: REST APIs through Spring Cloud Gateway
- **Internal**: gRPC for high-performance service-to-service calls
- **Async**: Kafka events for decoupled communication
- **Caching**: Redis for session data and temporary storage

## Development Notes
- All services use Spring Boot 3.3.6 with consistent dependency versions
- Lombok is used extensively for reducing boilerplate
- Custom validation annotations (`@ValidEmail`, `@ValidPassword`)
- Consistent exception handling across all services
- Swagger documentation auto-aggregated at gateway level
- Service registration automatic via Eureka client