# S3 Image Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add presigned-upload S3 image storage for product images and user avatars, with MinIO locally and AWS S3 in production behind identical code.

**Architecture:** New shared `core/core-s3` Maven module wraps the AWS SDK and exposes an `S3StorageService` bean. `product-service` adds a single `imageUrl` field to `Product` (MongoDB) plus presign + attach endpoints. `authorization-server` adds a single `avatar_url` column to `user` (MySQL) plus presign + attach endpoints. MinIO runs in `docker/minio.yml` for dev with public-read policy; switching to AWS is a Vault-only change.

**Tech Stack:** Java 17, Spring Boot 3.3.6, AWS SDK for Java 2.x (`software.amazon.awssdk:s3`), Testcontainers MinIO module, MinIO 2024+, HashiCorp Vault, Docker Compose, MongoDB, MySQL 8.

**Reference spec:** `docs/superpowers/specs/2026-04-27-s3-image-storage-design.md`

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `core/core-s3/pom.xml` | Maven module definition |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Properties.java` | `@ConfigurationProperties("s3")` — bucket, endpoint, creds, limits |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java` | `@Configuration` building `S3Client` + `S3Presigner` beans |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/PresignedUpload.java` | Record `{ String uploadUrl; String objectKey; Instant expiresAt }` |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageService.java` | Public interface |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageServiceImpl.java` | SDK-backed implementation |
| `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/EnableCoreS3.java` | `@Import(S3Config.class)` activator annotation |
| `core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3StorageServiceImplIT.java` | Testcontainers MinIO integration test |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/PresignImageRequest.java` | `{ contentType, sizeBytes }` |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/AttachImageRequest.java` | `{ objectKey }` |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/response/PresignedUploadResponse.java` | `{ uploadUrl, objectKey, expiresAt }` |
| `docker/minio.yml` | Compose stack: `minio` + `minio-init` |
| `docker/vault-configs/core-s3.json` | Shared Vault secret payload for `secret/core-s3` |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductImageService.java` | Interface |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductImageServiceImpl.java` | Presign + attach implementation |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductImageController.java` | `POST /v1/products/{id}/image/presign`, `PUT /v1/products/{id}/image` |
| `product-service/src/test/java/org/aibles/ecommerce/product_service/controller/ProductImageControllerTest.java` | `@WebMvcTest` |
| `product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductImageServiceImplTest.java` | Unit test for service logic |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/UserAvatarService.java` | Interface |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/UserAvatarServiceImpl.java` | Presign + attach implementation |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/controller/UserAvatarController.java` | `POST /v1/users/self/avatar/presign`, `PUT /v1/users/self/avatar` |
| `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/UserAvatarServiceImplTest.java` | Unit test |

### Modified files

| Path | Change |
|---|---|
| `scripts/maven/install-modules.sh` | Insert `install_module "$SCRIPT_DIR/core/core-s3" "core-s3"` after `core-redis` |
| `scripts/infra/up.sh` | Add `start_compose "minio.yml" "MinIO"` after `vault.yml` |
| `scripts/vault/import-secrets.sh` | Add `load_config "$CFG_DIR/core-s3.json" "core-s3"` |
| `docker/.env.example` | Add `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` |
| `docker/ecommerce.sql` | Append `ALTER TABLE \`user\` ADD COLUMN avatar_url VARCHAR(512) NULL;` |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/BadRequestException.java` | (no edit; new exception classes added as separate files) |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/` | Add `ImageTypeNotAllowedException`, `ImageTooLargeException`, `ImageKeyForbiddenException`, `ImageNotUploadedException`, `StorageUnavailableException` |
| `product-service/pom.xml` | Add `<dependency>` on `core-s3` |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java` | Add `private String imageUrl;` |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java` | Add `imageUrl` field + mapper update |
| `product-service/src/main/java/org/aibles/ecommerce/product_service/configuration/ProductServiceConfiguration.java` | Add `@Bean` for `ProductImageService` and `@EnableCoreS3` |
| `product-service/src/main/resources/application.yml` | Add `secret/core-s3` to Vault `additional-contexts` |
| `authorization-server/pom.xml` | Add dependency on `core-s3` |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/entity/User.java` | Add `avatarUrl` column |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/dto/response/UserResponse.java` | Add `avatarUrl` field (if response DTO exists; otherwise via the existing user mapper) |
| `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java` (or equivalent) | Add `@Bean` for `UserAvatarService` and `@EnableCoreS3` |
| `authorization-server/src/main/resources/application.yml` | Add `secret/core-s3` to Vault `additional-contexts` |
| `CLAUDE.md` | Document `core-s3`, MinIO infra, new endpoints, avatar/image conventions |

---

## Task 1: Bootstrap `core-s3` Maven module

**Files:**
- Create: `core/core-s3/pom.xml`
- Modify: `scripts/maven/install-modules.sh`

- [ ] **Step 1: Create `core/core-s3/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.6</version>
        <relativePath/>
    </parent>
    <groupId>org.aibles.ecommerce</groupId>
    <artifactId>core-s3</artifactId>
    <version>0.0.1</version>
    <name>core-s3</name>
    <description>S3-compatible object storage abstraction for the ecommerce platform</description>
    <properties>
        <java.version>17</java.version>
        <aws.sdk.version>2.28.16</aws.sdk.version>
        <testcontainers.version>1.20.4</testcontainers.version>
    </properties>
    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>s3</artifactId>
            <version>${aws.sdk.version}</version>
        </dependency>
        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>minio</artifactId>
            <version>${testcontainers.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>junit-jupiter</artifactId>
            <version>${testcontainers.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 2: Register module in `scripts/maven/install-modules.sh`**

Insert this line **after** `install_module "$SCRIPT_DIR/core/core-redis" "core-redis"`:

```bash
install_module "$SCRIPT_DIR/core/core-s3"           "core-s3"
```

- [ ] **Step 3: Verify the module compiles**

Run:
```bash
cd core/core-s3 && mvn -q clean install -DskipTests
```
Expected: `BUILD SUCCESS`. (No source files yet — Maven still produces an empty jar.)

- [ ] **Step 4: Commit**

```bash
git add core/core-s3/pom.xml scripts/maven/install-modules.sh
git commit -m "feat(core-s3): bootstrap module skeleton"
```

---

## Task 2: `S3Properties` configuration class

**Files:**
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Properties.java`
- Test: `core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3PropertiesTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.core_s3;

import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.MapConfigurationPropertySource;

import java.time.Duration;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class S3PropertiesTest {

    @Test
    void bindsAllFieldsFromMap() {
        Map<String, String> props = Map.of(
            "s3.endpoint", "http://minio:9000",
            "s3.region", "us-east-1",
            "s3.bucket", "ecommerce-media",
            "s3.access-key", "minioadmin",
            "s3.secret-key", "minioadmin",
            "s3.path-style", "true",
            "s3.public-base-url", "http://localhost:9000/ecommerce-media",
            "s3.presign-ttl", "PT5M",
            "s3.max-upload-size", "5242880",
            "s3.allowed-types", "image/jpeg,image/png,image/webp"
        );
        S3Properties bound = new Binder(new MapConfigurationPropertySource(props))
            .bind("s3", S3Properties.class).get();

        assertEquals("http://minio:9000", bound.getEndpoint());
        assertEquals("ecommerce-media", bound.getBucket());
        assertTrue(bound.isPathStyle());
        assertEquals(Duration.ofMinutes(5), bound.getPresignTtl());
        assertEquals(5_242_880L, bound.getMaxUploadSize());
        assertEquals(List.of("image/jpeg", "image/png", "image/webp"), bound.getAllowedTypes());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd core/core-s3 && mvn -q -Dtest=S3PropertiesTest test
```
Expected: compilation error — `S3Properties` does not exist.

- [ ] **Step 3: Create `S3Properties`**

