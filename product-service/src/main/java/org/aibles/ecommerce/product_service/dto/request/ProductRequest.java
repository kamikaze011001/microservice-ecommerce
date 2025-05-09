package org.aibles.ecommerce.product_service.dto.request;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import lombok.experimental.SuperBuilder;
import org.aibles.ecommerce.product_service.entity.Product;

import java.util.Map;

@Data
@AllArgsConstructor
@NoArgsConstructor
@SuperBuilder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductRequest {

    @NotBlank
    private String name;

    @NotNull
    private Double price;

    @Size(min = 1)
    private Map<String, Object> attributes;

    public static Product to(final ProductRequest productRequest) {
        return Product.builder()
                .name(productRequest.name)
                .price(productRequest.price)
                .attributes(productRequest.attributes)
                .build();
    }
}
