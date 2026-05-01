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