```java
package org.aibles.ecommerce.core_s3;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;

@Data
@ConfigurationProperties(prefix = "s3")
public class S3Properties {

    /** S3 endpoint URL. Empty/null means use AWS SDK default (real AWS S3). */
    private String endpoint;

    /** AWS region. Required even for MinIO; the SDK requires a non-null value. */
    private String region = "us-east-1";

    /** Bucket name. */
    private String bucket;

    private String accessKey;
    private String secretKey;

    /** Use path-style addressing (host/bucket/key). True for MinIO, false for AWS. */
    private boolean pathStyle;

    /**
     * Public-facing base URL prepended to object keys when storing in the database.
     * E.g. "http://localhost:9000/ecommerce-media" or
     * "https://ecommerce-media.s3.us-east-1.amazonaws.com".
     */
    private String publicBaseUrl;

    /** TTL for presigned upload URLs. */
    private Duration presignTtl = Duration.ofMinutes(5);

    /** Maximum upload size in bytes. */
    private long maxUploadSize = 5L * 1024 * 1024;

    /** Allowed Content-Type values for uploads. */
    private List<String> allowedTypes = List.of("image/jpeg", "image/png", "image/webp");
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd core/core-s3 && mvn -q -Dtest=S3PropertiesTest test
```
Expected: `Tests run: 1, Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Properties.java \
        core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3PropertiesTest.java
git commit -m "feat(core-s3): add S3Properties configuration class"
```

---

## Task 3: `S3Config` beans + `EnableCoreS3` activator

**Files:**
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java`
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/EnableCoreS3.java`
- Test: `core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3ConfigTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.core_s3;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import static org.assertj.core.api.Assertions.assertThat;

class S3ConfigTest {

    private final ApplicationContextRunner ctx = new ApplicationContextRunner()
        .withUserConfiguration(S3Config.class)
        .withPropertyValues(
            "s3.endpoint=http://minio:9000",
            "s3.region=us-east-1",
            "s3.bucket=ecommerce-media",
            "s3.access-key=minioadmin",
            "s3.secret-key=minioadmin",
            "s3.path-style=true",
            "s3.public-base-url=http://localhost:9000/ecommerce-media"
        );

    @Test
    void registersS3ClientAndPresigner() {
        ctx.run(c -> {
            assertThat(c).hasSingleBean(S3Client.class);
            assertThat(c).hasSingleBean(S3Presigner.class);
            assertThat(c).hasSingleBean(S3Properties.class);
        });
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd core/core-s3 && mvn -q -Dtest=S3ConfigTest test
```
Expected: compilation error — `S3Config` does not exist.

- [ ] **Step 3: Create `S3Config`**

```java
package org.aibles.ecommerce.core_s3;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.net.URI;

@Configuration
@EnableConfigurationProperties(S3Properties.class)
public class S3Config {

    @Bean
    public S3Client s3Client(S3Properties props) {
        return base(S3Client.builder(), props).build();
    }

    @Bean
    public S3Presigner s3Presigner(S3Properties props) {
        return base(S3Presigner.builder(), props).build();
    }

    private static <B extends software.amazon.awssdk.awscore.client.builder.AwsClientBuilder<B, ?>> B base(B builder, S3Properties props) {
        builder
            .region(Region.of(props.getRegion()))
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey())));
        if (props.getEndpoint() != null && !props.getEndpoint().isBlank()) {
            builder.endpointOverride(URI.create(props.getEndpoint()));
        }
        // path-style addressing is configured per-builder; both S3Client and S3Presigner
        // accept S3Configuration via serviceConfiguration() on their concrete builders.
        if (builder instanceof software.amazon.awssdk.services.s3.S3BaseClientBuilder<?, ?> s3b) {
            s3b.serviceConfiguration(S3Configuration.builder()
                .pathStyleAccessEnabled(props.isPathStyle()).build());
        }
        return builder;
    }
}
```

- [ ] **Step 4: Create `EnableCoreS3`**

```java
package org.aibles.ecommerce.core_s3;

import org.springframework.context.annotation.Import;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
@Import(S3Config.class)
public @interface EnableCoreS3 {
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd core/core-s3 && mvn -q -Dtest=S3ConfigTest test
```
Expected: `Tests run: 1, Failures: 0`.

- [ ] **Step 6: Commit**

```bash
git add core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java \
        core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/EnableCoreS3.java \
        core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3ConfigTest.java
git commit -m "feat(core-s3): add S3Config beans and EnableCoreS3 activator"
```

---

## Task 4: `S3StorageService` interface + `PresignedUpload` record + impl

**Files:**
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/PresignedUpload.java`
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageService.java`
- Create: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageServiceImpl.java`
- Modify: `core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java` (add `S3StorageService` bean)
- Test: `core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3StorageServiceImplIT.java`

This task is integration-test-driven against a real MinIO container.

- [ ] **Step 1: Write the failing integration test**

```java
package org.aibles.ecommerce.core_s3;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.MinIOContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
class S3StorageServiceImplIT {

    @Container
    static final MinIOContainer minio = new MinIOContainer("minio/minio:RELEASE.2024-09-13T20-26-02Z")
        .withUserName("minioadmin")
        .withPassword("minioadmin");

    static S3Client client;
    static S3Presigner presigner;
    static S3Properties props;
    static S3StorageServiceImpl service;

