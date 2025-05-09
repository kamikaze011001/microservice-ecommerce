package org.aibles.ecommerce.product_service.entity;

import lombok.Builder;
import lombok.Data;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

import java.time.LocalDateTime;

@Data
@Document
@Builder
public class ProductQuantityHistory {

    @Id
    private String id;

    @Indexed(name = "productId_index")
    private String productId;

    private long quantity;

    @CreatedDate
    private LocalDateTime createdAt;
}
