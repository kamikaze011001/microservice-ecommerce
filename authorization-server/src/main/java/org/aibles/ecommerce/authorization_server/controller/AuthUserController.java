package org.aibles.ecommerce.authorization_server.controller;

import jakarta.validation.Valid;
import org.aibles.ecommerce.authorization_server.constant.OTPType;
import org.aibles.ecommerce.authorization_server.dto.request.*;
import org.aibles.ecommerce.authorization_server.dto.response.LoginResponse;
import org.aibles.ecommerce.authorization_server.dto.response.RefreshTokenResponse;
import org.aibles.ecommerce.authorization_server.dto.response.VerifyForgotPasswordOtpResponse;
import org.aibles.ecommerce.authorization_server.service.AuthFacadeService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1")
public class AuthUserController {

    private final AuthFacadeService authFacadeService;

    public AuthUserController(AuthFacadeService authFacadeService) {
        this.authFacadeService = authFacadeService;
    }

    @PostMapping("/auth:register")
    @ResponseStatus(HttpStatus.CREATED)
    public BaseResponse register(@RequestBody @Valid RegisterUserRequest request) {
        authFacadeService.register(request);
        return BaseResponse.created("");
    }

    @PostMapping("/auth:activate")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse active(@RequestBody @Valid ActiveAccountRequest request) {
        authFacadeService.activate(request.getEmail(), request.getOtp());
        return BaseResponse.ok("");
    }

    @PostMapping("/auth:login")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse login(@RequestBody @Valid LoginRequest request) {
        LoginResponse response = authFacadeService.login(request.getUsername(), request.getPassword());
        return BaseResponse.ok(response);
    }

    @PostMapping("/auth:refresh-token")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse refreshToken(@RequestHeader(HttpHeaders.AUTHORIZATION) String refreshToken) {
        RefreshTokenResponse response = authFacadeService.refreshToken(refreshToken);
        return BaseResponse.ok(response);
    }

    @PostMapping("/auth:forgot-password")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse forgotPassword(@RequestBody @Valid ForgotPasswordRequest request) {
        authFacadeService.forgotPassword(request.getEmail());
        return BaseResponse.ok("");
    }

    @PostMapping("/auth:verify-forgot-pass-otp")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse verifyForgotPasswordOtp(@RequestBody @Valid VerifyForgotPasswordOtpRequest request) {
        VerifyForgotPasswordOtpResponse response = authFacadeService.
                verifyForgotPasswordOtp(request.getEmail(), request.getOtp());
        return BaseResponse.ok(response);
    }

    @PostMapping("/auth:reset-password")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse resetPassword(@RequestBody @Valid ResetPasswordRequest request) {
        authFacadeService.resetPassword(request);
        return BaseResponse.ok("");
    }

    @PostMapping("/auth:resend-otp")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse resendOtp(@RequestBody @Valid ResendOTPRequest request) {
        authFacadeService.resendOtp(OTPType.resolve(request.getType()), request.getEmail());
        return BaseResponse.ok("");
    }
}
