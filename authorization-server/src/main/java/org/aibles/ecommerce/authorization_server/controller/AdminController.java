package org.aibles.ecommerce.authorization_server.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.authorization_server.dto.request.FilterRequest;
import org.aibles.ecommerce.authorization_server.dto.request.UpdateRoleRequest;
import org.aibles.ecommerce.authorization_server.service.AuthFacadeService;
import org.aibles.ecommerce.authorization_server.service.UserService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1")
public class AdminController {

    private final AuthFacadeService authFacadeService;

    private final UserService userService;

    public AdminController(AuthFacadeService authFacadeService, UserService userService) {
        this.authFacadeService = authFacadeService;
        this.userService = userService;
    }

    @PatchMapping("/admin:update-role")
    public BaseResponse updateRole(@RequestBody UpdateRoleRequest request) {
        authFacadeService.updateRole(request.getRoleIds(), request.getAccountId());
        return BaseResponse.ok("");
    }

    @GetMapping("/admin/users/{userId}")
    public BaseResponse getUser(@PathVariable("userId") String userId) {
        return BaseResponse.ok(userService.get(userId));
    }

    @PostMapping("/admin/users:filter")
    public BaseResponse filter(@RequestBody @Valid FilterRequest request) {
        return BaseResponse.ok(userService.filter(request));
    }
}
