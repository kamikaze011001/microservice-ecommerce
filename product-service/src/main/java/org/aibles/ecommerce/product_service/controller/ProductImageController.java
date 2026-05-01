package org.aibles.ecommerce.product_service.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.product_service.service.ProductImageService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

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
