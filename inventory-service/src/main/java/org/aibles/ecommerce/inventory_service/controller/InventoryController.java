package org.aibles.ecommerce.inventory_service.controller;

import jakarta.validation.Valid;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory_service.dto.request.InventoryProductUpdateRequest;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequestMapping("/v1/inventories")
public class InventoryController {

    private final InventoryService inventoryService;

    public InventoryController(InventoryService inventoryService) {
        this.inventoryService = inventoryService;
    }

    @PatchMapping("/{id}")
    public BaseResponse update(@PathVariable("id") String id, @RequestBody @Valid InventoryProductUpdateRequest request) {
        log.info("(update) request: {}", request);
        inventoryService.update(id, request.getQuantity(), request.getIsAdd());
        return BaseResponse.ok();
    }
}
