package org.aibles.ecommerce.product_service.controller;

import org.aibles.ecommerce.common_dto.request.PagingRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.service.ProductService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/products")
public class ProductController {

    private final ProductService productService;

    public ProductController(ProductService productService) {
        this.productService = productService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public BaseResponse create(@RequestBody ProductRequest request) {
        ProductResponse response = productService.create(request);
        return BaseResponse.created(response);
    }

    @GetMapping("/{id}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getById(@PathVariable String id) {
        ProductResponse response = productService.get(id);
        return BaseResponse.ok(response);
    }

    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse list(final PagingRequest pagingRequest) {
        PagingResponse response = productService.list(pagingRequest.getPage(), pagingRequest.getSize());
        return BaseResponse.ok(response);
    }

    @PutMapping("/{id}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse update(@PathVariable String id, @RequestBody ProductRequest request) {
        productService.update(id, request);
        return BaseResponse.ok();
    }
}
