package org.aibles.ecommerce.product_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.product_service.dto.request.ProductRequest;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.entity.Product;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.aibles.ecommerce.product_service.repository.ProductRepository;
import org.aibles.ecommerce.product_service.service.ProductService;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
public class ProductServiceImpl implements ProductService {

    private final ProductRepository productRepository;

    private final ProductQuantityHistoryRepo productQuantityHistoryRepo;

    private final ApplicationEventPublisher applicationEventPublisher;

    public ProductServiceImpl(ProductRepository productRepository, ProductQuantityHistoryRepo productQuantityHistoryRepo, ApplicationEventPublisher applicationEventPublisher) {
        this.productRepository = productRepository;
        this.productQuantityHistoryRepo = productQuantityHistoryRepo;
        this.applicationEventPublisher = applicationEventPublisher;
    }

    @Override
    @Transactional
    public ProductResponse create(ProductRequest productRequest) {
        log.info("(create)request: {}", productRequest);
        Product product = ProductRequest.to(productRequest);
        product = productRepository.save(product);
        ProductUpdate productUpdate = ProductUpdate.newBuilder()
                .setId(product.getId())
                .setName(product.getName())
                .setPrice(product.getPrice())
                .build();

        MongoSavedEvent event = new MongoSavedEvent(this, EcommerceEvent.PRODUCT_UPDATE.getValue(), productUpdate);
        applicationEventPublisher.publishEvent(event);
        return ProductResponse.from(product, 0);
    }

    @Override
    @Transactional(readOnly = true)
    public ProductResponse get(String id) {
        log.info("(get)id: {}", id);
        Product product = productRepository.findById(id).orElseThrow(
                NotFoundException::new
        );

        long quantitySum = productQuantityHistoryRepo.getQuantitySumByProductId(product.getId());
        return ProductResponse.from(product, quantitySum);
    }

    @Override
    @Transactional
    public void update(String id, ProductRequest productRequest) {
        log.info("(update)id: {}", id);
        Product product = productRepository.findById(id).orElseThrow(
                NotFoundException::new
        );
        product.setName(productRequest.getName());
        product.setPrice(productRequest.getPrice());
        product.setAttributes(productRequest.getAttributes());
        ProductUpdate productUpdate = ProductUpdate.newBuilder()
                .setId(product.getId())
                .setName(product.getName())
                .setPrice(product.getPrice())
                .build();

        MongoSavedEvent event = new MongoSavedEvent(this,
                EcommerceEvent.PRODUCT_UPDATE.getValue(),
                productUpdate);
        applicationEventPublisher.publishEvent(event);
        productRepository.save(product);
    }

    @Override
    @Transactional(readOnly = true)
    public PagingResponse list(Integer page, Integer size) {
        log.info("(list)page: {}, size: {}", page, size);
        page = page - 1;
        List<Product> products = productRepository.list(page, size);
        List<ProductResponse> productResponses = products.stream().map(product -> {
                    Long quantitySum = productQuantityHistoryRepo.getQuantitySumByProductId(product.getId());
                    return ProductResponse.from(product,
                            quantitySum != null ? quantitySum : 0
                    );
                }
        ).toList();
        long total = productRepository.total();
        return PagingResponse.builder()
                .page(page)
                .size(size)
                .total(total)
                .data(productResponses)
                .build();
    }
}