    @BeforeAll
    static void setUp() {
        props = new S3Properties();
        props.setEndpoint(minio.getS3URL());
        props.setRegion("us-east-1");
        props.setBucket("test-bucket");
        props.setAccessKey("minioadmin");
        props.setSecretKey("minioadmin");
        props.setPathStyle(true);
        props.setPublicBaseUrl(minio.getS3URL() + "/test-bucket");
        props.setPresignTtl(Duration.ofMinutes(5));
        props.setMaxUploadSize(1024 * 1024);

        client = S3Client.builder()
            .endpointOverride(URI.create(props.getEndpoint()))
            .region(Region.of(props.getRegion()))
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey())))
            .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build())
            .build();
        presigner = S3Presigner.builder()
            .endpointOverride(URI.create(props.getEndpoint()))
            .region(Region.of(props.getRegion()))
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey())))
            .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build())
            .build();

        client.createBucket(CreateBucketRequest.builder().bucket(props.getBucket()).build());
        service = new S3StorageServiceImpl(client, presigner, props);
    }

    @Test
    void presignedUrlAcceptsValidUpload() throws Exception {
        PresignedUpload pre = service.presignUpload("products/abc/test.jpg", "image/jpeg");

        HttpResponse<String> resp = HttpClient.newHttpClient().send(
            HttpRequest.newBuilder(URI.create(pre.uploadUrl()))
                .header("Content-Type", "image/jpeg")
                .PUT(HttpRequest.BodyPublishers.ofByteArray(new byte[]{1, 2, 3}))
                .build(),
            HttpResponse.BodyHandlers.ofString());

        assertThat(resp.statusCode()).isEqualTo(200);
        assertThat(service.objectExists("products/abc/test.jpg")).isTrue();
    }

    @Test
    void objectExistsFalseForUnknownKey() {
        assertThat(service.objectExists("does/not/exist.png")).isFalse();
    }

    @Test
    void publicUrlConcatenatesBaseAndKey() {
        assertThat(service.publicUrl("avatars/u1/x.png"))
            .isEqualTo(props.getPublicBaseUrl() + "/avatars/u1/x.png");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd core/core-s3 && mvn -q -Dtest=S3StorageServiceImplIT test
```
Expected: compilation error — `PresignedUpload`, `S3StorageService`, `S3StorageServiceImpl` do not exist. (Docker must be running for the test to actually execute.)

- [ ] **Step 3: Create `PresignedUpload`**

```java
package org.aibles.ecommerce.core_s3;

import java.time.Instant;

public record PresignedUpload(String uploadUrl, String objectKey, Instant expiresAt) {
}
```

- [ ] **Step 4: Create `S3StorageService` interface**

```java
package org.aibles.ecommerce.core_s3;

public interface S3StorageService {

    /**
     * Mint a presigned PUT URL the client can use to upload directly to S3.
     * The signed URL embeds Content-Type as a condition; uploads with a different
     * Content-Type are rejected by S3.
     */
    PresignedUpload presignUpload(String objectKey, String contentType);

    /** HEAD the object; true if it exists. */
    boolean objectExists(String objectKey);

    /** Convert an object key into the public URL stored in the database. */
    String publicUrl(String objectKey);
}
```

- [ ] **Step 5: Create `S3StorageServiceImpl`**

```java
package org.aibles.ecommerce.core_s3;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.PresignedPutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;

import java.time.Instant;

@Slf4j
@RequiredArgsConstructor
public class S3StorageServiceImpl implements S3StorageService {

    private final S3Client client;
    private final S3Presigner presigner;
    private final S3Properties props;

    @Override
    public PresignedUpload presignUpload(String objectKey, String contentType) {
        PutObjectRequest put = PutObjectRequest.builder()
            .bucket(props.getBucket())
            .key(objectKey)
            .contentType(contentType)
            .build();
        PutObjectPresignRequest req = PutObjectPresignRequest.builder()
            .signatureDuration(props.getPresignTtl())
            .putObjectRequest(put)
            .build();
        PresignedPutObjectRequest signed = presigner.presignPutObject(req);
        Instant expiresAt = Instant.now().plus(props.getPresignTtl());
        return new PresignedUpload(signed.url().toString(), objectKey, expiresAt);
    }

    @Override
    public boolean objectExists(String objectKey) {
        try {
            client.headObject(HeadObjectRequest.builder()
                .bucket(props.getBucket()).key(objectKey).build());
            return true;
        } catch (NoSuchKeyException e) {
            return false;
        } catch (software.amazon.awssdk.services.s3.model.S3Exception e) {
            if (e.statusCode() == 404) return false;
            throw e;
        }
    }

    @Override
    public String publicUrl(String objectKey) {
        return props.getPublicBaseUrl() + "/" + objectKey;
    }
}
```

- [ ] **Step 6: Register `S3StorageService` bean in `S3Config`**

Add to `S3Config`:

```java
    @Bean
    public S3StorageService s3StorageService(S3Client client, S3Presigner presigner, S3Properties props) {
        return new S3StorageServiceImpl(client, presigner, props);
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run (Docker must be running):
```bash
cd core/core-s3 && mvn -q -Dtest=S3StorageServiceImplIT test
```
Expected: `Tests run: 3, Failures: 0`.

- [ ] **Step 8: Commit**

```bash
git add core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/PresignedUpload.java \
        core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageService.java \
        core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3StorageServiceImpl.java \
        core/core-s3/src/main/java/org/aibles/ecommerce/core_s3/S3Config.java \
        core/core-s3/src/test/java/org/aibles/ecommerce/core_s3/S3StorageServiceImplIT.java
git commit -m "feat(core-s3): implement S3StorageService with Testcontainers IT"
```

---

## Task 5: New exception types in `common-dto`

**Files:**
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageTypeNotAllowedException.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageTooLargeException.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageKeyForbiddenException.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageNotUploadedException.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/StorageUnavailableException.java`
- Test: `core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/exception/ImageExceptionsTest.java`

Existing exceptions (e.g. `BadRequestException`) follow this constructor pattern: `setStatus(...)` + `setCode("...")`. Mirror it.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.common_dto.exception;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ImageExceptionsTest {

    @Test
    void typeNotAllowedIs400WithStableCode() {
        ImageTypeNotAllowedException ex = new ImageTypeNotAllowedException();
        assertThat(ex.getStatus()).isEqualTo(400);
        assertThat(ex.getCode()).isEqualTo("org.aibles.business.exception.ImageTypeNotAllowedException");
    }

    @Test
    void tooLargeIs400() {
        assertThat(new ImageTooLargeException().getStatus()).isEqualTo(400);
        assertThat(new ImageTooLargeException().getCode())
            .isEqualTo("org.aibles.business.exception.ImageTooLargeException");
    }

    @Test
    void keyForbiddenIs403() {
        assertThat(new ImageKeyForbiddenException().getStatus()).isEqualTo(403);
        assertThat(new ImageKeyForbiddenException().getCode())
            .isEqualTo("org.aibles.business.exception.ImageKeyForbiddenException");
    }

    @Test
    void notUploadedIs400() {
        assertThat(new ImageNotUploadedException().getStatus()).isEqualTo(400);
        assertThat(new ImageNotUploadedException().getCode())
            .isEqualTo("org.aibles.business.exception.ImageNotUploadedException");
    }

    @Test
    void storageUnavailableIs503() {
        assertThat(new StorageUnavailableException().getStatus()).isEqualTo(503);
        assertThat(new StorageUnavailableException().getCode())
            .isEqualTo("org.aibles.business.exception.StorageUnavailableException");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd core/common-dto && mvn -q -Dtest=ImageExceptionsTest test
```
Expected: compilation error — exception classes do not exist.

- [ ] **Step 3: Create each exception class**

`ImageTypeNotAllowedException.java`:

```java
package org.aibles.ecommerce.common_dto.exception;

public class ImageTypeNotAllowedException extends BaseException {
    public ImageTypeNotAllowedException() {
        setStatus(400);
        setCode("org.aibles.business.exception.ImageTypeNotAllowedException");
    }
}
```

`ImageTooLargeException.java`:

```java
package org.aibles.ecommerce.common_dto.exception;

public class ImageTooLargeException extends BaseException {
    public ImageTooLargeException() {
        setStatus(400);
        setCode("org.aibles.business.exception.ImageTooLargeException");
    }
}
```

`ImageKeyForbiddenException.java`:

```java
package org.aibles.ecommerce.common_dto.exception;

public class ImageKeyForbiddenException extends BaseException {
    public ImageKeyForbiddenException() {
        setStatus(403);
        setCode("org.aibles.business.exception.ImageKeyForbiddenException");
    }
}
```

`ImageNotUploadedException.java`:

```java
package org.aibles.ecommerce.common_dto.exception;

public class ImageNotUploadedException extends BaseException {
    public ImageNotUploadedException() {
        setStatus(400);
        setCode("org.aibles.business.exception.ImageNotUploadedException");
    }
}
```

`StorageUnavailableException.java`:

```java
package org.aibles.ecommerce.common_dto.exception;

public class StorageUnavailableException extends BaseException {
    public StorageUnavailableException() {
        setStatus(503);
        setCode("org.aibles.business.exception.StorageUnavailableException");
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd core/common-dto && mvn -q -Dtest=ImageExceptionsTest test
```
Expected: `Tests run: 5, Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/Image*.java \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/StorageUnavailableException.java \
        core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/exception/ImageExceptionsTest.java
git commit -m "feat(common-dto): add image-storage exception types"
```

---

## Task 6: Common request/response DTOs for image upload

**Files:**
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/PresignImageRequest.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/AttachImageRequest.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/response/PresignedUploadResponse.java`
- Test: `core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/ImageDtosTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.common_dto;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class ImageDtosTest {

    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @Test
    void presignImageRequestSerializesAndBindsValidation() throws Exception {
        String json = "{\"contentType\":\"image/jpeg\",\"sizeBytes\":1234}";
        PresignImageRequest req = mapper.readValue(json, PresignImageRequest.class);
        assertThat(req.getContentType()).isEqualTo("image/jpeg");
        assertThat(req.getSizeBytes()).isEqualTo(1234L);
    }

    @Test
    void attachImageRequestRoundTrips() throws Exception {
        AttachImageRequest req = mapper.readValue(
            "{\"objectKey\":\"products/abc/x.jpg\"}", AttachImageRequest.class);
        assertThat(req.getObjectKey()).isEqualTo("products/abc/x.jpg");
    }

    @Test
    void presignedUploadResponseRoundTrips() throws Exception {
        PresignedUploadResponse r = new PresignedUploadResponse(
            "http://signed", "products/abc/x.jpg", Instant.parse("2026-04-27T00:00:00Z"));
        String json = mapper.writeValueAsString(r);
        assertThat(json).contains("\"uploadUrl\":\"http://signed\"");
        assertThat(json).contains("\"objectKey\":\"products/abc/x.jpg\"");
        assertThat(json).contains("\"expiresAt\":\"2026-04-27T00:00:00Z\"");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd core/common-dto && mvn -q -Dtest=ImageDtosTest test
```
Expected: compilation error — DTO classes do not exist.

- [ ] **Step 3: Create the DTOs**

`PresignImageRequest.java`:

```java
package org.aibles.ecommerce.common_dto.request;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class PresignImageRequest {
    @NotBlank
    private String contentType;

    @Positive
    @Min(1)
    private long sizeBytes;
}
```

`AttachImageRequest.java`:

```java
package org.aibles.ecommerce.common_dto.request;

import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class AttachImageRequest {
    @NotBlank
    private String objectKey;
}
```

`PresignedUploadResponse.java`:

```java
package org.aibles.ecommerce.common_dto.response;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.time.Instant;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class PresignedUploadResponse {
    private String uploadUrl;
    private String objectKey;
    private Instant expiresAt;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd core/common-dto && mvn -q -Dtest=ImageDtosTest test
```
Expected: `Tests run: 3, Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/PresignImageRequest.java \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/request/AttachImageRequest.java \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/response/PresignedUploadResponse.java \
        core/common-dto/src/test/java/org/aibles/ecommerce/common_dto/ImageDtosTest.java
git commit -m "feat(common-dto): add image presign/attach DTOs"
```

---

## Task 7: MinIO Docker compose stack + infra wiring

**Files:**
- Create: `docker/minio.yml`
- Modify: `docker/.env.example`
- Modify: `scripts/infra/up.sh`

- [ ] **Step 1: Add MinIO env-vars to `docker/.env.example`**

Append to the file:

```
# ===========================================
# MinIO (S3-compatible object storage)
# ===========================================
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
MINIO_BUCKET=ecommerce-media
```

- [ ] **Step 2: Mirror into `docker/.env`** (developer's local copy)

Run:
```bash
echo "" >> docker/.env
echo "MINIO_ROOT_USER=minioadmin" >> docker/.env
echo "MINIO_ROOT_PASSWORD=minioadmin" >> docker/.env
echo "MINIO_BUCKET=ecommerce-media" >> docker/.env
```

- [ ] **Step 3: Create `docker/minio.yml`**

```yaml
version: '3.8'

services:
  minio:
    image: minio/minio:RELEASE.2024-09-13T20-26-02Z
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:-minioadmin}
    volumes:
      - minio-data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5

  minio-init:
    image: minio/mc:RELEASE.2024-09-16T17-43-14Z
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
        mc alias set local http://minio:9000 ${MINIO_ROOT_USER:-minioadmin} ${MINIO_ROOT_PASSWORD:-minioadmin};
        mc mb --ignore-existing local/${MINIO_BUCKET:-ecommerce-media};
        mc anonymous set download local/${MINIO_BUCKET:-ecommerce-media}/products;
        mc anonymous set download local/${MINIO_BUCKET:-ecommerce-media}/avatars;
        echo 'MinIO bucket and anonymous-read policy applied.';
      "
    restart: "no"

volumes:
  minio-data:
```

- [ ] **Step 4: Wire MinIO into `scripts/infra/up.sh`**

Insert this line **after** `start_compose "vault.yml" "Vault"`:

```bash
start_compose "minio.yml"   "MinIO"
```

- [ ] **Step 5: Bring infra up and verify MinIO is reachable**

Run:
```bash
make infra-up
curl -fsS http://localhost:9000/minio/health/live && echo OK
```
Expected: prints `OK`. Web console at <http://localhost:9001>.

- [ ] **Step 6: Verify bucket exists and is anonymous-readable**

Run:
```bash
docker run --rm --network host minio/mc:RELEASE.2024-09-16T17-43-14Z \
    /bin/sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin && mc ls local/ecommerce-media"
```
Expected: lists `products/` and `avatars/` (or empty bucket — both fine, just no error).

- [ ] **Step 7: Commit**

```bash
git add docker/minio.yml docker/.env.example scripts/infra/up.sh
git commit -m "feat(infra): add MinIO compose stack and wire into make infra-up"
```

---

## Task 8: Vault config for `core-s3`

**Files:**
- Create: `docker/vault-configs/core-s3.json`
- Modify: `scripts/vault/import-secrets.sh`

- [ ] **Step 1: Create `docker/vault-configs/core-s3.json`**

```json
{
  "s3.endpoint": "http://localhost:9000",
  "s3.region": "us-east-1",
  "s3.bucket": "ecommerce-media",
  "s3.access-key": "minioadmin",
  "s3.secret-key": "minioadmin",
  "s3.path-style": "true",
  "s3.public-base-url": "http://localhost:9000/ecommerce-media",
  "s3.presign-ttl": "PT5M",
  "s3.max-upload-size": "5242880",
  "s3.allowed-types": "image/jpeg,image/png,image/webp"
}
```

Note: services run on the host (not inside Docker), so `s3.endpoint` is `localhost:9000`. Tests inside containers would use `minio:9000`; the impl uses whatever Vault returns.

- [ ] **Step 2: Wire into `scripts/vault/import-secrets.sh`**

Insert this line **after** `load_config "$CFG_DIR/ecommerce-common.json" "ecommerce"`:

```bash
load_config "$CFG_DIR/core-s3.json"                 "core-s3"
```

- [ ] **Step 3: Re-import Vault secrets and verify**

Run:
```bash
make vault-import
source <(scripts/vault/login.sh env)
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/core-s3" | jq '.data.data["s3.bucket"]'
```
Expected: prints `"ecommerce-media"`.

- [ ] **Step 4: Commit**

```bash
git add docker/vault-configs/core-s3.json scripts/vault/import-secrets.sh
git commit -m "feat(vault): add core-s3 shared secret config"
```

---

## Task 9: product-service — add `imageUrl` field + wire `core-s3`

**Files:**
- Modify: `product-service/pom.xml`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java`
- Modify: `product-service/src/main/resources/application.yml`
- Test: `product-service/src/test/java/org/aibles/ecommerce/product_service/entity/ProductImageUrlTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.product_service.entity;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ProductImageUrlTest {

    @Test
    void productHasNullableImageUrl() {
        Product p = Product.builder()
            .id("abc")
            .name("Test")
            .price(9.99)
            .imageUrl("http://localhost:9000/ecommerce-media/products/abc/x.jpg")
            .build();
        assertThat(p.getImageUrl()).isEqualTo("http://localhost:9000/ecommerce-media/products/abc/x.jpg");

        Product noImage = Product.builder().id("xyz").build();
        assertThat(noImage.getImageUrl()).isNull();
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd product-service && mvn -q -Dtest=ProductImageUrlTest test
```
Expected: compilation error — `imageUrl` does not exist on `Product`.

- [ ] **Step 3: Add `imageUrl` to `Product` entity**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java`. Add the new field after `category`:

```java
    @Indexed
    private String category;

    /** Public URL of the product image, or null if none. */
    private String imageUrl;
```

- [ ] **Step 4: Add `imageUrl` to `ProductResponse`**

Open `product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java` and add `private String imageUrl;` near the other fields. If a manual mapper exists (e.g. `ProductResponse.from(Product p)` or similar), update it to pass through `imageUrl`. Read the existing file before editing to find the exact mapping site.

- [ ] **Step 5: Add `core-s3` Maven dependency**

Edit `product-service/pom.xml`. In the `<dependencies>` block, add:

```xml
        <dependency>
            <groupId>org.aibles.ecommerce</groupId>
            <artifactId>core-s3</artifactId>
            <version>0.0.1</version>
        </dependency>
```

- [ ] **Step 6: Add `secret/core-s3` to Vault import contexts**

Open `product-service/src/main/resources/application.yml`. Replace the `kv:` block with:

```yaml
  cloud:
    vault:
      uri: http://localhost:8200
      token: ${VAULT_TOKEN}
      fail-fast: true
      kv:
        enabled: true
        backend: secret
        default-context: ecommerce
        application-name: product-service
        additional-contexts: core-s3
```

- [ ] **Step 7: Build and run the test**

Run:
```bash
cd core/common-dto && mvn -q clean install -DskipTests
cd ../core-s3 && mvn -q clean install -DskipTests
cd ../../product-service && mvn -q -Dtest=ProductImageUrlTest test
```
Expected: `Tests run: 1, Failures: 0`.

- [ ] **Step 8: Commit**

```bash
git add product-service/pom.xml \
        product-service/src/main/java/org/aibles/ecommerce/product_service/entity/Product.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/dto/response/ProductResponse.java \
        product-service/src/main/resources/application.yml \
        product-service/src/test/java/org/aibles/ecommerce/product_service/entity/ProductImageUrlTest.java
git commit -m "feat(product-service): add imageUrl field and wire core-s3"
```

---

## Task 10: product-service — `ProductImageService` + presign/attach logic

**Files:**
- Create: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductImageService.java`
- Create: `product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductImageServiceImpl.java`
- Modify: `product-service/src/main/java/org/aibles/ecommerce/product_service/configuration/ProductServiceConfiguration.java`
- Test: `product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductImageServiceImplTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.common_dto.exception.*;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.impl.ProductImageServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class ProductImageServiceImplTest {

    private ProductRepository productRepo;
    private S3StorageService storage;
    private S3Properties props;
    private ProductImageService service;

    @BeforeEach
    void setUp() {
        productRepo = mock(ProductRepository.class);
        storage = mock(S3StorageService.class);
        props = new S3Properties();
        props.setMaxUploadSize(5L * 1024 * 1024);
        props.setAllowedTypes(List.of("image/jpeg", "image/png", "image/webp"));
        props.setPresignTtl(Duration.ofMinutes(5));
        props.setPublicBaseUrl("http://localhost:9000/ecommerce-media");
        service = new ProductImageServiceImpl(productRepo, storage, props);
    }

    @Test
    void presignRejectsUnsupportedContentType() {
        when(productRepo.findById("abc")).thenReturn(Optional.of(new Product()));
        PresignImageRequest req = new PresignImageRequest("application/pdf", 100L);
        assertThatThrownBy(() -> service.presign("abc", req))
            .isInstanceOf(ImageTypeNotAllowedException.class);
    }

    @Test
    void presignRejectsOversize() {
        when(productRepo.findById("abc")).thenReturn(Optional.of(new Product()));
        PresignImageRequest req = new PresignImageRequest("image/jpeg", 10L * 1024 * 1024);
        assertThatThrownBy(() -> service.presign("abc", req))
            .isInstanceOf(ImageTooLargeException.class);
    }

    @Test
    void presignReturnsUrlWithProductScopedKey() {
        when(productRepo.findById("abc")).thenReturn(Optional.of(new Product()));
        when(storage.presignUpload(anyString(), eq("image/jpeg")))
            .thenAnswer(inv -> new PresignedUpload("http://signed", inv.getArgument(0), Instant.now().plusSeconds(300)));

        PresignedUploadResponse resp = service.presign("abc", new PresignImageRequest("image/jpeg", 1024L));

        assertThat(resp.getUploadUrl()).isEqualTo("http://signed");
        assertThat(resp.getObjectKey()).startsWith("products/abc/");
        assertThat(resp.getObjectKey()).endsWith(".jpg");
    }

    @Test
    void attachRejectsKeyWithMismatchedPrefix() {
        when(productRepo.findById("abc")).thenReturn(Optional.of(new Product()));
        AttachImageRequest req = new AttachImageRequest("products/OTHER/x.jpg");
        assertThatThrownBy(() -> service.attach("abc", req))
            .isInstanceOf(ImageKeyForbiddenException.class);
    }

    @Test
    void attachRejectsWhenObjectMissing() {
        when(productRepo.findById("abc")).thenReturn(Optional.of(new Product()));
        when(storage.objectExists("products/abc/x.jpg")).thenReturn(false);
        assertThatThrownBy(() -> service.attach("abc", new AttachImageRequest("products/abc/x.jpg")))
            .isInstanceOf(ImageNotUploadedException.class);
    }

    @Test
    void attachPersistsPublicUrlAndReturnsResponse() {
        Product p = Product.builder().id("abc").name("X").price(1.0).build();
        when(productRepo.findById("abc")).thenReturn(Optional.of(p));
        when(storage.objectExists("products/abc/x.jpg")).thenReturn(true);
        when(storage.publicUrl("products/abc/x.jpg"))
            .thenReturn("http://localhost:9000/ecommerce-media/products/abc/x.jpg");
        when(productRepo.save(any())).thenAnswer(inv -> inv.getArgument(0));

        ProductResponse resp = service.attach("abc", new AttachImageRequest("products/abc/x.jpg"));

        assertThat(p.getImageUrl()).isEqualTo("http://localhost:9000/ecommerce-media/products/abc/x.jpg");
        assertThat(resp.getImageUrl()).isEqualTo(p.getImageUrl());
    }

    @Test
    void presignThrowsWhenProductMissing() {
        when(productRepo.findById("nope")).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.presign("nope", new PresignImageRequest("image/jpeg", 100L)))
            .isInstanceOf(NotFoundException.class);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd product-service && mvn -q -Dtest=ProductImageServiceImplTest test
```
Expected: compilation error — `ProductImageService`, `ProductImageServiceImpl` do not exist.

- [ ] **Step 3: Create `ProductImageService` interface**

```java
package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;

public interface ProductImageService {
    PresignedUploadResponse presign(String productId, PresignImageRequest request);
    ProductResponse attach(String productId, AttachImageRequest request);
}
```

- [ ] **Step 4: Create `ProductImageServiceImpl`**

```java
package org.aibles.ecommerce.product_service.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.exception.*;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.ProductImageService;

import java.util.UUID;

@Slf4j
@RequiredArgsConstructor
public class ProductImageServiceImpl implements ProductImageService {

    private final ProductRepository productRepository;
    private final S3StorageService storage;
    private final S3Properties props;

    @Override
    public PresignedUploadResponse presign(String productId, PresignImageRequest request) {
        Product product = productRepository.findById(productId).orElseThrow(NotFoundException::new);
        validate(request);
        String ext = extensionFor(request.getContentType());
        String key = "products/" + product.getId() + "/" + UUID.randomUUID() + "." + ext;
        PresignedUpload signed = storage.presignUpload(key, request.getContentType());
        return new PresignedUploadResponse(signed.uploadUrl(), signed.objectKey(), signed.expiresAt());
    }

    @Override
    public ProductResponse attach(String productId, AttachImageRequest request) {
        Product product = productRepository.findById(productId).orElseThrow(NotFoundException::new);
        String prefix = "products/" + productId + "/";
        if (!request.getObjectKey().startsWith(prefix)) {
            throw new ImageKeyForbiddenException();
        }
        if (!storage.objectExists(request.getObjectKey())) {
            throw new ImageNotUploadedException();
        }
        product.setImageUrl(storage.publicUrl(request.getObjectKey()));
        Product saved = productRepository.save(product);
        return ProductResponse.from(saved);
    }

    private void validate(PresignImageRequest req) {
        if (!props.getAllowedTypes().contains(req.getContentType())) {
            throw new ImageTypeNotAllowedException();
        }
        if (req.getSizeBytes() > props.getMaxUploadSize()) {
            throw new ImageTooLargeException();
        }
    }

    private static String extensionFor(String contentType) {
        return switch (contentType) {
            case "image/jpeg" -> "jpg";
            case "image/png" -> "png";
            case "image/webp" -> "webp";
            default -> throw new ImageTypeNotAllowedException();
        };
    }
}
```

> **Note for the implementer:** if `ProductResponse.from(Product)` doesn't already exist, add a static factory there (or use the existing mapper, whatever the existing service uses). Read `ProductServiceImpl` first to match the existing conversion pattern.

- [ ] **Step 5: Wire bean and `@EnableCoreS3` in `ProductServiceConfiguration`**

Edit `product-service/src/main/java/org/aibles/ecommerce/product_service/configuration/ProductServiceConfiguration.java`:

```java
package org.aibles.ecommerce.product_service.configuration;

import org.aibles.ecommerce.core_s3.EnableCoreS3;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.ProductImageService;
import org.aibles.ecommerce.product_service.service.ProductService;
import org.aibles.ecommerce.product_service.service.impl.ProductImageServiceImpl;
import org.aibles.ecommerce.product_service.service.impl.ProductServiceImpl;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableMongoAuditing
@EnableAsync
@EnableCoreS3
public class ProductServiceConfiguration {

    @Bean
    public ProductService productService(ProductRepository productRepository,
                                         ProductQuantityHistoryRepo productQuantityHistoryRepo,
                                         ApplicationEventPublisher applicationEventPublisher) {
        return new ProductServiceImpl(productRepository, productQuantityHistoryRepo, applicationEventPublisher);
    }

    @Bean
    public ProductImageService productImageService(ProductRepository productRepository,
                                                   S3StorageService storage,
                                                   S3Properties props) {
        return new ProductImageServiceImpl(productRepository, storage, props);
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
cd product-service && mvn -q -Dtest=ProductImageServiceImplTest test
```
Expected: `Tests run: 7, Failures: 0`.

- [ ] **Step 7: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/service/ProductImageService.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/service/impl/ProductImageServiceImpl.java \
        product-service/src/main/java/org/aibles/ecommerce/product_service/configuration/ProductServiceConfiguration.java \
        product-service/src/test/java/org/aibles/ecommerce/product_service/service/ProductImageServiceImplTest.java
git commit -m "feat(product-service): add ProductImageService presign/attach logic"
```

---

## Task 11: product-service — `ProductImageController`

**Files:**
- Create: `product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductImageController.java`
- Test: `product-service/src/test/java/org/aibles/ecommerce/product_service/controller/ProductImageControllerTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.product_service.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.service.ProductImageService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = ProductImageController.class)
class ProductImageControllerTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private ObjectMapper mapper;

    @MockBean
    private ProductImageService imageService;

    @Test
    void presignReturnsSignedUrl() throws Exception {
        when(imageService.presign(eq("abc"), any(PresignImageRequest.class)))
            .thenReturn(new PresignedUploadResponse(
                "http://signed", "products/abc/x.jpg",
                Instant.parse("2026-04-27T00:00:00Z")));

        mvc.perform(post("/v1/products/abc/image/presign")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"contentType\":\"image/jpeg\",\"sizeBytes\":1024}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.uploadUrl").value("http://signed"))
            .andExpect(jsonPath("$.data.objectKey").value("products/abc/x.jpg"));
    }

    @Test
    void attachReturnsUpdatedProduct() throws Exception {
        ProductResponse resp = new ProductResponse();
        resp.setId("abc");
        resp.setImageUrl("http://localhost:9000/ecommerce-media/products/abc/x.jpg");
        when(imageService.attach(eq("abc"), any(AttachImageRequest.class))).thenReturn(resp);

        mvc.perform(put("/v1/products/abc/image")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"objectKey\":\"products/abc/x.jpg\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.imageUrl")
                .value("http://localhost:9000/ecommerce-media/products/abc/x.jpg"));
    }
}
```

> **Note for the implementer:** if `ProductResponse` doesn't have a no-args constructor or simple setters (it's a record, etc.), adapt the test to construct it the same way `ProductController`'s tests do. Read existing controller tests in `product-service/src/test` first.

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd product-service && mvn -q -Dtest=ProductImageControllerTest test
```
Expected: compilation error — `ProductImageController` does not exist.

