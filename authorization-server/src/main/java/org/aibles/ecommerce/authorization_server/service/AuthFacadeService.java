package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.constant.OTPType;
import org.aibles.ecommerce.authorization_server.dto.request.RegisterUserRequest;
import org.aibles.ecommerce.authorization_server.dto.request.ResetPasswordRequest;
import org.aibles.ecommerce.authorization_server.dto.response.LoginResponse;
import org.aibles.ecommerce.authorization_server.dto.response.RefreshTokenResponse;
import org.aibles.ecommerce.authorization_server.dto.response.VerifyForgotPasswordOtpResponse;

import java.util.List;

public interface AuthFacadeService {

    void register(RegisterUserRequest request);

    void activate(String email, String otp);

    LoginResponse login(String username, String password);

    void updateRole(List<String> roleIds, String accountId);

    RefreshTokenResponse refreshToken(String refreshToken);

    void forgotPassword(String email);

    VerifyForgotPasswordOtpResponse verifyForgotPasswordOtp(String email, String otp);

    void resetPassword(ResetPasswordRequest request);

    void resendOtp(OTPType type, String email);
}
