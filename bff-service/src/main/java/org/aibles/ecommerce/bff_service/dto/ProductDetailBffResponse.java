package org.aibles.ecommerce.bff_service.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductDetailBffResponse {

    private String id;
    private String name;
    private Double price;
    private String category;
    private Map<String, Object> attributes;
    private long stockQuantity;
    private boolean inStock;
}