- [ ] **Step 3: Create `ProductImageController`**

```java
package org.aibles.ecommerce.product_service.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.product_service.service.ProductImageService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1/products")
public class ProductImageController {

    private final ProductImageService imageService;

    public ProductImageController(ProductImageService imageService) {
        this.imageService = imageService;
    }

    @PostMapping("/{id}/image/presign")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse presign(@PathVariable String id,
                                @RequestBody @Valid PresignImageRequest request) {
        return BaseResponse.ok(imageService.presign(id, request));
    }

    @PutMapping("/{id}/image")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse attach(@PathVariable String id,
                               @RequestBody @Valid AttachImageRequest request) {
        return BaseResponse.ok(imageService.attach(id, request));
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd product-service && mvn -q -Dtest=ProductImageControllerTest test
```
Expected: `Tests run: 2, Failures: 0`.

- [ ] **Step 5: Run the full product-service test suite**

Run:
```bash
cd product-service && mvn -q test
```
Expected: all tests pass; `contextLoads` continues to work.

- [ ] **Step 6: Commit**

```bash
git add product-service/src/main/java/org/aibles/ecommerce/product_service/controller/ProductImageController.java \
        product-service/src/test/java/org/aibles/ecommerce/product_service/controller/ProductImageControllerTest.java
git commit -m "feat(product-service): expose product image presign/attach endpoints"
```

