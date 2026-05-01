package org.aibles.ecommerce.authorization_server.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.authorization_server.util.SecurityUtil;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/users/self/avatar")
public class UserAvatarController {

    private final UserAvatarService avatarService;

    public UserAvatarController(UserAvatarService avatarService) {
        this.avatarService = avatarService;
    }

    @PostMapping("/presign")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse presign(@RequestBody @Valid PresignImageRequest request) {
        return BaseResponse.ok(avatarService.presign(SecurityUtil.getUserId(), request));
    }

    @PutMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse attach(@RequestBody @Valid AttachImageRequest request) {
        return BaseResponse.ok(avatarService.attach(SecurityUtil.getUserId(), request));
    }
}
