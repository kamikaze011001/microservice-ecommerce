package org.aibles.ecommerce.product_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.EqualsAndHashCode;
import lombok.NoArgsConstructor;
import lombok.experimental.SuperBuilder;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.entity.Product;

import java.util.Map;

@Data
@AllArgsConstructor
@NoArgsConstructor
@SuperBuilder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductResponse {

    private String id;

    private String name;

    private Double price;

    private Map<String, Object> attributes;

    private long quantity;

    public static ProductResponse from(final Product product, final long quantity) {
        return ProductResponse.builder()
                .id(product.getId())
                .name(product.getName())
                .price(product.getPrice())
                .quantity(quantity)
                .attributes(product.getAttributes())
                .build();
    }
}