---

## Task 12: authorization-server — `avatar_url` column + entity update

**Files:**
- Modify: `authorization-server/pom.xml`
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/entity/User.java`
- Modify: `authorization-server/src/main/resources/application.yml`
- Modify: `docker/ecommerce.sql`
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/entity/UserAvatarUrlTest.java`

- [ ] **Step 1: Apply the column to the live dev database**

The seed runs only on first install (it skips when `account` is populated). For an already-seeded local DB, apply the ALTER directly:

```bash
docker exec -i mysql-master mysql -uroot -p"${MYSQL_MASTER_PASSWORD:-masterpassword}" ecommerce_dev \
    -e "ALTER TABLE \`user\` ADD COLUMN avatar_url VARCHAR(512) NULL;"
```

Expected: no output, exit 0. (If the column already exists you'll get `Duplicate column`; that's fine — re-running this plan is safe.)

- [ ] **Step 2: Add the ALTER to `docker/ecommerce.sql` for fresh installs**

Open `docker/ecommerce.sql`, find the `CREATE TABLE \`user\`` block, and add `avatar_url VARCHAR(512) NULL,` to the column list immediately before the `PRIMARY KEY` declaration. (Read the file first to find the exact insertion point — the column list is short.)

- [ ] **Step 3: Write the failing test**

