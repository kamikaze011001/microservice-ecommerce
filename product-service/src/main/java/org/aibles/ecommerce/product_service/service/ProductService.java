package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;

public interface ProductService {

    ProductResponse create(ProductRequest productRequest);

    ProductResponse get(String id);

    void update(String id, ProductRequest productRequest);

    PagingResponse list(Integer page, Integer size);
}
