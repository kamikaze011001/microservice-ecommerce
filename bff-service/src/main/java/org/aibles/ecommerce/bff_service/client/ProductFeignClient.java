package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;

import java.util.Set;

@FeignClient(name = "product-service")
public interface ProductFeignClient {

    @GetMapping("/product-service/v1/products/{id}")
    BaseResponse getById(@PathVariable("id") String id);

    @GetMapping("/product-service/v1/products")
    BaseResponse listByIds(@RequestParam("ids") Set<String> ids);
}
