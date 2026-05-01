package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;

public interface ProductImageService {

    PresignedUploadResponse presign(String productId, PresignImageRequest request);

    ProductResponse attach(String productId, AttachImageRequest request);
}
