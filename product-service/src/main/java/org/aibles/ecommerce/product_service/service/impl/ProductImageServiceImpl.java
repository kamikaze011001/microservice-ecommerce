package org.aibles.ecommerce.product_service.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.exception.ImageKeyForbiddenException;
import org.aibles.ecommerce.common_dto.exception.ImageNotUploadedException;
import org.aibles.ecommerce.common_dto.exception.ImageTooLargeException;
import org.aibles.ecommerce.common_dto.exception.ImageTypeNotAllowedException;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
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
import org.springframework.context.ApplicationEventPublisher;

import java.util.UUID;

@Slf4j
@RequiredArgsConstructor
public class ProductImageServiceImpl implements ProductImageService {

    private final ProductRepository productRepository;
    private final S3StorageService storage;
    private final S3Properties props;
    private final ApplicationEventPublisher applicationEventPublisher;

    @Override
    public PresignedUploadResponse presign(String productId, PresignImageRequest request) {
        log.info("(presign)productId: {}, contentType: {}", productId, request.getContentType());
        Product product = productRepository.findById(productId).orElseThrow(NotFoundException::new);
        validate(request);
        String ext = extensionFor(request.getContentType());
        String key = "products/" + product.getId() + "/" + UUID.randomUUID() + "." + ext;
        PresignedUpload signed = storage.presignUpload(key, request.getContentType());
        return new PresignedUploadResponse(signed.uploadUrl(), signed.objectKey(), signed.expiresAt());
    }

    @Override
    public ProductResponse attach(String productId, AttachImageRequest request) {
        log.info("(attach)productId: {}, objectKey: {}", productId, request.getObjectKey());
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

        ProductUpdate productUpdate = ProductUpdate.newBuilder()
                .setId(saved.getId())
                .setName(saved.getName())
                .setPrice(saved.getPrice())
                .setImageUrl(saved.getImageUrl())
                .build();
        applicationEventPublisher.publishEvent(
                new MongoSavedEvent(this, EcommerceEvent.PRODUCT_UPDATE.getValue(), productUpdate));

        return ProductResponse.from(saved, 0);
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
