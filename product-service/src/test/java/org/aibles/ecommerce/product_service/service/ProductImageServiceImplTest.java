package org.aibles.ecommerce.product_service.service;

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
import org.aibles.ecommerce.product_service.service.impl.ProductImageServiceImpl;
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
        Product p = Product.builder().id("abc").build();
        when(productRepo.findById("abc")).thenReturn(Optional.of(p));
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
