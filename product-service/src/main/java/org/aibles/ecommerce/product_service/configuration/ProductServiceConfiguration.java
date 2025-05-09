package org.aibles.ecommerce.product_service.configuration;

import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.ProductService;
import org.aibles.ecommerce.product_service.service.impl.ProductServiceImpl;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableMongoAuditing
@EnableAsync
public class ProductServiceConfiguration {

    @Bean
    public ProductService productService(ProductRepository productRepository,
                                         ProductQuantityHistoryRepo productQuantityHistoryRepo,
                                         ApplicationEventPublisher applicationEventPublisher) {
        return new ProductServiceImpl(productRepository, productQuantityHistoryRepo, applicationEventPublisher);
    }
}