```java
package org.aibles.ecommerce.authorization_server.entity;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class UserAvatarUrlTest {

    @Test
    void userHasNullableAvatarUrl() {
        User u = new User();
        u.setAvatarUrl("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        assertThat(u.getAvatarUrl()).isEqualTo("http://localhost:9000/ecommerce-media/avatars/u1/x.png");

        User noAvatar = new User();
        assertThat(noAvatar.getAvatarUrl()).isNull();
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run:
```bash
cd authorization-server && mvn -q -Dtest=UserAvatarUrlTest test
```
Expected: compilation error — `avatarUrl` does not exist on `User`.

- [ ] **Step 5: Add `avatarUrl` to `User` entity**

Edit `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/entity/User.java`. Add after `address`:

```java
    @Column(name = "avatar_url", length = 512)
    private String avatarUrl;
```

- [ ] **Step 6: Add `core-s3` Maven dependency**

Edit `authorization-server/pom.xml`. Add to `<dependencies>`:

```xml
        <dependency>
            <groupId>org.aibles.ecommerce</groupId>
            <artifactId>core-s3</artifactId>
            <version>0.0.1</version>
        </dependency>
```

- [ ] **Step 7: Add `secret/core-s3` to Vault import contexts**

Edit `authorization-server/src/main/resources/application.yml` — add `additional-contexts: core-s3` under the existing `kv:` block, mirroring the change made in product-service Task 9 Step 6. Read the existing file first to preserve indentation and any other `kv:` keys.

- [ ] **Step 8: Run the test to verify it passes**

Run:
```bash
cd core/core-s3 && mvn -q clean install -DskipTests
cd ../../authorization-server && mvn -q -Dtest=UserAvatarUrlTest test
```
Expected: `Tests run: 1, Failures: 0`.

- [ ] **Step 9: Commit**

```bash
git add authorization-server/pom.xml \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/entity/User.java \
        authorization-server/src/main/resources/application.yml \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/entity/UserAvatarUrlTest.java \
        docker/ecommerce.sql
