package org.aibles.ecommerce.product_service.repository;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.product_service.entity.Product;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
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
    public List<Product> list(Integer page, Integer size, String keyword, String category) {
        log.info("(list) page: {}, size: {}, keyword: {}, category: {}", page, size, keyword, category);
        Query query = new Query(buildCriteria(keyword, category));
        query.skip((long) page * size);
        query.limit(size);
        return mongoTemplate.find(query, Product.class);
    }

    @Override
    public long total(String category, String keyword) {
        return mongoTemplate.count(new Query(buildCriteria(keyword, category)), Product.class);
    }

    /**
     * TODO (you): build a MongoDB Criteria that combines:
     *   - keyword: case-insensitive substring match on the `name` field, ONLY if keyword is non-blank
     *   - category: exact match on the `category` field, ONLY if category is non-blank
     *
     * Hints:
     *   - Start with `Criteria criteria = new Criteria();` (empty = match everything)
     *   - For keyword: `criteria = criteria.and("name").regex(keyword, "i");`
     *     The "i" flag makes it case-insensitive. The pattern is a substring match
     *     because Mongo regex matches anywhere unless anchored with ^ / $.
     *   - For category: `criteria = criteria.and("category").is(category);`
     *   - Skip each block with `if (value != null && !value.isBlank())`.
     *
     * Why both filters in one method instead of two? Because Mongo's Criteria is
     * fluent — chaining `.and("field")` mutates the same Criteria object, and the
     * resulting Query gets the AND of all conditions. Splitting into two methods
     * would force you to merge two Criteria objects which is awkward.
     *
     * Watch out: if you do `criteria.and("name")` twice on the same Criteria, you
     * get an IllegalStateException. So a single guarded chain is the right shape.
     */
    private Criteria buildCriteria(String keyword, String category) {
        Criteria criteria = new Criteria();

        if (keyword != null && !keyword.isBlank()) {
            criteria = criteria.and("name").regex(keyword, "i");
        }

        if (category != null && !category.isBlank()) {
            criteria = criteria.and("category").is(category);
        }

        return criteria;
    }
}
