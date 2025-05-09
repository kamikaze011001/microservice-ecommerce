package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.ProductQuantityHistory;
import org.springframework.data.mongodb.repository.Aggregation;
import org.springframework.data.mongodb.repository.MongoRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface ProductQuantityHistoryRepo extends MongoRepository<ProductQuantityHistory, String> {

    @Aggregation(pipeline = {
            "{ $match: { productId: ?0 } }",
            "{ $group: { _id: '$productId', totalQuantity: { $sum: '$quantity' } } }"
    })
    Long getQuantitySumByProductId(String productId);
}
