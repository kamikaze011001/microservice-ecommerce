package org.aibles.ecommerce.product_service.repository;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Query;
import org.springframework.stereotype.Repository;

import java.util.List;

@Slf4j
@Repository
public class ProductRepositoryCustomImpl implements ProductRepositoryCustom {

    private final MongoTemplate mongoTemplate;

    public ProductRepositoryCustomImpl(MongoTemplate mongoTemplate) {
        this.mongoTemplate = mongoTemplate;
    }

    @Override
    public List<Product> list(Integer page, Integer size) {
        log.info("(list)page : {}, size : {}", page, size);
        Query query = new Query();
        query.skip((long) page * size);
        query.limit(size);

        return mongoTemplate.find(query, Product.class);
    }

    @Override
    public long total() {
        return mongoTemplate.count(new Query(), Product.class);
    }
}
