package org.aibles.ecommerce.core_s3;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.PresignedPutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;

@Slf4j
@RequiredArgsConstructor
public class S3StorageServiceImpl implements S3StorageService {

    private final S3Client client;
    private final S3Presigner presigner;
    private final S3Properties props;

    @Override
    public PresignedUpload presignUpload(String objectKey, String contentType) {
        log.info("(presignUpload)objectKey: {}, contentType: {}", objectKey, contentType);
        PutObjectRequest putObjectRequest = PutObjectRequest.builder()
                .bucket(props.getBucket())
                .key(objectKey)
                .contentType(contentType)
                .build();

        PutObjectPresignRequest putObjectPresignRequest = PutObjectPresignRequest.builder()
                .putObjectRequest(putObjectRequest)
                .signatureDuration(props.getPresignTtl())
                .build();

        PresignedPutObjectRequest presignedPutObjectRequest = presigner.presignPutObject(putObjectPresignRequest);

        return new PresignedUpload(
                presignedPutObjectRequest.url().toString(), objectKey, presignedPutObjectRequest.expiration()
        );
    }

    @Override
    public boolean objectExists(String objectKey) {
        log.debug("(objectExists)objectKey: {}", objectKey);
        try {
            client.headObject(HeadObjectRequest.builder()
                    .bucket(props.getBucket())
                    .key(objectKey)
                    .build());
        } catch (NoSuchKeyException e) {
            log.warn("(objectExists)key is not exists");
            return false;
        } catch (S3Exception e) {
            if (e.statusCode() == 404) return false;
            throw e;
        }

        return true;
    }

    @Override
    public String publicUrl(String objectKey) {
        log.debug("(publicUrl)objectKey: {}", objectKey);
        return props.getPublicBaseUrl().replaceAll("/+$", "") + "/" + objectKey;
    }
}
