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
     */
    private String publicBaseUrl;

    /** TTL for presigned upload URLs. */
    private Duration presignTtl = Duration.ofMinutes(5);

    /** Maximum upload size in bytes. */
    private long maxUploadSize = 5L * 1024 * 1024;

    /** Allowed Content-Type values for uploads. */
    private List<String> allowedTypes = List.of("image/jpeg", "image/png", "image/webp");
}
