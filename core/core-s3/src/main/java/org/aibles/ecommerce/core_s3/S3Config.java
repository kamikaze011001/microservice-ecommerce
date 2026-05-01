package org.aibles.ecommerce.core_s3;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
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
        var b = S3Client.builder()
            .region(Region.of(props.getRegion()))
            .credentialsProvider(credentials(props))
            .serviceConfiguration(serviceConfig(props));
        if (hasEndpoint(props)) {
            b.endpointOverride(URI.create(props.getEndpoint()));
        }
        return b.build();
    }

    @Bean
    public S3Presigner s3Presigner(S3Properties props) {
        var b = S3Presigner.builder()
            .region(Region.of(props.getRegion()))
            .credentialsProvider(credentials(props))
            .serviceConfiguration(serviceConfig(props));
        if (hasEndpoint(props)) {
            b.endpointOverride(URI.create(props.getEndpoint()));
        }
        return b.build();
    }

    @Bean
    public S3StorageService s3StorageService(S3Client client, S3Presigner presigner, S3Properties props) {
        return new S3StorageServiceImpl(client, presigner, props);
    }

    private static AwsCredentialsProvider credentials(S3Properties props) {
        return StaticCredentialsProvider.create(
            AwsBasicCredentials.create(props.getAccessKey(), props.getSecretKey()));
    }

    private static S3Configuration serviceConfig(S3Properties props) {
        return S3Configuration.builder()
            .pathStyleAccessEnabled(props.isPathStyle())
            .build();
    }

    private static boolean hasEndpoint(S3Properties props) {
        return props.getEndpoint() != null && !props.getEndpoint().isBlank();
    }
}
