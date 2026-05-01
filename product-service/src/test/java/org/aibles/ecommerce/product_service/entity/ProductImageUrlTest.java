package org.aibles.ecommerce.product_service.entity;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ProductImageUrlTest {

    @Test
    void productHasNullableImageUrl() {
        Product p = Product.builder()
            .id("abc")
            .name("Test")
            .price(9.99)
            .imageUrl("http://localhost:9000/ecommerce-media/products/abc/x.jpg")
            .build();
        assertThat(p.getImageUrl()).isEqualTo("http://localhost:9000/ecommerce-media/products/abc/x.jpg");

        Product noImage = Product.builder().id("xyz").build();
        assertThat(noImage.getImageUrl()).isNull();
    }
}
