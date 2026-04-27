package org.aibles.ecommerce.core_s3;

import org.junit.jupiter.api.Test;
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
