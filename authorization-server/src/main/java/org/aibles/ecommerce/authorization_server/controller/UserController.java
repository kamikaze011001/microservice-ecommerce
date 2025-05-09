package org.aibles.ecommerce.authorization_server.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.authorization_server.dto.request.UpdatePasswordRequest;
import org.aibles.ecommerce.authorization_server.dto.request.UpdateUserRequest;
import org.aibles.ecommerce.authorization_server.service.AccountService;
import org.aibles.ecommerce.authorization_server.service.UserService;
import org.aibles.ecommerce.authorization_server.util.SecurityUtil;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1")
public class UserController {

    private final UserService userService;

    private final AccountService accountService;

    public UserController(UserService userService, AccountService accountService) {
        this.userService = userService;
        this.accountService = accountService;
    }

    @PutMapping("/users/self")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse update(@RequestBody @Valid final UpdateUserRequest request) {
        userService.update(SecurityUtil.getUserId(), request);
        return BaseResponse.ok("");
    }

    @GetMapping("/users/self")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse get() {
        return BaseResponse.ok(userService.get(SecurityUtil.getUserId()));
    }

    @PatchMapping("/users/self:update-password")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse updatePassword(@RequestBody @Valid final UpdatePasswordRequest request) {
        accountService.updatePassword(SecurityUtil.getUserId(), request.getOldPassword(), request.getNewPassword());
        return BaseResponse.ok("");
    }
}
