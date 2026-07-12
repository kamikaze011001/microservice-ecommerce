package org.aibles.ecommerce.product_service.dto;

import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ProductResponseMappingTest {

    @Test
    void from_carriesDescriptionAndTags() {
        Product product = Product.builder()
                .id("67c000000000000000000002")
                .name("Broadsheet Plaid Shirt")
                .price(62.0)
                .category("apparel")
                .attributes(Map.of("color", "Red"))
                .imageUrl("http://localhost:9000/x.jpg")
                .description("A brushed cotton plaid cut for layering.")
                .tags(List.of("shirt", "cotton", "plaid"))
                .build();

        ProductResponse response = ProductResponse.from(product, 18L);

        assertThat(response.getDescription()).isEqualTo("A brushed cotton plaid cut for layering.");
        assertThat(response.getTags()).containsExactly("shirt", "cotton", "plaid");
        assertThat(response.getQuantity()).isEqualTo(18L);
    }
}
