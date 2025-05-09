package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.repository.MongoRepository;

public interface ProductRepository extends MongoRepository<Product, String>, ProductRepositoryCustom {
}
