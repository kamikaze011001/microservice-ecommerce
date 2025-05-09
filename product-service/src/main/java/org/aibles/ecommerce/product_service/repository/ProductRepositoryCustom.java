package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;

import java.util.List;

public interface ProductRepositoryCustom {

    List<Product> list(Integer page, Integer size);

    long total();
}
