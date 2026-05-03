package org.aibles.ecommerce.bff_service.configuration;

import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.PaymentFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.bff_service.service.impl.BffServiceImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class BffServiceConfiguration {

    @Bean
    public BffService bffService(ProductFeignClient productFeignClient,
                                 OrderFeignClient orderFeignClient,
                                 PaymentFeignClient paymentFeignClient,
                                 InventoryGrpcClientService inventoryGrpcClientService) {
        return new BffServiceImpl(productFeignClient, orderFeignClient, paymentFeignClient, inventoryGrpcClientService);
    }
}