git commit -m "feat(authorization-server): add avatar_url column and wire core-s3"
```

---

## Task 13: authorization-server — `UserAvatarService` + presign/attach logic

**Files:**
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/UserAvatarService.java`
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/UserAvatarServiceImpl.java`
- Modify: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java` (or whichever `@Configuration` wires user-side beans)
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/UserAvatarServiceImplTest.java`

> **Note for the implementer:** before writing `UserAvatarServiceImpl`, read the existing `UserService` / `UserServiceImpl` to find the user repository class name (likely `UserRepository`) and any existing `User -> UserResponse` mapper. Use the same patterns.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.repository.UserRepository;
import org.aibles.ecommerce.authorization_server.service.impl.UserAvatarServiceImpl;
import org.aibles.ecommerce.common_dto.exception.*;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class UserAvatarServiceImplTest {

    private UserRepository userRepo;
    private S3StorageService storage;
    private S3Properties props;
    private UserAvatarService service;

    @BeforeEach
    void setUp() {
        userRepo = mock(UserRepository.class);
        storage = mock(S3StorageService.class);
        props = new S3Properties();
        props.setMaxUploadSize(5L * 1024 * 1024);
        props.setAllowedTypes(List.of("image/jpeg", "image/png", "image/webp"));
        props.setPresignTtl(Duration.ofMinutes(5));
        props.setPublicBaseUrl("http://localhost:9000/ecommerce-media");
        service = new UserAvatarServiceImpl(userRepo, storage, props);
    }

    @Test
    void presignReturnsAvatarScopedKey() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.presignUpload(anyString(), eq("image/png")))
            .thenAnswer(inv -> new PresignedUpload("http://signed", inv.getArgument(0), Instant.now().plusSeconds(300)));

        PresignedUploadResponse resp = service.presign("u1", new PresignImageRequest("image/png", 1024L));

        assertThat(resp.getObjectKey()).startsWith("avatars/u1/");
        assertThat(resp.getObjectKey()).endsWith(".png");
    }

    @Test
    void presignRejectsUnsupportedType() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.presign("u1", new PresignImageRequest("application/pdf", 100L)))
            .isInstanceOf(ImageTypeNotAllowedException.class);
    }

    @Test
    void presignRejectsOversize() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.presign("u1", new PresignImageRequest("image/jpeg", 10L * 1024 * 1024)))
            .isInstanceOf(ImageTooLargeException.class);
    }

    @Test
    void attachRejectsKeyForOtherUser() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.attach("u1", new AttachImageRequest("avatars/u2/x.png")))
            .isInstanceOf(ImageKeyForbiddenException.class);
    }

    @Test
    void attachRejectsWhenObjectMissing() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.objectExists("avatars/u1/x.png")).thenReturn(false);
        assertThatThrownBy(() -> service.attach("u1", new AttachImageRequest("avatars/u1/x.png")))
            .isInstanceOf(ImageNotUploadedException.class);
    }

    @Test
    void attachPersistsAvatarUrl() {
        User u = new User();
        u.setId("u1");
        when(userRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.objectExists("avatars/u1/x.png")).thenReturn(true);
        when(storage.publicUrl("avatars/u1/x.png"))
            .thenReturn("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        when(userRepo.save(any())).thenAnswer(inv -> inv.getArgument(0));

        service.attach("u1", new AttachImageRequest("avatars/u1/x.png"));

        assertThat(u.getAvatarUrl()).isEqualTo("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd authorization-server && mvn -q -Dtest=UserAvatarServiceImplTest test
```
Expected: compilation error — service classes do not exist.

- [ ] **Step 3: Create `UserAvatarService` interface**

```java
package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;

public interface UserAvatarService {
    PresignedUploadResponse presign(String userId, PresignImageRequest request);
    User attach(String userId, AttachImageRequest request);
}
```

- [ ] **Step 4: Create `UserAvatarServiceImpl`**

```java
package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.repository.UserRepository;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.common_dto.exception.*;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;

import java.util.UUID;

@Slf4j
@RequiredArgsConstructor
public class UserAvatarServiceImpl implements UserAvatarService {

    private final UserRepository userRepository;
    private final S3StorageService storage;
    private final S3Properties props;

    @Override
    public PresignedUploadResponse presign(String userId, PresignImageRequest request) {
        userRepository.findById(userId).orElseThrow(NotFoundException::new);
        validate(request);
        String ext = extensionFor(request.getContentType());
        String key = "avatars/" + userId + "/" + UUID.randomUUID() + "." + ext;
        PresignedUpload signed = storage.presignUpload(key, request.getContentType());
        return new PresignedUploadResponse(signed.uploadUrl(), signed.objectKey(), signed.expiresAt());
    }

    @Override
    public User attach(String userId, AttachImageRequest request) {
        User user = userRepository.findById(userId).orElseThrow(NotFoundException::new);
        String prefix = "avatars/" + userId + "/";
        if (!request.getObjectKey().startsWith(prefix)) {
            throw new ImageKeyForbiddenException();
        }
        if (!storage.objectExists(request.getObjectKey())) {
            throw new ImageNotUploadedException();
        }
        user.setAvatarUrl(storage.publicUrl(request.getObjectKey()));
        return userRepository.save(user);
    }

    private void validate(PresignImageRequest req) {
        if (!props.getAllowedTypes().contains(req.getContentType())) {
            throw new ImageTypeNotAllowedException();
        }
        if (req.getSizeBytes() > props.getMaxUploadSize()) {
            throw new ImageTooLargeException();
        }
    }

    private static String extensionFor(String contentType) {
        return switch (contentType) {
            case "image/jpeg" -> "jpg";
            case "image/png" -> "png";
            case "image/webp" -> "webp";
            default -> throw new ImageTypeNotAllowedException();
        };
    }
}
```

> **Note:** if `UserRepository`'s actual class name or method differs (e.g. `findByEmail`, custom finder names), adapt the calls. Read `UserService`/`UserServiceImpl` first.

- [ ] **Step 5: Wire bean and `@EnableCoreS3` in the user-side configuration**

Open `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java` (or the configuration class that wires `UserService` — read it first). Add `@EnableCoreS3` to the class annotations and add a `@Bean` method:

```java
    @Bean
    public UserAvatarService userAvatarService(UserRepository userRepository,
                                               S3StorageService storage,
                                               S3Properties props) {
        return new UserAvatarServiceImpl(userRepository, storage, props);
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
cd authorization-server && mvn -q -Dtest=UserAvatarServiceImplTest test
```
Expected: `Tests run: 6, Failures: 0`.

- [ ] **Step 7: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/UserAvatarService.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/service/impl/UserAvatarServiceImpl.java \
        authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/configuration/AuthorizationServerConfiguration.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/service/UserAvatarServiceImplTest.java
