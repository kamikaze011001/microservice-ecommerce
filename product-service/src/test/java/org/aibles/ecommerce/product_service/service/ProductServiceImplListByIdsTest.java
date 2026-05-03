package org.aibles.ecommerce.product_service.service;

import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.impl.ProductServiceImpl;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.context.ApplicationEventPublisher;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductServiceImplListByIdsTest {

    @Mock private ProductRepository productRepository;
    @Mock private ProductQuantityHistoryRepo productQuantityHistoryRepo;
    @Mock private ApplicationEventPublisher publisher;

    @Test
    void listByIds_returnsMatchingProductsOnly() {
        ProductServiceImpl service = new ProductServiceImpl(productRepository, productQuantityHistoryRepo, publisher);
        Product p1 = new Product();
        p1.setId("p1"); p1.setName("Issue Nº01"); p1.setPrice(25.0); p1.setImageUrl("http://img/p1.png");
        Product p2 = new Product();
        p2.setId("p2"); p2.setName("Issue Nº02"); p2.setPrice(30.0); p2.setImageUrl("http://img/p2.png");
        when(productRepository.findAllByIdIn(Set.of("p1", "p2"))).thenReturn(List.of(p1, p2));
        when(productQuantityHistoryRepo.getQuantitySumByProductId("p1")).thenReturn(5L);
        when(productQuantityHistoryRepo.getQuantitySumByProductId("p2")).thenReturn(0L);

        List<ProductResponse> result = service.listByIds(Set.of("p1", "p2"));

        assertThat(result).hasSize(2);
        assertThat(result).extracting(ProductResponse::getId).containsExactlyInAnyOrder("p1", "p2");
    }

    @Test
    void listByIds_emptyInput_returnsEmpty() {
        ProductServiceImpl service = new ProductServiceImpl(productRepository, productQuantityHistoryRepo, publisher);
        assertThat(service.listByIds(Set.of())).isEmpty();
    }
}
