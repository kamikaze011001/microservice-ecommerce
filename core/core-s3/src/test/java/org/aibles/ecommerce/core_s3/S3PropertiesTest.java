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