git commit -m "feat(authorization-server): add UserAvatarService presign/attach logic"
```

---

## Task 14: authorization-server — `UserAvatarController`

**Files:**
- Create: `authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/controller/UserAvatarController.java`
- Test: `authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/controller/UserAvatarControllerTest.java`

The controller follows the existing `UserController` pattern: it reads the caller's user id from `SecurityUtil.getUserId()` and exposes paths under `/v1/users/self/...`.

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.ecommerce.authorization_server.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.authorization_server.util.SecurityUtil;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.MockedStatic;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = UserAvatarController.class)
class UserAvatarControllerTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private ObjectMapper mapper;

    @MockBean
    private UserAvatarService avatarService;

    private MockedStatic<SecurityUtil> securityUtilMock;

    @AfterEach
    void tearDown() {
        if (securityUtilMock != null) securityUtilMock.close();
    }

    @Test
    void presignReturnsSignedUrl() throws Exception {
        securityUtilMock = mockStatic(SecurityUtil.class);
        securityUtilMock.when(SecurityUtil::getUserId).thenReturn("u1");
        when(avatarService.presign(eq("u1"), any(PresignImageRequest.class)))
            .thenReturn(new PresignedUploadResponse(
                "http://signed", "avatars/u1/x.png",
                Instant.parse("2026-04-27T00:00:00Z")));

        mvc.perform(post("/v1/users/self/avatar/presign")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"contentType\":\"image/png\",\"sizeBytes\":1024}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.uploadUrl").value("http://signed"))
            .andExpect(jsonPath("$.data.objectKey").value("avatars/u1/x.png"));
    }

    @Test
    void attachReturnsUpdatedUser() throws Exception {
        securityUtilMock = mockStatic(SecurityUtil.class);
        securityUtilMock.when(SecurityUtil::getUserId).thenReturn("u1");
        User u = new User();
        u.setId("u1");
        u.setAvatarUrl("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        when(avatarService.attach(eq("u1"), any(AttachImageRequest.class))).thenReturn(u);

        mvc.perform(put("/v1/users/self/avatar")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"objectKey\":\"avatars/u1/x.png\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.avatarUrl")
                .value("http://localhost:9000/ecommerce-media/avatars/u1/x.png"));
    }
}
```

> **Note:** If the existing `UserController` test exposes a different `User`-to-response mapping (e.g. wraps the entity in a `UserResponse` DTO), match that. Read the existing UserController test first; if `UserResponse` exists, change the controller and test to use it.

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd authorization-server && mvn -q -Dtest=UserAvatarControllerTest test
```
Expected: compilation error — `UserAvatarController` does not exist.

- [ ] **Step 3: Create `UserAvatarController`**

```java
package org.aibles.ecommerce.authorization_server.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.authorization_server.util.SecurityUtil;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1/users/self/avatar")
public class UserAvatarController {

    private final UserAvatarService avatarService;

    public UserAvatarController(UserAvatarService avatarService) {
        this.avatarService = avatarService;
    }

    @PostMapping("/presign")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse presign(@RequestBody @Valid PresignImageRequest request) {
        return BaseResponse.ok(avatarService.presign(SecurityUtil.getUserId(), request));
    }

    @PutMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse attach(@RequestBody @Valid AttachImageRequest request) {
        return BaseResponse.ok(avatarService.attach(SecurityUtil.getUserId(), request));
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd authorization-server && mvn -q -Dtest=UserAvatarControllerTest test
```
Expected: `Tests run: 2, Failures: 0`.

- [ ] **Step 5: Run the full authorization-server test suite**

Run:
```bash
cd authorization-server && mvn -q test
```
Expected: all tests pass; `contextLoads` continues to work without MinIO.

- [ ] **Step 6: Commit**

```bash
git add authorization-server/src/main/java/org/aibles/ecommerce/authorization_server/controller/UserAvatarController.java \
        authorization-server/src/test/java/org/aibles/ecommerce/authorization_server/controller/UserAvatarControllerTest.java
git commit -m "feat(authorization-server): expose user avatar presign/attach endpoints"
```

---

## Task 15: End-to-end smoke test (manual)

This is a manual verification step — no code change. Document a green run before committing the docs update.

- [ ] **Step 1: Bring everything up**

Run:
```bash
make build
make up
```
Expected: all services start; `make status` shows green.

- [ ] **Step 2: Sign and upload a product image**

Replace `<JWT>` with an admin token from `authorization-server`'s login flow.

```bash
PRESIGN=$(curl -s -X POST http://localhost:8080/product-service/v1/products/<productId>/image/presign \
    -H "Authorization: Bearer <JWT>" \
    -H "Content-Type: application/json" \
    -d '{"contentType":"image/jpeg","sizeBytes":12345}')
echo "$PRESIGN" | jq .

UPLOAD_URL=$(echo "$PRESIGN" | jq -r '.data.uploadUrl')
KEY=$(echo "$PRESIGN" | jq -r '.data.objectKey')

# Upload bytes directly to MinIO
curl -fsS -X PUT "$UPLOAD_URL" -H "Content-Type: image/jpeg" --data-binary @./some-image.jpg

# Attach
curl -fsS -X PUT http://localhost:8080/product-service/v1/products/<productId>/image \
    -H "Authorization: Bearer <JWT>" \
    -H "Content-Type: application/json" \
    -d "{\"objectKey\":\"$KEY\"}" | jq .data.imageUrl
```
Expected: the final `jq` prints a URL like `http://localhost:9000/ecommerce-media/products/<productId>/<uuid>.jpg`. Open that URL in a browser — image renders.

- [ ] **Step 3: Sign and upload an avatar**

```bash
PRESIGN=$(curl -s -X POST http://localhost:8080/authorization-server/v1/users/self/avatar/presign \
    -H "Authorization: Bearer <JWT>" \
    -H "Content-Type: application/json" \
    -d '{"contentType":"image/png","sizeBytes":2048}')
UPLOAD_URL=$(echo "$PRESIGN" | jq -r '.data.uploadUrl')
KEY=$(echo "$PRESIGN" | jq -r '.data.objectKey')

curl -fsS -X PUT "$UPLOAD_URL" -H "Content-Type: image/png" --data-binary @./avatar.png

curl -fsS -X PUT http://localhost:8080/authorization-server/v1/users/self/avatar \
    -H "Authorization: Bearer <JWT>" \
    -H "Content-Type: application/json" \
    -d "{\"objectKey\":\"$KEY\"}" | jq .data.avatarUrl
```
Expected: prints a URL under `avatars/<userId>/...`; URL is publicly viewable.

- [ ] **Step 4: Verify rejection paths**

```bash
# Wrong content-type
curl -s -X POST http://localhost:8080/product-service/v1/products/<productId>/image/presign \
    -H "Authorization: Bearer <JWT>" -H "Content-Type: application/json" \
    -d '{"contentType":"application/pdf","sizeBytes":100}' | jq .status
# Expected: 400

# Oversize
curl -s -X POST http://localhost:8080/product-service/v1/products/<productId>/image/presign \
    -H "Authorization: Bearer <JWT>" -H "Content-Type: application/json" \
    -d '{"contentType":"image/jpeg","sizeBytes":100000000}' | jq .status
# Expected: 400

# Foreign-prefix attach
curl -s -X PUT http://localhost:8080/product-service/v1/products/<productId>/image \
    -H "Authorization: Bearer <JWT>" -H "Content-Type: application/json" \
    -d '{"objectKey":"products/SOMEONE_ELSE/x.jpg"}' | jq .status
# Expected: 403
```

- [ ] **Step 5: Note any deviations** in the conversation; do not commit anything in this task.

---

## Task 16: Documentation update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add `core-s3` to the Core Modules list**

Find the `### Core Modules (in /core)` block in `CLAUDE.md` and add a bullet:

```markdown
- **core-s3**: S3-compatible object storage (presigned uploads, MinIO local / AWS S3 prod)
```

- [ ] **Step 2: Add MinIO to Service Ports**

Find the `### Service Ports` table and add two rows:

```markdown
| MinIO S3 API | 9000 |
| MinIO Console | 9001 |
```

- [ ] **Step 3: Add an Image Storage section under Code Conventions**

Append to `## Code Conventions (non-obvious)`:

```markdown
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
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document core-s3 image storage in CLAUDE.md"
```

---

## Self-review checklist (run before declaring complete)

- [ ] All 16 tasks committed in order
- [ ] `make build` succeeds end-to-end
- [ ] `mvn test` passes in `core/core-s3`, `core/common-dto`, `product-service`, `authorization-server`
- [ ] `make up` brings MinIO up and `curl http://localhost:9000/minio/health/live` returns 200
- [ ] Manual smoke test (Task 15) passes for both product image and avatar
- [ ] Public URLs in DB are reachable in a browser (anonymous read works)
- [ ] No new fields surfaced through gateway routes — verify Swagger UI lists the four new endpoints
- [ ] `CLAUDE.md` updated and committed
