package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.repository.MongoRepository;

import java.util.Collection;
import java.util.List;

public interface ProductRepository extends MongoRepository<Product, String>, ProductRepositoryCustom {

    List<Product> findAllByIdIn(Collection<String> ids);
}
